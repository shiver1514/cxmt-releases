[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-ScriptFunction {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)][string] $FunctionName
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath,
        [ref] $tokens,
        [ref] $parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Parse errors found in $ScriptPath"
    }

    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $FunctionName
    }, $true)

    if ($null -eq $functionAst) {
        throw "Function $FunctionName not found in $ScriptPath"
    }

    . ([scriptblock]::Create("function global:$FunctionName $($functionAst.Body.Extent.Text)"))
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] $Actual,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$scriptPath = Join-Path $PSScriptRoot "Publish-GitHubRelease.ps1"
Import-ScriptFunction -ScriptPath $scriptPath -FunctionName "Invoke-WithRetry"
Import-ScriptFunction -ScriptPath $scriptPath -FunctionName "Get-UploadProgressPercent"

$attempts = 0
$result = Invoke-WithRetry -OperationName "flaky operation" -MaxAttempts 3 -DelaySeconds 0 -ScriptBlock {
    $script:attempts++
    if ($script:attempts -lt 3) {
        throw "temporary failure"
    }

    "ok"
}

Assert-Equal -Expected "ok" -Actual $result -Message "Retry should return the successful result."
Assert-Equal -Expected 3 -Actual $attempts -Message "Retry should attempt until the operation succeeds."

$attempts = 0
try {
    Invoke-WithRetry -OperationName "persistent failure" -MaxAttempts 2 -DelaySeconds 0 -ScriptBlock {
        $script:attempts++
        throw "still failing"
    } | Out-Null

    throw "Expected persistent failure to throw."
}
catch {
    if ($_.Exception.Message -eq "Expected persistent failure to throw.") {
        throw
    }
}

Assert-Equal -Expected 2 -Actual $attempts -Message "Retry should stop after the maximum attempt count."

Assert-Equal -Expected 0 -Actual (Get-UploadProgressPercent -UploadedBytes 0 -TotalBytes 0) -Message "Zero-byte totals should report 0 percent."
Assert-Equal -Expected 0 -Actual (Get-UploadProgressPercent -UploadedBytes 0 -TotalBytes 100) -Message "No uploaded bytes should report 0 percent."
Assert-Equal -Expected 50 -Actual (Get-UploadProgressPercent -UploadedBytes 50 -TotalBytes 100) -Message "Half uploaded should report 50 percent."
Assert-Equal -Expected 100 -Actual (Get-UploadProgressPercent -UploadedBytes 100 -TotalBytes 100) -Message "Complete uploads should report 100 percent."
Assert-Equal -Expected 100 -Actual (Get-UploadProgressPercent -UploadedBytes 120 -TotalBytes 100) -Message "Progress should be capped at 100 percent."

Write-Host "Publish-GitHubRelease retry tests passed."
