[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PartsDirectory,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

$partsFullPath = Resolve-FullPath $PartsDirectory
$outputFullPath = Resolve-FullPath $OutputDirectory

if (-not (Test-Path -LiteralPath $partsFullPath -PathType Container)) {
    throw "Parts directory not found: $partsFullPath"
}

New-Item -ItemType Directory -Force -Path $outputFullPath | Out-Null

$manifestPath = Join-Path $partsFullPath "manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest.json not found in $partsFullPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$archivePath = Join-Path $partsFullPath $manifest.archiveName
$partFiles = @(Get-ChildItem -LiteralPath $partsFullPath -File | Where-Object { $_.Name -like "$($manifest.archiveName).part*" } | Sort-Object Name)

if ($partFiles.Count -eq 0) {
    $singleArchive = Join-Path $partsFullPath $manifest.archiveName
    if (-not (Test-Path -LiteralPath $singleArchive)) {
        throw "No archive or archive parts found for $($manifest.archiveName)."
    }
    $archivePath = $singleArchive
}
else {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }

    $outputStream = [System.IO.File]::Create($archivePath)
    try {
        foreach ($part in $partFiles) {
            Write-Host "Joining $($part.Name)"
            $inputStream = [System.IO.File]::OpenRead($part.FullName)
            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $outputStream.Dispose()
    }
}

Write-Host "Verifying archive hash entries..."
foreach ($asset in @($manifest.assets)) {
    $assetPath = Join-Path $partsFullPath $asset.name
    if (Test-Path -LiteralPath $assetPath) {
        $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
        if ($actualHash -ne $asset.sha256) {
            throw "SHA256 mismatch for $($asset.name)."
        }
    }
}

$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tar) {
    throw "tar.exe was not found. Windows 10/11 normally includes it."
}

Write-Host "Extracting archive to: $outputFullPath"
& $tar.Source -xf $archivePath -C $outputFullPath
if ($LASTEXITCODE -ne 0) {
    throw "tar.exe failed with exit code $LASTEXITCODE."
}

Write-Host "Restore complete: $outputFullPath"
