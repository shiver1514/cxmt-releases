[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Owner,

    [Parameter(Mandatory = $true)]
    [string] $Repo,

    [string] $Token = $env:GITHUB_TOKEN,

    [string] $Tag = ("temp-" + (Get-Date -Format "yyyyMMdd-HHmmss")),

    [string] $ReleaseName,

    [string] $SourcePath = (Join-Path $PSScriptRoot "..\payload"),

    [string] $ArtifactsPath = (Join-Path $PSScriptRoot "..\release-artifacts"),

    [ValidateRange(1, 2000)]
    [int] $ChunkSizeMB = 1900,

    [switch] $KeepArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Get", "Post", "Delete")]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [hashtable] $Headers,

        [object] $Body
    )

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $Headers
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }

    Invoke-RestMethod @params
}

function New-TarArchive {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDirectory,
        [Parameter(Mandatory = $true)][string] $ArchivePath
    )

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw "tar.exe was not found. Windows 10/11 normally includes it. Install tar or run this script from a shell where tar.exe is available."
    }

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    & $tar.Source -cf $ArchivePath -C $SourceDirectory .
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed with exit code $LASTEXITCODE."
    }
}

function Split-LargeFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $OutputDirectory,
        [Parameter(Mandatory = $true)][int64] $ChunkSizeBytes
    )

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -le $ChunkSizeBytes) {
        return @($file.FullName)
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $buffer = New-Object byte[] (8MB)
    $inputStream = [System.IO.File]::OpenRead($file.FullName)

    try {
        $partNumber = 1
        while ($inputStream.Position -lt $inputStream.Length) {
            $partPath = Join-Path $OutputDirectory ("{0}.part{1:D3}" -f $file.Name, $partNumber)
            if (Test-Path -LiteralPath $partPath) {
                Remove-Item -LiteralPath $partPath -Force
            }

            $outputStream = [System.IO.File]::Create($partPath)
            try {
                $remainingInPart = [Math]::Min($ChunkSizeBytes, $inputStream.Length - $inputStream.Position)
                while ($remainingInPart -gt 0) {
                    $bytesToRead = [int] [Math]::Min($buffer.Length, $remainingInPart)
                    $bytesRead = $inputStream.Read($buffer, 0, $bytesToRead)
                    if ($bytesRead -le 0) {
                        break
                    }

                    $outputStream.Write($buffer, 0, $bytesRead)
                    $remainingInPart -= $bytesRead
                }
            }
            finally {
                $outputStream.Dispose()
            }

            $parts.Add($partPath)
            $partNumber++
        }
    }
    finally {
        $inputStream.Dispose()
    }

    return $parts.ToArray()
}

function Remove-ExistingAsset {
    param(
        [Parameter(Mandatory = $true)] $Release,
        [Parameter(Mandatory = $true)][string] $AssetName,
        [Parameter(Mandatory = $true)][string] $ApiBase,
        [Parameter(Mandatory = $true)][hashtable] $Headers
    )

    $assets = @()
    if ($Release.PSObject.Properties.Name -contains "assets") {
        $assets = @($Release.assets)
    }

    foreach ($asset in $assets) {
        if ($asset.name -eq $AssetName) {
            Write-Host "Deleting existing release asset: $AssetName"
            Invoke-GitHubApi -Method Delete -Uri "$ApiBase/releases/assets/$($asset.id)" -Headers $Headers | Out-Null
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "GITHUB_TOKEN is not set. Run: `$env:GITHUB_TOKEN = `"YOUR_TOKEN`""
}

$sourceFullPath = Resolve-FullPath $SourcePath
$artifactsRoot = Resolve-FullPath $ArtifactsPath
$releaseArtifactsPath = Join-Path $artifactsRoot $Tag

if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Container)) {
    throw "Source directory not found: $sourceFullPath"
}

$payloadFiles = @(Get-ChildItem -LiteralPath $sourceFullPath -File -Force -Recurse)
if ($payloadFiles.Count -eq 0) {
    throw "No files found in $sourceFullPath. Put files in payload/ first."
}

New-Item -ItemType Directory -Force -Path $releaseArtifactsPath | Out-Null

$safeRepo = $Repo -replace '[^A-Za-z0-9_.-]', '-'
$archivePath = Join-Path $releaseArtifactsPath "$safeRepo-$Tag.tar"
$chunkSizeBytes = [int64] $ChunkSizeMB * 1MB

Write-Host "Creating tar archive from: $sourceFullPath"
New-TarArchive -SourceDirectory $sourceFullPath -ArchivePath $archivePath

Write-Host "Splitting archive when larger than $ChunkSizeMB MiB..."
$assetPaths = @(Split-LargeFile -Path $archivePath -OutputDirectory $releaseArtifactsPath -ChunkSizeBytes $chunkSizeBytes)

if (($assetPaths.Count -gt 1) -and (-not $KeepArchive)) {
    Remove-Item -LiteralPath $archivePath -Force
}

$manifestPath = Join-Path $releaseArtifactsPath "manifest.json"
$manifest = [ordered] @{
    owner = $Owner
    repo = $Repo
    tag = $Tag
    createdAt = (Get-Date).ToString("o")
    sourcePath = $sourceFullPath
    chunkSizeMB = $ChunkSizeMB
    archiveName = (Split-Path $archivePath -Leaf)
    assets = @(
        foreach ($assetPath in $assetPaths) {
            $asset = Get-Item -LiteralPath $assetPath
            [ordered] @{
                name = $asset.Name
                bytes = $asset.Length
                sha256 = (Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256).Hash
            }
        }
    )
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$assetPaths += $manifestPath

$headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent" = "github-release-staging-powershell"
}

$apiBase = "https://api.github.com/repos/$Owner/$Repo"

if ([string]::IsNullOrWhiteSpace($ReleaseName)) {
    $ReleaseName = "Temporary stash $Tag"
}

try {
    Write-Host "Checking for existing release tag: $Tag"
    $release = Invoke-GitHubApi -Method Get -Uri "$apiBase/releases/tags/$Tag" -Headers $headers
}
catch {
    $statusCode = $null
    if ($_.Exception.Response) {
        $statusCode = [int] $_.Exception.Response.StatusCode
    }

    if ($statusCode -ne 404) {
        throw
    }

    Write-Host "Creating GitHub prerelease: $Tag"
    $releaseBody = @{
        tag_name = $Tag
        name = $ReleaseName
        body = "Temporary stash uploaded by scripts/Publish-GitHubRelease.ps1. Download all archive parts and manifest.json before restoring."
        draft = $false
        prerelease = $true
        make_latest = "false"
    }

    $release = Invoke-GitHubApi -Method Post -Uri "$apiBase/releases" -Headers $headers -Body $releaseBody
}

foreach ($assetPath in $assetPaths) {
    $asset = Get-Item -LiteralPath $assetPath
    Remove-ExistingAsset -Release $release -AssetName $asset.Name -ApiBase $apiBase -Headers $headers

    $escapedName = [Uri]::EscapeDataString($asset.Name)
    $uploadUri = "https://uploads.github.com/repos/$Owner/$Repo/releases/$($release.id)/assets?name=$escapedName"

    Write-Host "Uploading $($asset.Name) ($([Math]::Round($asset.Length / 1MB, 2)) MiB)"
    Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $headers -ContentType "application/octet-stream" -InFile $asset.FullName | Out-Null
}

Write-Host ""
Write-Host "Release upload complete:"
Write-Host "https://github.com/$Owner/$Repo/releases/tag/$Tag"
