param(
    [Parameter(Mandatory=$true)]
    [string]$jmeno,

    [Parameter(Mandatory=$true)]
    [string]$heslo
)

class Transaction
{
    [System.DateTime]$Date
    [int]$Amount
    [int]$TotalAmount
    [System.Nullable[int]]$RemainingAmount
    [string]$Description

    Transaction([System.DateTime]$date, [int]$amount, [string]$description)
    {
        $this.Date = $date
        $this.Amount = $amount
        $this.Description = $description
    }
}

function GetResponse()
{
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession]$session,
        [int]$page
    )

    $uri = "https://www.cd.cz/profil-uzivatele/user/loyalty/full?type=ALL&pageNum=$page";

    $response = Invoke-WebRequest -Uri $uri -WebSession $session
    $responseBody = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($response.Content))

    ConvertFrom-Json $responseBody
}

function ParseDate()
{
    param(
        [long]$timestamp
    )
    $origin = New-Object -Type DateTime -ArgumentList 1970, 1, 1, 0, 0, 0, 0
    $origin.AddMilliseconds($timestamp).ToLocalTime()
}

function SplitMinusTransactions()
{
    param(
        [Transaction[]]$transactions
    )

    $plusTransactions = $transactions | ? { $_.Amount -gt 0 };
    $minusTransactions = New-Object -TypeName 'System.Collections.Generic.Stack[Transaction]'
    $transactions `
        | ? { $_.Amount -lt 0 } `
        | Reverse `
        | % { $minusTransactions.Push($_) } `
        | Out-Null
    $resultTransactions = [System.Collections.Generic.List[Transaction]]@()

    $remainingAmount = 0;
    foreach ($plusTransaction in $plusTransactions)
    {
        $remainingAmount += $plusTransaction.Amount

        $resultTransactions.Add($plusTransaction)

        $totalMinusAmount = 0

        while ($minusTransactions.Count -gt 0)
        {
            $minusTransaction = $minusTransactions.Peek()

            if ($remainingAmount -lt -$minusTransaction.Amount)
            {
                break
            }

            $minusTransactions.Pop() | Out-Null

            $totalMinusAmount += -$minusTransaction.Amount

            if ($totalMinusAmount -lt $remainingAmount)
            {
                $remainingAmount -= -$minusTransaction.Amount
                $totalMinusAmount -= -$minusTransaction.Amount
                $resultTransactions.Add($minusTransaction)
            }
            else
            {
                $minusAmount = $remainingAmount - $totalMinusAmount
                $remainingAmount -= $minusAmount
                $splittedTransaction1 = CopyWithNewAmount -transaction $minusTransaction -newAmount $minusAmount
                $resultTransactions.Add($splittedTransaction1)
                $splittedTransaction2 = CopyWithNewAmount -transaction $minusTransaction -newAmount $minusTransaction.Amount - $minusAmount
                $minusTransactions.Push($splittedTransaction2)
                break
            }
        }
    }

    $resultTransactions
}

function CopyWithNewAmount()
{
    param(
        [Transaction]$transaction,
        [int]$newAmount
    )

    [Transaction]::new($transaction.Date, $newAmount, $transaction.Description)
}

function Reverse()
{
    param(
        [Parameter(ValueFromPipeline)]
        $input
    )
    $result = @($input)
    [System.Array]::Reverse($result)
    $result
}

function SkipWhile()
{
    param(
        [Parameter(ValueFromPipeline)]
        $input,
        $predicate
    )

    begin
    {
        $skip = $true
    }

    process
    {
        if ($skip)
        {
            $skip = & $predicate $input
        }
        else
        {
            $input
        }
    }
}

function CalculateRemainingAmount()
{
    param(
        [Transaction]$lastMinusTransaction,
        [Transaction]$lastUsedTransaction,
        [Transaction]$transaction
    )

    $transaction.RemainingAmount = if ($transaction.Amount -lt 0)
    {
        $null;
    }
    elseif ($lastMinusTransaction -eq $null)
    {
        $transaction.Amount;
    }
    elseif ($lastUsedTransaction -eq $null)
    {
        $lastMinusTransaction.TotalAmount;
    }
    else
    {
        0;
    }
}

$body = @{
    username = $jmeno;
    password = $heslo
}

Invoke-WebRequest -Method POST -Uri 'https://www.cd.cz//profil-uzivatele/auth/login' -body $body -ContentType 'application/x-www-form-urlencoded' -SessionVariable session | Out-Null

[System.Collections.Generic.List[System.Object]]$pages = @()
$page1 = GetResponse -session $session -page 1
$pages.Add($page1) | Out-Null

2..$page1.transactionList.pageCount `
    | % { GetResponse -session $session -page $_ } `
    | % { $pages.Add($_) } `
    | Out-Null

$allTransactions = $pages `
    | % { $_.transactionList.transactions } `
    | % {
        $date = ParseDate -times $_.date
        $amount = if ($_.kredit) { $_.amount } else { -$_.amount }
        [Transaction]::new($date, $amount, $_.description)
    } `
    | Sort-Object -Property Date

if ($allTransactions.Count -eq 0)
{
    "Nebyly nalezeny žádné transakce."
    return;
}

$sortedTransactions = SplitMinusTransactions -transactions $allTransactions

$totalAmount = 0
foreach ($transaction in $sortedTransactions)
{
    $totalAmount += $transaction.Amount;
    $transaction.TotalAmount = $totalAmount;
}


[Transaction]$lastMinusTransaction = $null
[Transaction]$lastUsedTransaction = $null

foreach ($transaction in $sortedTransactions | Reverse)
{
    CalculateRemainingAmount -lastMinusTransaction $lastMinusTransaction -lastUsedTransaction $lastUsedTransaction -transaction $transaction

    if ($lastMinusTransaction -eq $null -and $transaction.Amount -lt 0)
    {
        $lastMinusTransaction = $transaction;
    }

    if ($lastUsedTransaction -eq $null -and $lastMinusTransaction -ne $null -and $transaction.Amount -gt 0)
    {
        $lastUsedTransaction = $transaction;
    }
}

$sortedTransactions | Format-Table `
    @{ L = 'Datum'; E = { $_.Date } }, `
    @{ L = 'Body'; E = { $_.Amount } }, `
    @{ L = 'Zbývající body'; E = { $_.RemainingAmount } }, `
    @{ L = 'Název'; E = { $_.Description } }


$lastTransaction = $sortedTransactions `
    | Reverse `
    | SkipWhile -predicate { $_.Amount -gt 0 } `
    | ? { $_.Amount -gt 0 -and $_.RemainingAmount -gt 0 } `
    | Select-Object -First 1

if ($lastTransaction -eq $null)
{
    $lastTransaction = $sortedTransactions `
        | Select-Object -First 1
}

"Zbývá $totalAmount bodů, $($lastTransaction.RemainingAmount) bodů expiruje $($lastTransaction.Date.AddYears(2).ToString())."
