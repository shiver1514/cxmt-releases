[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Owner,

    [Parameter(Mandatory = $true)]
    [string] $Repo,

    [string] $Token = $env:GITHUB_TOKEN,

    [string] $Tag = ("temp-" + (Get-Date -Format "yyyyMMdd-HHmmss")),

    [string] $ReleaseName,

    [string] $ArchiveLabel,

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

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OperationName,

        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,

        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4,

        [ValidateRange(0, 300)]
        [int] $DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }

            Write-Warning ("{0} failed on attempt {1}/{2}: {3}" -f $OperationName, $attempt, $MaxAttempts, $_.Exception.Message)
            if ($DelaySeconds -gt 0) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
}

function Get-UploadProgressPercent {
    param(
        [Parameter(Mandatory = $true)]
        [int64] $UploadedBytes,

        [Parameter(Mandatory = $true)]
        [int64] $TotalBytes
    )

    if ($TotalBytes -le 0) {
        return 0
    }

    $percent = [int] [Math]::Floor(($UploadedBytes / $TotalBytes) * 100)
    if ($percent -lt 0) {
        return 0
    }

    if ($percent -gt 100) {
        return 100
    }

    return $percent
}

function ConvertTo-SafeAssetNamePart {
    param(
        [AllowNull()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $safeValue = $Value.Trim() -replace '[^A-Za-z0-9_.-]+', '-'
    $safeValue = $safeValue -replace '-+', '-'
    return $safeValue.Trim([char[]] ".-")
}

function Get-ArchiveBaseName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repo,

        [Parameter(Mandatory = $true)]
        [string] $Tag,

        [AllowEmptyString()]
        [string] $ArchiveLabel
    )

    $safeRepo = ConvertTo-SafeAssetNamePart $Repo
    $safeTag = ConvertTo-SafeAssetNamePart $Tag
    $archiveBaseName = "$safeRepo-$safeTag"
    $safeLabel = ConvertTo-SafeAssetNamePart $ArchiveLabel

    if ((-not [string]::IsNullOrWhiteSpace($ArchiveLabel)) -and [string]::IsNullOrWhiteSpace($safeLabel)) {
        throw "ArchiveLabel '$ArchiveLabel' does not contain usable asset-name characters. Use letters, numbers, dots, underscores, or hyphens."
    }

    if (-not [string]::IsNullOrWhiteSpace($safeLabel)) {
        $archiveBaseName = "$archiveBaseName-$safeLabel"
    }

    return $archiveBaseName
}

function Get-ManifestFileName {
    param(
        [AllowEmptyString()]
        [string] $ArchiveLabel
    )

    $safeLabel = ConvertTo-SafeAssetNamePart $ArchiveLabel
    if ((-not [string]::IsNullOrWhiteSpace($ArchiveLabel)) -and [string]::IsNullOrWhiteSpace($safeLabel)) {
        throw "ArchiveLabel '$ArchiveLabel' does not contain usable asset-name characters. Use letters, numbers, dots, underscores, or hyphens."
    }

    if ([string]::IsNullOrWhiteSpace($safeLabel)) {
        return "manifest.json"
    }

    return "manifest-$safeLabel.json"
}

function Find-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)] $Release,
        [Parameter(Mandatory = $true)][string] $AssetName
    )

    if (-not ($Release.PSObject.Properties.Name -contains "assets")) {
        return $null
    }

    foreach ($asset in @($Release.assets)) {
        if ($asset.name -eq $AssetName) {
            return $asset
        }
    }

    return $null
}

function Get-AssetUploadDecision {
    param(
        [AllowNull()] $ExistingAsset,

        [Parameter(Mandatory = $true)]
        [int64] $LocalSize
    )

    if ($null -eq $ExistingAsset) {
        return "Upload"
    }

    if ([int64] $ExistingAsset.size -eq $LocalSize) {
        return "Skip"
    }

    return "Replace"
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

    Invoke-WithRetry -OperationName "$Method $Uri" -ScriptBlock {
        Invoke-RestMethod @params
    }
}

function Set-RequestHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebRequest] $Request,

        [Parameter(Mandatory = $true)]
        [hashtable] $Headers
    )

    foreach ($key in $Headers.Keys) {
        $value = [string] $Headers[$key]
        switch ($key.ToLowerInvariant()) {
            "accept" { $Request.Accept = $value }
            "user-agent" { $Request.UserAgent = $value }
            default { $Request.Headers[$key] = $value }
        }
    }
}

function Read-WebResponseBody {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebResponse] $Response
    )

    $stream = $Response.GetResponseStream()
    if ($null -eq $stream) {
        return ""
    }

    $reader = [System.IO.StreamReader]::new($stream)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Invoke-GitHubAssetUpload {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [hashtable] $Headers,

        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string] $Activity,

        [int] $ProgressId = 1
    )

    $file = Get-Item -LiteralPath $FilePath
    $request = [System.Net.HttpWebRequest] [System.Net.WebRequest]::Create($Uri)
    $request.Method = "POST"
    $request.ContentType = "application/octet-stream"
    $request.ContentLength = $file.Length
    $request.AllowWriteStreamBuffering = $false
    $request.SendChunked = $false
    $request.Timeout = 60 * 60 * 1000
    $request.ReadWriteTimeout = 60 * 60 * 1000
    Set-RequestHeaders -Request $request -Headers $Headers

    $buffer = New-Object byte[] (8MB)
    $uploadedBytes = [int64] 0
    $fileStream = [System.IO.File]::OpenRead($file.FullName)
    $requestStream = $null

    try {
        $requestStream = $request.GetRequestStream()
        while ($true) {
            $bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) {
                break
            }

            $requestStream.Write($buffer, 0, $bytesRead)
            $uploadedBytes += $bytesRead
            $percent = Get-UploadProgressPercent -UploadedBytes $uploadedBytes -TotalBytes $file.Length
            $status = "{0:N2} MiB / {1:N2} MiB ({2}%)" -f ($uploadedBytes / 1MB), ($file.Length / 1MB), $percent
            Write-Progress -Id $ProgressId -Activity $Activity -Status $status -PercentComplete $percent
        }
    }
    finally {
        if ($null -ne $requestStream) {
            $requestStream.Dispose()
        }
        $fileStream.Dispose()
    }

    try {
        $response = $request.GetResponse()
        try {
            $body = Read-WebResponseBody -Response $response
            Write-Progress -Id $ProgressId -Activity $Activity -Completed
            if ([string]::IsNullOrWhiteSpace($body)) {
                return $null
            }

            return $body | ConvertFrom-Json
        }
        finally {
            $response.Dispose()
        }
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $statusCode = [int] $_.Exception.Response.StatusCode
            $body = Read-WebResponseBody -Response $_.Exception.Response
            throw "GitHub upload failed with HTTP $statusCode. $body"
        }

        throw
    }
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

$archiveBaseName = Get-ArchiveBaseName -Repo $Repo -Tag $Tag -ArchiveLabel $ArchiveLabel
$archivePath = Join-Path $releaseArtifactsPath "$archiveBaseName.tar"
$chunkSizeBytes = [int64] $ChunkSizeMB * 1MB

Write-Host "Creating tar archive from: $sourceFullPath"
New-TarArchive -SourceDirectory $sourceFullPath -ArchivePath $archivePath

Write-Host "Splitting archive when larger than $ChunkSizeMB MiB..."
$assetPaths = @(Split-LargeFile -Path $archivePath -OutputDirectory $releaseArtifactsPath -ChunkSizeBytes $chunkSizeBytes)

if (($assetPaths.Count -gt 1) -and (-not $KeepArchive)) {
    Remove-Item -LiteralPath $archivePath -Force
}

$manifestPath = Join-Path $releaseArtifactsPath (Get-ManifestFileName -ArchiveLabel $ArchiveLabel)
$manifest = [ordered] @{
    owner = $Owner
    repo = $Repo
    tag = $Tag
    archiveLabel = $ArchiveLabel
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

for ($assetIndex = 0; $assetIndex -lt $assetPaths.Count; $assetIndex++) {
    $assetPath = $assetPaths[$assetIndex]
    $asset = Get-Item -LiteralPath $assetPath

    $escapedName = [Uri]::EscapeDataString($asset.Name)
    $uploadUri = "https://uploads.github.com/repos/$Owner/$Repo/releases/$($release.id)/assets?name=$escapedName"

    $assetNumber = $assetIndex + 1
    $activity = "Uploading asset $assetNumber of $($assetPaths.Count): $($asset.Name)"

    $uploadResult = Invoke-WithRetry -OperationName "Upload $($asset.Name)" -ScriptBlock {
        $currentRelease = Invoke-GitHubApi -Method Get -Uri "$apiBase/releases/tags/$Tag" -Headers $headers
        $existingAsset = Find-ReleaseAsset -Release $currentRelease -AssetName $asset.Name
        $decision = Get-AssetUploadDecision -ExistingAsset $existingAsset -LocalSize $asset.Length

        if ($decision -eq "Skip") {
            Write-Host "Skipping existing $($asset.Name) ($([Math]::Round($asset.Length / 1MB, 2)) MiB)"
            return [pscustomobject] @{ skipped = $true }
        }

        if ($decision -eq "Replace") {
            Write-Host "Deleting existing asset with different size: $($asset.Name)"
            Invoke-GitHubApi -Method Delete -Uri "$apiBase/releases/assets/$($existingAsset.id)" -Headers $headers | Out-Null
        }

        Write-Host "$activity ($([Math]::Round($asset.Length / 1MB, 2)) MiB)"
        Invoke-GitHubAssetUpload -Uri $uploadUri -Headers $headers -FilePath $asset.FullName -Activity $activity -ProgressId 1
        return [pscustomobject] @{ skipped = $false }
    }

    if (-not ($uploadResult.PSObject.Properties.Name -contains "skipped") -or -not $uploadResult.skipped) {
        Write-Host "Uploaded $($asset.Name)"
    }
}

Write-Host ""
Write-Host "Release upload complete:"
Write-Host "https://github.com/$Owner/$Repo/releases/tag/$Tag"
