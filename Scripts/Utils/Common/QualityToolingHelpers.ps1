# QualityToolingHelpers.ps1
#
# Single-source shared infrastructure for the shell-quality (shfmt/shellcheck) and
# native-quality (StyLua/actionlint) tooling scripts. Dot-source this file after
# StrictModeHelpers.ps1; it defines functions only and performs no top-level side effects.
#
# Tool-suite-specific behavior is parameterized through a context object built by
# New-QualityToolingContext. All generic functions accept a -Context object and emit
# stable diagnostic codes derived from $Context.DiagnosticPrefix and
# $Context.TargetDiagnosticPrefix so the consuming scripts keep verbatim error strings.

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'CompatibilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $compatibilityHelpersPath

function New-QualityToolingContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DiagnosticPrefix,

        [Parameter(Mandatory = $true)]
        [string]$TargetDiagnosticPrefix,

        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,

        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [string]$ToolRootName,

        [Parameter(Mandatory = $true)]
        [int]$DownloadTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [string]$ToolSuiteLabel,

        [Parameter(Mandatory = $true)]
        [string]$ManifestContextLabel,

        [Parameter(Mandatory = $true)]
        [string]$MarkerContextLabel
    )

    return [pscustomobject]@{
        DiagnosticPrefix       = $DiagnosticPrefix
        TargetDiagnosticPrefix = $TargetDiagnosticPrefix
        LogPrefix              = $LogPrefix
        ManifestPath           = $ManifestPath
        ToolRootName           = $ToolRootName
        DownloadTimeoutSeconds = $DownloadTimeoutSeconds
        ToolSuiteLabel         = $ToolSuiteLabel
        ManifestContextLabel   = $ManifestContextLabel
        MarkerContextLabel     = $MarkerContextLabel
    }
}

function Read-QualityToolingManifest {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $false)]
        [string]$ManifestPath
    )

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = $Context.ManifestPath
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "E_$($Context.DiagnosticPrefix)_MANIFEST_MISSING: $($Context.ManifestContextLabel) not found at '$ManifestPath'."
    }

    $manifestContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path, [System.Text.Encoding]::UTF8)
    $manifest = ConvertFrom-JsonSingleObject -Json $manifestContent -Context $Context.ManifestContextLabel
    if ($null -eq $manifest.tools) {
        throw "E_$($Context.DiagnosticPrefix)_MANIFEST_INVALID: manifest '$ManifestPath' does not define a tools object."
    }

    return $manifest
}

function ConvertTo-QualityToolingArchitectureName {
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

function Get-QualityToolingOperatingSystemName {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context
    )

    if (Test-IsWindowsPlatform) {
        return "windows"
    }

    if (Test-IsMacOSPlatform) {
        return "darwin"
    }

    if (Test-IsLinuxPlatform) {
        return "linux"
    }

    throw "E_$($Context.DiagnosticPrefix)_PLATFORM_UNSUPPORTED: unsupported operating system for $($Context.ToolSuiteLabel) quality tools."
}

function Get-QualityToolingExecutableName {
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

function Get-QualityToolingAssetProperty {
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

function Get-QualityToolingVersionArguments {
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

function Resolve-QualityToolingAssetSpec {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("darwin", "linux", "windows")]
        [string]$OperatingSystem,

        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    $toolProperty = $Manifest.tools.PSObject.Properties[$ToolName]
    if ($null -eq $toolProperty) {
        throw "E_$($Context.DiagnosticPrefix)_MANIFEST_INVALID: manifest does not define tool '$ToolName'."
    }

    $toolManifest = $toolProperty.Value
    $requestedAssetKey = "$OperatingSystem-$Architecture"
    $asset = Get-QualityToolingAssetProperty -ToolManifest $toolManifest -AssetKey $requestedAssetKey
    $assetKey = $requestedAssetKey
    $fallbackReason = ""

    if ($null -eq $asset -and $OperatingSystem -eq "windows" -and $Architecture -eq "arm64") {
        $assetKey = "windows-x64"
        $asset = Get-QualityToolingAssetProperty -ToolManifest $toolManifest -AssetKey $assetKey
        if ($null -ne $asset) {
            $fallbackReason = "upstream publishes no Windows ARM64 $ToolName asset; using the pinned Windows x64 asset under Windows ARM64 emulation"
        }
    }

    if ($null -eq $asset) {
        $supportedAssets = @($toolManifest.assets.PSObject.Properties.Name | Sort-Object -Culture ([System.Globalization.CultureInfo]::InvariantCulture.Name)) -join ", "
        throw "E_$($Context.DiagnosticPrefix)_PLATFORM_UNSUPPORTED: $ToolName does not have a pinned asset for platform '$requestedAssetKey' (supportedAssets=$supportedAssets)."
    }

    $releaseTag = [string]$toolManifest.releaseTag
    $repository = [string]$toolManifest.repository
    $assetName = [string]$asset.assetName
    $sha256 = ([string]$asset.sha256).ToLowerInvariant()
    $kind = [string]$asset.kind
    $version = [string]$toolManifest.version
    $versionPattern = [string]$toolManifest.versionPattern
    $executableBaseName = [string]$toolManifest.executableBaseName
    $executableName = Get-QualityToolingExecutableName -ExecutableBaseName $executableBaseName -OperatingSystem $OperatingSystem
    $versionArguments = @(Get-QualityToolingVersionArguments -ToolManifest $toolManifest)

    if ([string]::IsNullOrWhiteSpace($repository) -or [string]::IsNullOrWhiteSpace($releaseTag) -or [string]::IsNullOrWhiteSpace($assetName) -or [string]::IsNullOrWhiteSpace($sha256)) {
        throw "E_$($Context.DiagnosticPrefix)_MANIFEST_INVALID: $ToolName asset '$assetKey' is missing repository, releaseTag, assetName, or sha256."
    }

    if ($sha256 -notmatch '^[a-f0-9]{64}$') {
        throw "E_$($Context.DiagnosticPrefix)_MANIFEST_INVALID: $ToolName asset '$assetKey' has invalid sha256 '$sha256'."
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

function Get-QualityToolingInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec
    )

    $toolRoot = Join-Path -Path $RepositoryRoot -ChildPath $Context.ToolRootName
    $toolVersionRoot = Join-Path -Path $toolRoot -ChildPath $AssetSpec.ToolName
    $versionRoot = Join-Path -Path $toolVersionRoot -ChildPath $AssetSpec.Version
    return Join-Path -Path $versionRoot -ChildPath $AssetSpec.AssetKey
}

function Get-QualityToolingExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec
    )

    return Join-Path -Path (Join-Path -Path $InstallRoot -ChildPath "bin") -ChildPath $AssetSpec.ExecutableName
}

function Invoke-QualityToolingCapturedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

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

    # ProcessStartInfo.ArgumentList is .NET Core-only; Set-PortableProcessArguments populates
    # it on PowerShell 7+ and falls back to an equivalently escaped .Arguments string on
    # Windows PowerShell 5.1 (.NET Framework), where ArgumentList does not exist.
    Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList $ArgumentList

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Failed to kill timed-out process '$FilePath': $($_.Exception.Message)"
            }

            throw "E_$($Context.DiagnosticPrefix)_PROCESS_TIMEOUT: process '$FilePath' exceeded ${TimeoutSeconds}s."
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

function Invoke-QualityToolingProcess {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

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

    # ProcessStartInfo.ArgumentList is .NET Core-only; see Set-PortableProcessArguments.
    Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList $ArgumentList

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        [void]$process.Start()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Failed to kill timed-out process '$FilePath': $($_.Exception.Message)"
            }

            throw "E_$($Context.DiagnosticPrefix)_PROCESS_TIMEOUT: process '$FilePath' exceeded ${TimeoutSeconds}s."
        }

        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Assert-QualityToolingToolVersion {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $versionArguments = if ($null -ne $AssetSpec.PSObject.Properties["VersionArguments"] -and @($AssetSpec.VersionArguments).Count -gt 0) {
        @($AssetSpec.VersionArguments)
    }
    else {
        @("--version")
    }

    $versionResult = Invoke-QualityToolingCapturedProcess -Context $Context -FilePath $ExecutablePath -ArgumentList $versionArguments -WorkingDirectory $RepositoryRoot -TimeoutSeconds 30
    $combinedOutput = @($versionResult.Stdout, $versionResult.Stderr) -join [Environment]::NewLine
    if ($versionResult.ExitCode -ne 0) {
        throw "E_$($Context.DiagnosticPrefix)_VERSION_FAILED: $($AssetSpec.ToolName) version probe failed (exitCode=$($versionResult.ExitCode); executable='$ExecutablePath'; output=$combinedOutput)."
    }

    if ($combinedOutput -notmatch $AssetSpec.VersionPattern) {
        throw "E_$($Context.DiagnosticPrefix)_VERSION_MISMATCH: $($AssetSpec.ToolName) executable '$ExecutablePath' did not report expected version '$($AssetSpec.Version)' (output=$combinedOutput)."
    }
}

function Test-QualityToolingToolReady {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $executablePath = Get-QualityToolingExecutablePath -InstallRoot $InstallRoot -AssetSpec $AssetSpec
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
        $marker = ConvertFrom-JsonSingleObject -Json $markerContent -Context "$($AssetSpec.ToolName) $($Context.MarkerContextLabel)"
        if ([string]$marker.assetName -ne $AssetSpec.AssetName -or [string]$marker.sha256 -ne $AssetSpec.Sha256) {
            Write-Verbose "$($AssetSpec.ToolName) marker does not match pinned manifest; reinstalling."
            return $false
        }

        Assert-QualityToolingToolVersion -Context $Context -ExecutablePath $executablePath -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot
        return $true
    }
    catch {
        Write-Verbose "$($AssetSpec.ToolName) existing tool validation failed: $($_.Exception.Message)"
        return $false
    }
}

function Assert-QualityToolingHash {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [string]$ToolName
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "E_$($Context.DiagnosticPrefix)_HASH_MISMATCH: downloaded $ToolName asset hash mismatch (expected=$ExpectedSha256; actual=$actualHash; path='$Path')."
    }
}

function Test-QualityToolingArchiveEntryPath {
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

function Test-QualityToolingZipEntryIsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchiveEntry]$Entry
    )

    $unixMode = ($Entry.ExternalAttributes -shr 16) -band 0xF000
    return ($unixMode -eq 0xA000)
}

function Test-QualityToolingFileSystemItemIsLinkLike {
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

function Assert-QualityToolingZipSafe {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in @($zipArchive.Entries)) {
            if (-not (Test-QualityToolingArchiveEntryPath -EntryPath $entry.FullName)) {
                throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_UNSAFE: zip asset contains unsafe entry '$($entry.FullName)'."
            }

            if (Test-QualityToolingZipEntryIsLinkLike -Entry $entry) {
                throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_UNSAFE: zip asset contains symlink-like entry '$($entry.FullName)'."
            }
        }
    }
    finally {
        $zipArchive.Dispose()
    }
}

function Get-QualityToolingTarExecutableOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context
    )

    $tarCommand = Get-Command -Name "tar" -ErrorAction SilentlyContinue
    if ($null -eq $tarCommand) {
        throw "E_$($Context.DiagnosticPrefix)_TAR_NOT_AVAILABLE: tar is required to extract pinned $($Context.ToolSuiteLabel) quality archives on this platform but was not found on PATH."
    }

    return $tarCommand.Source
}

function Test-QualityToolingTarMetadataLineSafe {
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

function Assert-QualityToolingTarSafe {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    $tarExecutable = Get-QualityToolingTarExecutableOrThrow -Context $Context
    $listResult = Invoke-QualityToolingCapturedProcess -Context $Context -FilePath $tarExecutable -ArgumentList @("-tzf", $ArchivePath) -TimeoutSeconds 60
    if ($listResult.ExitCode -ne 0) {
        $combinedOutput = @($listResult.Stdout, $listResult.Stderr) -join [Environment]::NewLine
        throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_LIST_FAILED: unable to list tar asset '$ArchivePath' (exitCode=$($listResult.ExitCode); output=$combinedOutput)."
    }

    foreach ($entry in @($listResult.Stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        if (-not (Test-QualityToolingArchiveEntryPath -EntryPath $entry)) {
            throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_UNSAFE: tar asset contains unsafe entry '$entry'."
        }
    }

    $verboseListResult = Invoke-QualityToolingCapturedProcess -Context $Context -FilePath $tarExecutable -ArgumentList @("-tvzf", $ArchivePath) -TimeoutSeconds 60
    if ($verboseListResult.ExitCode -ne 0) {
        $combinedOutput = @($verboseListResult.Stdout, $verboseListResult.Stderr) -join [Environment]::NewLine
        throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_LIST_FAILED: unable to list tar asset metadata '$ArchivePath' (exitCode=$($verboseListResult.ExitCode); output=$combinedOutput)."
    }

    foreach ($metadataLine in @($verboseListResult.Stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($metadataLine)) {
            continue
        }

        if (-not (Test-QualityToolingTarMetadataLineSafe -MetadataLine $metadataLine)) {
            throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_UNSAFE: tar asset contains unsupported entry type '$metadataLine'."
        }
    }
}

function Expand-QualityToolingTarGz {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Assert-QualityToolingTarSafe -Context $Context -ArchivePath $ArchivePath
    $tarExecutable = Get-QualityToolingTarExecutableOrThrow -Context $Context
    $extractResult = Invoke-QualityToolingCapturedProcess -Context $Context -FilePath $tarExecutable -ArgumentList @("-xzf", $ArchivePath, "-C", $DestinationPath) -TimeoutSeconds 120
    if ($extractResult.ExitCode -ne 0) {
        $combinedOutput = @($extractResult.Stdout, $extractResult.Stderr) -join [Environment]::NewLine
        throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_EXTRACT_FAILED: unable to extract tar asset '$ArchivePath' (exitCode=$($extractResult.ExitCode); output=$combinedOutput)."
    }
}

function Copy-QualityToolingExecutableFromArchive {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

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
        throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_EXECUTABLE_MISSING: $($AssetSpec.AssetName) did not contain '$($AssetSpec.ExecutableName)'."
    }

    if ($candidateExecutables.Count -gt 1) {
        throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_AMBIGUOUS: $($AssetSpec.AssetName) contained multiple '$($AssetSpec.ExecutableName)' files."
    }

    if (Test-QualityToolingFileSystemItemIsLinkLike -Item $candidateExecutables[0]) {
        throw "E_$($Context.DiagnosticPrefix)_ARCHIVE_UNSAFE: $($AssetSpec.AssetName) contained link-like executable '$($candidateExecutables[0].FullName)'."
    }

    New-Item -Path $BinRoot -ItemType Directory -Force | Out-Null
    $targetPath = Join-Path -Path $BinRoot -ChildPath $AssetSpec.ExecutableName
    Copy-Item -LiteralPath $candidateExecutables[0].FullName -Destination $targetPath -Force
    return $targetPath
}

function Set-QualityToolingExecutableMode {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath
    )

    if (Test-IsWindowsPlatform) {
        return
    }

    $chmodCommand = Get-Command -Name "chmod" -ErrorAction SilentlyContinue
    if ($null -eq $chmodCommand) {
        throw "E_$($Context.DiagnosticPrefix)_CHMOD_NOT_AVAILABLE: chmod is required to mark '$ExecutablePath' executable on this platform."
    }

    $chmodResult = Invoke-QualityToolingCapturedProcess -Context $Context -FilePath $chmodCommand.Source -ArgumentList @("755", $ExecutablePath) -TimeoutSeconds 30
    if ($chmodResult.ExitCode -ne 0) {
        $combinedOutput = @($chmodResult.Stdout, $chmodResult.Stderr) -join [Environment]::NewLine
        throw "E_$($Context.DiagnosticPrefix)_CHMOD_FAILED: chmod failed for '$ExecutablePath' (exitCode=$($chmodResult.ExitCode); output=$combinedOutput)."
    }
}

function Save-QualityToolingAssetMarker {
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

function Invoke-QualityToolingDownload {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$DownloadPath
    )

    $previousProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    $lastErrorMessage = ""
    $backoffSeconds = @(2, 5)
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-Host "$($Context.LogPrefix) Downloading $($AssetSpec.ToolName) $($AssetSpec.Version) from $($AssetSpec.DownloadUrl)"
                # -UseBasicParsing avoids the Internet Explorer engine dependency on
                # Windows PowerShell 5.1 (no-op on PowerShell 7+).
                Invoke-WebRequest -Uri $AssetSpec.DownloadUrl -OutFile $DownloadPath -TimeoutSec $Context.DownloadTimeoutSeconds -UseBasicParsing -ErrorAction Stop
                return
            }
            catch {
                $lastErrorMessage = $_.Exception.Message
                if ($attempt -lt 3) {
                    Write-Verbose "Quality tool download attempt $attempt failed for $($AssetSpec.ToolName): $lastErrorMessage"
                    Start-Sleep -Seconds $backoffSeconds[$attempt - 1]
                }
            }
        }

        throw "E_$($Context.DiagnosticPrefix)_DOWNLOAD_FAILED: failed to download $($AssetSpec.ToolName) asset '$($AssetSpec.AssetName)' from '$($AssetSpec.DownloadUrl)': $lastErrorMessage"
    }
    finally {
        $global:ProgressPreference = $previousProgressPreference
    }
}

function Install-QualityToolingToolAsset {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [scriptblock]$DownloadCommand
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
        & $DownloadCommand -AssetSpec $AssetSpec -DownloadPath $downloadPath
        Assert-QualityToolingHash -Context $Context -Path $downloadPath -ExpectedSha256 $AssetSpec.Sha256 -ToolName $AssetSpec.ToolName

        $binRoot = Join-Path -Path $stagingRoot -ChildPath "bin"
        if ($AssetSpec.Kind -eq "executable") {
            New-Item -Path $binRoot -ItemType Directory -Force | Out-Null
            $executablePath = Join-Path -Path $binRoot -ChildPath $AssetSpec.ExecutableName
            Copy-Item -LiteralPath $downloadPath -Destination $executablePath -Force
        }
        elseif ($AssetSpec.Kind -eq "zip") {
            Assert-QualityToolingZipSafe -Context $Context -ArchivePath $downloadPath
            $extractRoot = Join-Path -Path $stagingRoot -ChildPath "extract"
            New-Item -Path $extractRoot -ItemType Directory -Force | Out-Null
            Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractRoot -Force
            $executablePath = Copy-QualityToolingExecutableFromArchive -Context $Context -ExtractRoot $extractRoot -BinRoot $binRoot -AssetSpec $AssetSpec
        }
        elseif ($AssetSpec.Kind -eq "tar.gz") {
            $extractRoot = Join-Path -Path $stagingRoot -ChildPath "extract"
            New-Item -Path $extractRoot -ItemType Directory -Force | Out-Null
            Expand-QualityToolingTarGz -Context $Context -ArchivePath $downloadPath -DestinationPath $extractRoot
            $executablePath = Copy-QualityToolingExecutableFromArchive -Context $Context -ExtractRoot $extractRoot -BinRoot $binRoot -AssetSpec $AssetSpec
        }
        else {
            throw "E_$($Context.DiagnosticPrefix)_MANIFEST_INVALID: unsupported asset kind '$($AssetSpec.Kind)' for $($AssetSpec.ToolName)."
        }

        Set-QualityToolingExecutableMode -Context $Context -ExecutablePath $executablePath
        Assert-QualityToolingToolVersion -Context $Context -ExecutablePath $executablePath -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot
        Save-QualityToolingAssetMarker -InstallRoot $stagingRoot -AssetSpec $AssetSpec

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

function Invoke-QualityToolingInstallLock {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$LockPath,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [int]$LockTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int]$LockRetryMilliseconds
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lockAcquired = $false
    while (-not $lockAcquired) {
        try {
            New-Item -Path $LockPath -ItemType Directory -ErrorAction Stop | Out-Null
            $lockAcquired = $true
        }
        catch {
            if ($stopwatch.Elapsed.TotalSeconds -ge $LockTimeoutSeconds) {
                throw "E_$($Context.DiagnosticPrefix)_LOCK_TIMEOUT: timed out waiting for $($Context.ToolSuiteLabel) tool install lock '$LockPath'."
            }

            Start-Sleep -Milliseconds $LockRetryMilliseconds
        }
    }

    try {
        & $ScriptBlock
    }
    finally {
        Remove-Item -LiteralPath $LockPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-QualityToolingToolExecutable {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'RuntimeInformation.ProcessArchitecture is available on .NET Framework 4.7.1+, the floor on all supported Windows PowerShell 5.1 hosts.')]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [scriptblock]$InstallCommand,

        [Parameter(Mandatory = $true)]
        [int]$LockTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int]$LockRetryMilliseconds
    )

    $operatingSystem = Get-QualityToolingOperatingSystemName -Context $Context
    $architecture = ConvertTo-QualityToolingArchitectureName -Architecture ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)
    $assetSpec = Resolve-QualityToolingAssetSpec -Context $Context -Manifest $Manifest -ToolName $ToolName -OperatingSystem $operatingSystem -Architecture $architecture
    if (-not [string]::IsNullOrWhiteSpace($assetSpec.FallbackReason)) {
        Write-Warning "W_$($Context.DiagnosticPrefix)_PLATFORM_FALLBACK: $($assetSpec.FallbackReason)."
    }

    $installRoot = Get-QualityToolingInstallRoot -Context $Context -RepositoryRoot $RepositoryRoot -AssetSpec $assetSpec
    if (Test-QualityToolingToolReady -Context $Context -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot) {
        return Get-QualityToolingExecutablePath -InstallRoot $installRoot -AssetSpec $assetSpec
    }

    New-Item -Path (Split-Path -Path $installRoot -Parent) -ItemType Directory -Force | Out-Null
    $lockPath = "$installRoot.lock"
    Invoke-QualityToolingInstallLock -Context $Context -LockPath $lockPath -LockTimeoutSeconds $LockTimeoutSeconds -LockRetryMilliseconds $LockRetryMilliseconds -ScriptBlock {
        if (-not (Test-QualityToolingToolReady -Context $Context -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot)) {
            & $InstallCommand -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot
        }
    }.GetNewClosure()

    if (-not (Test-QualityToolingToolReady -Context $Context -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $RepositoryRoot)) {
        throw "E_$($Context.DiagnosticPrefix)_INSTALL_FAILED: $ToolName was not ready after automated install at '$installRoot'."
    }

    return Get-QualityToolingExecutablePath -InstallRoot $installRoot -AssetSpec $assetSpec
}

function Resolve-QualityToolingTargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$InputFiles = @()
    )

    $targets = New-Object 'System.Collections.Generic.List[string]'
    $repositoryRootFullPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $repositoryRootWithSeparator = $repositoryRootFullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $pathComparison = if (Test-IsWindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

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

        if (-not [string]::Equals($candidatePath, $repositoryRootFullPath, $pathComparison) -and -not $candidatePath.StartsWith($repositoryRootWithSeparator, $pathComparison)) {
            throw "E_$($Context.TargetDiagnosticPrefix)_TARGET_OUTSIDE_REPOSITORY: $($Context.ToolSuiteLabel) quality target '$inputFile' resolves outside repository root '$RepositoryRoot'."
        }

        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            Write-Verbose "Skipping non-existent quality target '$inputFile'."
            continue
        }

        [void]$targets.Add($candidatePath)
    }

    $invariantCultureName = [System.Globalization.CultureInfo]::InvariantCulture.Name
    return @($targets.ToArray() | Sort-Object -Unique -Culture $invariantCultureName)
}

function ConvertTo-QualityToolingRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ((Get-RelativePathCompat -BasePath $RepositoryRoot -TargetPath $Path) -replace '[\\/]+', '/')
}
