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

Write-Host "Publish-GitHubRelease retry tests passed."
