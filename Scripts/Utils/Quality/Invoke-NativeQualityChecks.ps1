[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("All", "stylua", "actionlint")]
    [string]$Tool = "All",

    [Parameter(Mandatory = $false)]
    [switch]$Fix,

    [Parameter(Mandatory = $false)]
    [switch]$EnsureOnly,

    [Parameter(Mandatory = $false)]
    [switch]$NoInvokeMain,

    [Parameter(Mandatory = $false, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$TargetFiles = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:NativeQualityManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "native-quality-tools.json"
$script:NativeQualityToolRootName = ".tools/native-quality"
$script:NativeQualityDownloadTimeoutSeconds = 300
$script:NativeQualityLockTimeoutSeconds = 60
$script:NativeQualityLockRetryMilliseconds = 200

if (-not [string]::IsNullOrWhiteSpace($env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS)) {
    if ($env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS -notmatch '^[0-9]+$' -or [int]$env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS -lt 30) {
        throw "E_NATIVE_TOOL_TIMEOUT_CONFIG: WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS must be an integer >= 30 seconds (received '$env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS')."
    }

    $script:NativeQualityDownloadTimeoutSeconds = [int]$env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS
}

$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/StrictModeHelpers.ps1"
if (-not (Test-Path -LiteralPath $strictModeHelpersPath -PathType Leaf)) {
    throw "E_NATIVE_TOOL_STRICT_MODE_HELPER_MISSING: strict mode helper file not found at '$strictModeHelpersPath'."
}

. $strictModeHelpersPath

function Get-NativeQualityRepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../../..") -ErrorAction Stop).Path
}

function Read-NativeQualityToolManifest {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ManifestPath = $script:NativeQualityManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "E_NATIVE_TOOL_MANIFEST_MISSING: native quality tool manifest not found at '$ManifestPath'."
    }

    $manifestContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path, [System.Text.Encoding]::UTF8)
    $manifest = ConvertFrom-JsonSingleObject -Json $manifestContent -Context "native quality tool manifest"
    if ($null -eq $manifest.tools) {
        throw "E_NATIVE_TOOL_MANIFEST_INVALID: manifest '$ManifestPath' does not define a tools object."
    }

    return $manifest
}

function ConvertTo-NativeQualityArchitectureName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Runtime.InteropServices.Architecture]$Architecture
    )

    switch ($Architecture) {
        ([System.Runtime.InteropServices.Architecture]::X64) { return "x64" }
        ([System.Runtime.InteropServices.Architecture]::Arm64) { return "arm64" }
        ([System.Runtime.InteropServices.Architecture]::X86) { return "x86" }
        ([System.Runtime.InteropServices.Architecture]::Arm) { return "arm" }
        default { return ([string]$Architecture).ToLowerInvariant() }
    }
}

function Get-NativeQualityOperatingSystemName {
    if ($IsWindows) {
        return "windows"
    }

    if ($IsMacOS) {
        return "darwin"
    }

    if ($IsLinux) {
        return "linux"
    }

    throw "E_NATIVE_TOOL_PLATFORM_UNSUPPORTED: unsupported operating system for native quality tools."
}

function Get-NativeQualityExecutableName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutableBaseName,

        [Parameter(Mandatory = $true)]
        [string]$OperatingSystem
    )

    if ($OperatingSystem -eq "windows") {
        return "$ExecutableBaseName.exe"
    }

    return $ExecutableBaseName
}

function Get-NativeQualityAssetProperty {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ToolManifest,

        [Parameter(Mandatory = $true)]
        [string]$AssetKey
    )

    $assetProperty = $ToolManifest.assets.PSObject.Properties[$AssetKey]
    if ($null -eq $assetProperty) {
        return $null
    }

    return $assetProperty.Value
}

function Get-NativeQualityVersionArguments {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ToolManifest
    )

    $versionArgumentsProperty = $ToolManifest.PSObject.Properties["versionArguments"]
    if ($null -eq $versionArgumentsProperty) {
        return @("--version")
    }

    $versionArguments = @(
        foreach ($argument in @($versionArgumentsProperty.Value)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$argument)) {
                [string]$argument
            }
        }
    )

    if ($versionArguments.Count -eq 0) {
        return @("--version")
    }

    return @($versionArguments)
}

function Resolve-NativeQualityAssetSpec {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,

        [Parameter(Mandatory = $true)]
        [ValidateSet("stylua", "actionlint")]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("darwin", "linux", "windows")]
        [string]$OperatingSystem,

        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    $toolProperty = $Manifest.tools.PSObject.Properties[$ToolName]
    if ($null -eq $toolProperty) {
        throw "E_NATIVE_TOOL_MANIFEST_INVALID: manifest does not define tool '$ToolName'."
    }

    $toolManifest = $toolProperty.Value
    $requestedAssetKey = "$OperatingSystem-$Architecture"
    $asset = Get-NativeQualityAssetProperty -ToolManifest $toolManifest -AssetKey $requestedAssetKey
    $assetKey = $requestedAssetKey
    $fallbackReason = ""

    if ($null -eq $asset -and $OperatingSystem -eq "windows" -and $Architecture -eq "arm64") {
        $assetKey = "windows-x64"
        $asset = Get-NativeQualityAssetProperty -ToolManifest $toolManifest -AssetKey $assetKey
        if ($null -ne $asset) {
            $fallbackReason = "upstream publishes no Windows ARM64 $ToolName asset; using the pinned Windows x64 asset under Windows ARM64 emulation"
        }
    }

    if ($null -eq $asset) {
        $supportedAssets = @($toolManifest.assets.PSObject.Properties.Name | Sort-Object) -join ", "
        throw "E_NATIVE_TOOL_PLATFORM_UNSUPPORTED: $ToolName does not have a pinned asset for platform '$requestedAssetKey' (supportedAssets=$supportedAssets)."
    }

    $releaseTag = [string]$toolManifest.releaseTag
    $repository = [string]$toolManifest.repository
    $assetName = [string]$asset.assetName
    $sha256 = ([string]$asset.sha256).ToLowerInvariant()
    $kind = [string]$asset.kind
    $version = [string]$toolManifest.version
    $versionPattern = [string]$toolManifest.versionPattern
    $executableBaseName = [string]$toolManifest.executableBaseName
    $executableName = Get-NativeQualityExecutableName -ExecutableBaseName $executableBaseName -OperatingSystem $OperatingSystem
    $versionArguments = @(Get-NativeQualityVersionArguments -ToolManifest $toolManifest)

    if ([string]::IsNullOrWhiteSpace($repository) -or [string]::IsNullOrWhiteSpace($releaseTag) -or [string]::IsNullOrWhiteSpace($assetName) -or [string]::IsNullOrWhiteSpace($sha256)) {
        throw "E_NATIVE_TOOL_MANIFEST_INVALID: $ToolName asset '$assetKey' is missing repository, releaseTag, assetName, or sha256."
    }

    if ($sha256 -notmatch '^[a-f0-9]{64}$') {
        throw "E_NATIVE_TOOL_MANIFEST_INVALID: $ToolName asset '$assetKey' has invalid sha256 '$sha256'."
    }

    return [pscustomobject]@{
        ToolName          = $ToolName
        Version           = $version
        VersionPattern    = $versionPattern
        VersionArguments  = $versionArguments
        Repository        = $repository
        ReleaseTag        = $releaseTag
        AssetKey          = $assetKey
        RequestedAssetKey = $requestedAssetKey
        AssetName         = $assetName
        Sha256            = $sha256
        Kind              = $kind
        ExecutableName    = $executableName
        DownloadUrl       = "https://github.com/$repository/releases/download/$releaseTag/$assetName"
        FallbackReason    = $fallbackReason
    }
}

function Get-NativeQualityToolInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec
    )

    $toolRoot = Join-Path -Path $RepositoryRoot -ChildPath $script:NativeQualityToolRootName
    $toolVersionRoot = Join-Path -Path $toolRoot -ChildPath $AssetSpec.ToolName
    $versionRoot = Join-Path -Path $toolVersionRoot -ChildPath $AssetSpec.Version
    return Join-Path -Path $versionRoot -ChildPath $AssetSpec.AssetKey
}

function Get-NativeQualityToolExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec
    )

    return Join-Path -Path (Join-Path -Path $InstallRoot -ChildPath "bin") -ChildPath $AssetSpec.ExecutableName
}

function Invoke-NativeQualityCapturedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory = (Get-Location).Path,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 900)]
        [int]$TimeoutSeconds = 30
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $FilePath
    $processStartInfo.WorkingDirectory = $WorkingDirectory
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true

    foreach ($argument in @($ArgumentList)) {
        [void]$processStartInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-Verbose "Failed to kill timed-out process '$FilePath': $($_.Exception.Message)"
            }

            throw "E_NATIVE_TOOL_PROCESS_TIMEOUT: process '$FilePath' exceeded ${TimeoutSeconds}s."
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.GetAwaiter().GetResult()
            Stderr   = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-NativeQualityProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 900)]
        [int]$TimeoutSeconds = 300
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $FilePath
    $processStartInfo.WorkingDirectory = $WorkingDirectory
    $processStartInfo.UseShellExecute = $false

    foreach ($argument in @($ArgumentList)) {
        [void]$processStartInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        [void]$process.Start()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-Verbose "Failed to kill timed-out process '$FilePath': $($_.Exception.Message)"
            }

            throw "E_NATIVE_TOOL_PROCESS_TIMEOUT: process '$FilePath' exceeded ${TimeoutSeconds}s."
        }

        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Assert-NativeQualityToolVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $versionResult = Invoke-NativeQualityCapturedProcess -FilePath $ExecutablePath -ArgumentList $AssetSpec.VersionArguments -WorkingDirectory $RepositoryRoot -TimeoutSeconds 30
    $combinedOutput = @($versionResult.Stdout, $versionResult.Stderr) -join [Environment]::NewLine
    if ($versionResult.ExitCode -ne 0) {
        throw "E_NATIVE_TOOL_VERSION_FAILED: $($AssetSpec.ToolName) version probe failed (exitCode=$($versionResult.ExitCode); executable='$ExecutablePath'; output=$combinedOutput)."
    }

    if ($combinedOutput -notmatch $AssetSpec.VersionPattern) {
        throw "E_NATIVE_TOOL_VERSION_MISMATCH: $($AssetSpec.ToolName) executable '$ExecutablePath' did not report expected version '$($AssetSpec.Version)' (output=$combinedOutput)."
    }
}

function Test-NativeQualityToolReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $executablePath = Get-NativeQualityToolExecutablePath -InstallRoot $InstallRoot -AssetSpec $AssetSpec
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        return $false
    }

    $markerPath = Join-Path -Path $InstallRoot -ChildPath "asset.json"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Write-Verbose "$($AssetSpec.ToolName) marker file is missing at '$markerPath'; reinstalling."
        return $false
    }

    try {
        $markerContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $markerPath -ErrorAction Stop).Path, [System.Text.Encoding]::UTF8)
        $marker = ConvertFrom-JsonSingleObject -Json $markerContent -Context "$($AssetSpec.ToolName) native quality asset marker"
        if ([string]$marker.assetName -ne $AssetSpec.AssetName -or [string]$marker.sha256 -ne $AssetSpec.Sha256) {
            Write-Verbose "$($AssetSpec.ToolName) marker does not match pinned manifest; reinstalling."
            return $false
        }

        Assert-NativeQualityToolVersion -ExecutablePath $executablePath -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot
        return $true
    }
    catch {
        Write-Verbose "$($AssetSpec.ToolName) existing tool validation failed: $($_.Exception.Message)"
        return $false
    }
}

function Assert-NativeQualityHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [string]$ToolName
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "E_NATIVE_TOOL_HASH_MISMATCH: downloaded $ToolName asset hash mismatch (expected=$ExpectedSha256; actual=$actualHash; path='$Path')."
    }
}

function Test-NativeQualityArchiveEntryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryPath
    )

    if ([string]::IsNullOrWhiteSpace($EntryPath)) {
        return $false
    }

    $normalizedEntryPath = $EntryPath -replace '\\', '/'
    if ($normalizedEntryPath.StartsWith('/')) {
        return $false
    }

    if ($normalizedEntryPath -match '^[A-Za-z]:' -or $normalizedEntryPath -match ':') {
        return $false
    }

    foreach ($segment in @($normalizedEntryPath -split '/')) {
        if ($segment -eq '..') {
            return $false
        }
    }

    return $true
}

function Test-NativeQualityZipEntryIsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchiveEntry]$Entry
    )

    $unixMode = ($Entry.ExternalAttributes -shr 16) -band 0xF000
    return ($unixMode -eq 0xA000)
}

function Test-NativeQualityFileSystemItemIsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.IO.FileSystemInfo]$Item
    )

    $linkTypeProperty = $Item.PSObject.Properties['LinkType']
    $hasLinkType = ($null -ne $linkTypeProperty -and -not [string]::IsNullOrWhiteSpace([string]$Item.LinkType))
    $hasReparsePointAttribute = (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    return ($hasLinkType -or $hasReparsePointAttribute)
}

function Assert-NativeQualityZipSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in @($zipArchive.Entries)) {
            if (-not (Test-NativeQualityArchiveEntryPath -EntryPath $entry.FullName)) {
                throw "E_NATIVE_TOOL_ARCHIVE_UNSAFE: zip asset contains unsafe entry '$($entry.FullName)'."
            }

            if (Test-NativeQualityZipEntryIsLinkLike -Entry $entry) {
                throw "E_NATIVE_TOOL_ARCHIVE_UNSAFE: zip asset contains symlink-like entry '$($entry.FullName)'."
            }
        }
    }
    finally {
        $zipArchive.Dispose()
    }
}

function Get-NativeQualityTarExecutableOrThrow {
    $tarCommand = Get-Command -Name "tar" -ErrorAction SilentlyContinue
    if ($null -eq $tarCommand) {
        throw "E_NATIVE_TOOL_TAR_NOT_AVAILABLE: tar is required to extract pinned native quality archives on this platform but was not found on PATH."
    }

    return $tarCommand.Source
}

function Test-NativeQualityTarMetadataLineSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetadataLine
    )

    if ([string]::IsNullOrWhiteSpace($MetadataLine)) {
        return $true
    }

    $entryType = $MetadataLine[0]
    return ($entryType -eq '-' -or $entryType -eq 'd')
}

function Assert-NativeQualityTarSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    $tarExecutable = Get-NativeQualityTarExecutableOrThrow
    $listResult = Invoke-NativeQualityCapturedProcess -FilePath $tarExecutable -ArgumentList @("-tzf", $ArchivePath) -TimeoutSeconds 60
    if ($listResult.ExitCode -ne 0) {
        $combinedOutput = @($listResult.Stdout, $listResult.Stderr) -join [Environment]::NewLine
        throw "E_NATIVE_TOOL_ARCHIVE_LIST_FAILED: unable to list tar asset '$ArchivePath' (exitCode=$($listResult.ExitCode); output=$combinedOutput)."
    }

    foreach ($entry in @($listResult.Stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        if (-not (Test-NativeQualityArchiveEntryPath -EntryPath $entry)) {
            throw "E_NATIVE_TOOL_ARCHIVE_UNSAFE: tar asset contains unsafe entry '$entry'."
        }
    }

    $verboseListResult = Invoke-NativeQualityCapturedProcess -FilePath $tarExecutable -ArgumentList @("-tvzf", $ArchivePath) -TimeoutSeconds 60
    if ($verboseListResult.ExitCode -ne 0) {
        $combinedOutput = @($verboseListResult.Stdout, $verboseListResult.Stderr) -join [Environment]::NewLine
        throw "E_NATIVE_TOOL_ARCHIVE_LIST_FAILED: unable to list tar asset metadata '$ArchivePath' (exitCode=$($verboseListResult.ExitCode); output=$combinedOutput)."
    }

    foreach ($metadataLine in @($verboseListResult.Stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($metadataLine)) {
            continue
        }

        if (-not (Test-NativeQualityTarMetadataLineSafe -MetadataLine $metadataLine)) {
            throw "E_NATIVE_TOOL_ARCHIVE_UNSAFE: tar asset contains unsupported entry type '$metadataLine'."
        }
    }
}

function Expand-NativeQualityTarGz {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Assert-NativeQualityTarSafe -ArchivePath $ArchivePath
    $tarExecutable = Get-NativeQualityTarExecutableOrThrow
    $extractResult = Invoke-NativeQualityCapturedProcess -FilePath $tarExecutable -ArgumentList @("-xzf", $ArchivePath, "-C", $DestinationPath) -TimeoutSeconds 120
    if ($extractResult.ExitCode -ne 0) {
        $combinedOutput = @($extractResult.Stdout, $extractResult.Stderr) -join [Environment]::NewLine
        throw "E_NATIVE_TOOL_ARCHIVE_EXTRACT_FAILED: unable to extract tar asset '$ArchivePath' (exitCode=$($extractResult.ExitCode); output=$combinedOutput)."
    }
}

function Copy-NativeQualityExecutableFromArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractRoot,

        [Parameter(Mandatory = $true)]
        [string]$BinRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec
    )

    $candidateExecutables = @(
        Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Name -eq $AssetSpec.ExecutableName } |
            Sort-Object FullName
    )

    if ($candidateExecutables.Count -eq 0) {
        throw "E_NATIVE_TOOL_ARCHIVE_EXECUTABLE_MISSING: $($AssetSpec.AssetName) did not contain '$($AssetSpec.ExecutableName)'."
    }

    if ($candidateExecutables.Count -gt 1) {
        throw "E_NATIVE_TOOL_ARCHIVE_AMBIGUOUS: $($AssetSpec.AssetName) contained multiple '$($AssetSpec.ExecutableName)' files."
    }

    if (Test-NativeQualityFileSystemItemIsLinkLike -Item $candidateExecutables[0]) {
        throw "E_NATIVE_TOOL_ARCHIVE_UNSAFE: $($AssetSpec.AssetName) contained link-like executable '$($candidateExecutables[0].FullName)'."
    }

    New-Item -Path $BinRoot -ItemType Directory -Force | Out-Null
    $targetPath = Join-Path -Path $BinRoot -ChildPath $AssetSpec.ExecutableName
    Copy-Item -LiteralPath $candidateExecutables[0].FullName -Destination $targetPath -Force
    return $targetPath
}

function Set-NativeQualityExecutableMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath
    )

    if ($IsWindows) {
        return
    }

    $chmodCommand = Get-Command -Name "chmod" -ErrorAction SilentlyContinue
    if ($null -eq $chmodCommand) {
        throw "E_NATIVE_TOOL_CHMOD_NOT_AVAILABLE: chmod is required to mark '$ExecutablePath' executable on this platform."
    }

    $chmodResult = Invoke-NativeQualityCapturedProcess -FilePath $chmodCommand.Source -ArgumentList @("755", $ExecutablePath) -TimeoutSeconds 30
    if ($chmodResult.ExitCode -ne 0) {
        $combinedOutput = @($chmodResult.Stdout, $chmodResult.Stderr) -join [Environment]::NewLine
        throw "E_NATIVE_TOOL_CHMOD_FAILED: chmod failed for '$ExecutablePath' (exitCode=$($chmodResult.ExitCode); output=$combinedOutput)."
    }
}

function Save-NativeQualityAssetMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec
    )

    $markerPath = Join-Path -Path $InstallRoot -ChildPath "asset.json"
    $marker = [ordered]@{
        tool              = $AssetSpec.ToolName
        version           = $AssetSpec.Version
        repository        = $AssetSpec.Repository
        releaseTag        = $AssetSpec.ReleaseTag
        assetKey          = $AssetSpec.AssetKey
        requestedAssetKey = $AssetSpec.RequestedAssetKey
        assetName         = $AssetSpec.AssetName
        sha256            = $AssetSpec.Sha256
        downloadUrl       = $AssetSpec.DownloadUrl
    }
    $markerJson = ($marker | ConvertTo-Json -Depth 4) + [Environment]::NewLine
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($markerPath, $markerJson, $utf8NoBom)
}

function Invoke-NativeQualityDownload {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$DownloadPath
    )

    $previousProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    $lastErrorMessage = ""
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-Host "[native-quality] Downloading $($AssetSpec.ToolName) $($AssetSpec.Version) from $($AssetSpec.DownloadUrl)"
                Invoke-WebRequest -Uri $AssetSpec.DownloadUrl -OutFile $DownloadPath -TimeoutSec $script:NativeQualityDownloadTimeoutSeconds -ErrorAction Stop
                return
            }
            catch {
                $lastErrorMessage = $_.Exception.Message
                if ($attempt -lt 3) {
                    Write-Verbose "Native quality download attempt $attempt failed for $($AssetSpec.ToolName): $lastErrorMessage"
                    Start-Sleep -Seconds ([int[]]@(2, 5)[$attempt - 1])
                }
            }
        }

        throw "E_NATIVE_TOOL_DOWNLOAD_FAILED: failed to download $($AssetSpec.ToolName) asset '$($AssetSpec.AssetName)' from '$($AssetSpec.DownloadUrl)': $lastErrorMessage"
    }
    finally {
        $global:ProgressPreference = $previousProgressPreference
    }
}

function Install-NativeQualityToolAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $toolRoot = Split-Path -Path (Split-Path -Path $InstallRoot -Parent) -Parent
    New-Item -Path $toolRoot -ItemType Directory -Force | Out-Null
    New-Item -Path (Split-Path -Path $InstallRoot -Parent) -ItemType Directory -Force | Out-Null

    $stagingRoot = Join-Path -Path $toolRoot -ChildPath ("staging-{0}" -f [guid]::NewGuid().ToString("N"))
    $downloadRoot = Join-Path -Path $toolRoot -ChildPath ".downloads"
    New-Item -Path $stagingRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $downloadRoot -ItemType Directory -Force | Out-Null

    try {
        $downloadPath = Join-Path -Path $downloadRoot -ChildPath ("{0}-{1}" -f [guid]::NewGuid().ToString("N"), $AssetSpec.AssetName)
        Invoke-NativeQualityDownload -AssetSpec $AssetSpec -DownloadPath $downloadPath
        Assert-NativeQualityHash -Path $downloadPath -ExpectedSha256 $AssetSpec.Sha256 -ToolName $AssetSpec.ToolName

        $binRoot = Join-Path -Path $stagingRoot -ChildPath "bin"
        if ($AssetSpec.Kind -eq "executable") {
            New-Item -Path $binRoot -ItemType Directory -Force | Out-Null
            $executablePath = Join-Path -Path $binRoot -ChildPath $AssetSpec.ExecutableName
            Copy-Item -LiteralPath $downloadPath -Destination $executablePath -Force
        }
        elseif ($AssetSpec.Kind -eq "zip") {
            Assert-NativeQualityZipSafe -ArchivePath $downloadPath
            $extractRoot = Join-Path -Path $stagingRoot -ChildPath "extract"
            New-Item -Path $extractRoot -ItemType Directory -Force | Out-Null
            Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractRoot -Force
            $executablePath = Copy-NativeQualityExecutableFromArchive -ExtractRoot $extractRoot -BinRoot $binRoot -AssetSpec $AssetSpec
        }
        elseif ($AssetSpec.Kind -eq "tar.gz") {
            $extractRoot = Join-Path -Path $stagingRoot -ChildPath "extract"
            New-Item -Path $extractRoot -ItemType Directory -Force | Out-Null
            Expand-NativeQualityTarGz -ArchivePath $downloadPath -DestinationPath $extractRoot
            $executablePath = Copy-NativeQualityExecutableFromArchive -ExtractRoot $extractRoot -BinRoot $binRoot -AssetSpec $AssetSpec
        }
        else {
            throw "E_NATIVE_TOOL_MANIFEST_INVALID: unsupported asset kind '$($AssetSpec.Kind)' for $($AssetSpec.ToolName)."
        }

        Set-NativeQualityExecutableMode -ExecutablePath $executablePath
        Assert-NativeQualityToolVersion -ExecutablePath $executablePath -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot
        Save-NativeQualityAssetMarker -InstallRoot $stagingRoot -AssetSpec $AssetSpec

        if (Test-Path -LiteralPath $InstallRoot) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        }
        Move-Item -LiteralPath $stagingRoot -Destination $InstallRoot
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-NativeQualityInstallLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lockAcquired = $false
    while (-not $lockAcquired) {
        try {
            New-Item -Path $LockPath -ItemType Directory -ErrorAction Stop | Out-Null
            $lockAcquired = $true
        }
        catch {
            if ($stopwatch.Elapsed.TotalSeconds -ge $script:NativeQualityLockTimeoutSeconds) {
                throw "E_NATIVE_TOOL_LOCK_TIMEOUT: timed out waiting for native tool install lock '$LockPath'."
            }

            Start-Sleep -Milliseconds $script:NativeQualityLockRetryMilliseconds
        }
    }

    try {
        & $ScriptBlock
    }
    finally {
        Remove-Item -LiteralPath $LockPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-NativeQualityToolExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,

        [Parameter(Mandatory = $true)]
        [ValidateSet("stylua", "actionlint")]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $operatingSystem = Get-NativeQualityOperatingSystemName
    $architecture = ConvertTo-NativeQualityArchitectureName -Architecture ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)
    $assetSpec = Resolve-NativeQualityAssetSpec -Manifest $Manifest -ToolName $ToolName -OperatingSystem $operatingSystem -Architecture $architecture
    if (-not [string]::IsNullOrWhiteSpace($assetSpec.FallbackReason)) {
        Write-Warning "W_NATIVE_TOOL_PLATFORM_FALLBACK: $($assetSpec.FallbackReason)."
    }

    $installRoot = Get-NativeQualityToolInstallRoot -RepositoryRoot $RepositoryRoot -AssetSpec $assetSpec
    if (Test-NativeQualityToolReady -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot) {
        return Get-NativeQualityToolExecutablePath -InstallRoot $installRoot -AssetSpec $assetSpec
    }

    New-Item -Path (Split-Path -Path $installRoot -Parent) -ItemType Directory -Force | Out-Null
    $lockPath = "$installRoot.lock"
    Invoke-NativeQualityInstallLock -LockPath $lockPath -ScriptBlock {
        if (-not (Test-NativeQualityToolReady -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot)) {
            Install-NativeQualityToolAsset -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot
        }
    }

    if (-not (Test-NativeQualityToolReady -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot)) {
        throw "E_NATIVE_TOOL_INSTALL_FAILED: $ToolName was not ready after automated install at '$installRoot'."
    }

    return Get-NativeQualityToolExecutablePath -InstallRoot $installRoot -AssetSpec $assetSpec
}

function Resolve-NativeQualityTargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$InputFiles = @()
    )

    $targets = New-Object 'System.Collections.Generic.List[string]'
    $repositoryRootFullPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $repositoryRootWithSeparator = $repositoryRootFullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

    foreach ($inputFile in @($InputFiles)) {
        if ([string]::IsNullOrWhiteSpace($inputFile)) {
            continue
        }

        $candidatePath = if ([System.IO.Path]::IsPathRooted($inputFile)) {
            [System.IO.Path]::GetFullPath($inputFile)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path -Path $RepositoryRoot -ChildPath $inputFile))
        }

        if ($candidatePath -ne $repositoryRootFullPath -and -not $candidatePath.StartsWith($repositoryRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "E_NATIVE_QUALITY_TARGET_OUTSIDE_REPOSITORY: native quality target '$inputFile' resolves outside repository root '$RepositoryRoot'."
        }

        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            Write-Verbose "Skipping non-existent native quality target '$inputFile'."
            continue
        }

        [void]$targets.Add($candidatePath)
    }

    $invariantCultureName = [System.Globalization.CultureInfo]::InvariantCulture.Name
    return @($targets.ToArray() | Sort-Object -Unique -Culture $invariantCultureName)
}

function ConvertTo-NativeQualityRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ([System.IO.Path]::GetRelativePath($RepositoryRoot, $Path) -replace '[\\/]+', '/')
}

function Test-NativeQualityTargetMatchesTool {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("stylua", "actionlint")]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $relativePath = ConvertTo-NativeQualityRelativePath -RepositoryRoot $RepositoryRoot -Path $Path
    if ($ToolName -eq "stylua") {
        return ($relativePath -eq "Config/Wezterm/wezterm.lua")
    }

    if ($ToolName -eq "actionlint") {
        return ($relativePath -match '^\.github/workflows/.+\.(yml|yaml)$')
    }

    return $false
}

function Select-NativeQualityToolTargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("stylua", "actionlint")]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$Files = @(),

        [Parameter(Mandatory = $true)]
        [bool]$FilterForTool
    )

    if (-not $FilterForTool) {
        return @($Files)
    }

    return @(
        foreach ($file in @($Files)) {
            if (Test-NativeQualityTargetMatchesTool -ToolName $ToolName -RepositoryRoot $RepositoryRoot -Path $file) {
                $file
            }
        }
    )
}

function Invoke-StyluaQualityCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Files,

        [Parameter(Mandatory = $true)]
        [bool]$ApplyFix
    )

    $configPath = Join-Path -Path $RepositoryRoot -ChildPath ".stylua.toml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "E_STYLUA_CONFIG_MISSING: .stylua.toml not found at '$configPath'."
    }

    $arguments = @()
    if (-not $ApplyFix) {
        $arguments += "--check"
    }
    $arguments += @("--config-path", ".stylua.toml")

    foreach ($file in @($Files)) {
        $arguments += (ConvertTo-NativeQualityRelativePath -RepositoryRoot $RepositoryRoot -Path $file)
    }

    $exitCode = Invoke-NativeQualityProcess -FilePath $ExecutablePath -ArgumentList $arguments -WorkingDirectory $RepositoryRoot
    if ($exitCode -ne 0) {
        if ($ApplyFix) {
            throw "E_STYLUA_FAILED: stylua failed while formatting selected Lua target(s) (exitCode=$exitCode)."
        }

        throw "E_STYLUA_FORMAT_REQUIRED: stylua found formatting drift in selected Lua target(s) (exitCode=$exitCode). Run this script with -Tool stylua -Fix."
    }
}

function Invoke-ActionlintQualityCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Files
    )

    $arguments = @()
    foreach ($file in @($Files)) {
        $arguments += (ConvertTo-NativeQualityRelativePath -RepositoryRoot $RepositoryRoot -Path $file)
    }

    $exitCode = Invoke-NativeQualityProcess -FilePath $ExecutablePath -ArgumentList $arguments -WorkingDirectory $RepositoryRoot
    if ($exitCode -ne 0) {
        throw "E_ACTIONLINT_FAILED: actionlint failed for selected GitHub workflow target(s) (exitCode=$exitCode)."
    }
}

function Invoke-NativeQualityChecksMain {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("All", "stylua", "actionlint")]
        [string]$SelectedTool,

        [Parameter(Mandatory = $true)]
        [bool]$ApplyFix,

        [Parameter(Mandatory = $true)]
        [bool]$OnlyEnsureTools,

        [Parameter(Mandatory = $false)]
        [string[]]$InputFiles = @()
    )

    $repositoryRoot = Get-NativeQualityRepositoryRoot
    $manifest = Read-NativeQualityToolManifest
    $toolNames = if ($SelectedTool -eq "All") { @("stylua", "actionlint") } else { @($SelectedTool) }
    $toolExecutables = @{}

    foreach ($toolName in $toolNames) {
        $toolExecutables[$toolName] = Resolve-NativeQualityToolExecutable -Manifest $manifest -ToolName $toolName -RepositoryRoot $repositoryRoot
    }

    if ($OnlyEnsureTools) {
        Write-Host "[native-quality] Native quality tools are ready."
        return
    }

    $targetPaths = @(Resolve-NativeQualityTargetFiles -RepositoryRoot $repositoryRoot -InputFiles $InputFiles)
    if ($targetPaths.Count -eq 0) {
        Write-Host "[native-quality] No existing native quality targets selected; skipping."
        return
    }

    $filterForTool = ($SelectedTool -eq "All")
    if ($toolExecutables.ContainsKey("stylua")) {
        $styluaTargets = @(Select-NativeQualityToolTargetFiles -ToolName stylua -RepositoryRoot $repositoryRoot -Files $targetPaths -FilterForTool $filterForTool)
        if ($styluaTargets.Count -gt 0) {
            Invoke-StyluaQualityCheck -ExecutablePath $toolExecutables["stylua"] -RepositoryRoot $repositoryRoot -Files $styluaTargets -ApplyFix $ApplyFix
        }
    }

    if ($toolExecutables.ContainsKey("actionlint")) {
        $actionlintTargets = @(Select-NativeQualityToolTargetFiles -ToolName actionlint -RepositoryRoot $repositoryRoot -Files $targetPaths -FilterForTool $filterForTool)
        if ($actionlintTargets.Count -gt 0) {
            Invoke-ActionlintQualityCheck -ExecutablePath $toolExecutables["actionlint"] -RepositoryRoot $repositoryRoot -Files $actionlintTargets
        }
    }
}

if (-not $NoInvokeMain) {
    Invoke-NativeQualityChecksMain -SelectedTool $Tool -ApplyFix:$Fix.IsPresent -OnlyEnsureTools:$EnsureOnly.IsPresent -InputFiles $TargetFiles
}
