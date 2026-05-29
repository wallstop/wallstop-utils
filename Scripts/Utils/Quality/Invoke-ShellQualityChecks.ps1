[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("All", "shfmt", "shellcheck")]
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

$script:ShellQualityManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "shell-quality-tools.json"
$script:ShellQualityToolRootName = ".tools/shell-quality"
$script:ShellQualityDownloadTimeoutSeconds = 180
$script:ShellQualityLockTimeoutSeconds = 60
$script:ShellQualityLockRetryMilliseconds = 200

if (-not [string]::IsNullOrWhiteSpace($env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS)) {
    if ($env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS -notmatch '^[0-9]+$' -or [int]$env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS -lt 30) {
        throw "E_SHELL_TOOL_TIMEOUT_CONFIG: WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS must be an integer >= 30 seconds (received '$env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS')."
    }

    $script:ShellQualityDownloadTimeoutSeconds = [int]$env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS
}

$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/StrictModeHelpers.ps1"
if (-not (Test-Path -LiteralPath $strictModeHelpersPath -PathType Leaf)) {
    throw "E_SHELL_TOOL_STRICT_MODE_HELPER_MISSING: strict mode helper file not found at '$strictModeHelpersPath'."
}

. $strictModeHelpersPath

$qualityToolingHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/QualityToolingHelpers.ps1"
if (-not (Test-Path -LiteralPath $qualityToolingHelpersPath -PathType Leaf)) {
    throw "E_SHELL_TOOL_QUALITY_HELPER_MISSING: quality tooling helper file not found at '$qualityToolingHelpersPath'."
}

. $qualityToolingHelpersPath

$script:ShellQualityContext = New-QualityToolingContext `
    -DiagnosticPrefix "SHELL_TOOL" `
    -TargetDiagnosticPrefix "SHELL_QUALITY" `
    -LogPrefix "[shell-quality]" `
    -ManifestPath $script:ShellQualityManifestPath `
    -ToolRootName $script:ShellQualityToolRootName `
    -DownloadTimeoutSeconds $script:ShellQualityDownloadTimeoutSeconds `
    -ToolSuiteLabel "shell" `
    -ManifestContextLabel "shell quality tool manifest" `
    -MarkerContextLabel "shell quality asset marker"

function Get-ShellQualityRepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../../..") -ErrorAction Stop).Path
}

function Read-ShellQualityToolManifest {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ManifestPath = $script:ShellQualityManifestPath
    )

    return Read-QualityToolingManifest -Context $script:ShellQualityContext -ManifestPath $ManifestPath
}

function Resolve-ShellQualityAssetSpec {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,

        [Parameter(Mandatory = $true)]
        [ValidateSet("shfmt", "shellcheck")]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("darwin", "linux", "windows")]
        [string]$OperatingSystem,

        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    return Resolve-QualityToolingAssetSpec -Context $script:ShellQualityContext -Manifest $Manifest -ToolName $ToolName -OperatingSystem $OperatingSystem -Architecture $Architecture
}

function Invoke-ShellQualityDownload {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$DownloadPath
    )

    Invoke-QualityToolingDownload -Context $script:ShellQualityContext -AssetSpec $AssetSpec -DownloadPath $DownloadPath
}

function Install-ShellQualityToolAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    Install-QualityToolingToolAsset -Context $script:ShellQualityContext -InstallRoot $InstallRoot -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot -DownloadCommand { param($AssetSpec, $DownloadPath) Invoke-ShellQualityDownload -AssetSpec $AssetSpec -DownloadPath $DownloadPath }
}

function Invoke-ShellQualityInstallLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    Invoke-QualityToolingInstallLock -Context $script:ShellQualityContext -LockPath $LockPath -ScriptBlock $ScriptBlock -LockTimeoutSeconds $script:ShellQualityLockTimeoutSeconds -LockRetryMilliseconds $script:ShellQualityLockRetryMilliseconds
}

function Test-ShellQualityArchiveEntryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryPath
    )

    return Test-QualityToolingArchiveEntryPath -EntryPath $EntryPath
}

function Test-ShellQualityZipEntryIsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchiveEntry]$Entry
    )

    return Test-QualityToolingZipEntryIsLinkLike -Entry $Entry
}

function Test-ShellQualityTarMetadataLineSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetadataLine
    )

    return Test-QualityToolingTarMetadataLineSafe -MetadataLine $MetadataLine
}

function Copy-ShellQualityExecutableFromArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractRoot,

        [Parameter(Mandatory = $true)]
        [string]$BinRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec
    )

    return Copy-QualityToolingExecutableFromArchive -Context $script:ShellQualityContext -ExtractRoot $ExtractRoot -BinRoot $BinRoot -AssetSpec $AssetSpec
}

function Resolve-ShellQualityToolExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,

        [Parameter(Mandatory = $true)]
        [ValidateSet("shfmt", "shellcheck")]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    return Resolve-QualityToolingToolExecutable -Context $script:ShellQualityContext -Manifest $Manifest -ToolName $ToolName -RepositoryRoot $RepositoryRoot -LockTimeoutSeconds $script:ShellQualityLockTimeoutSeconds -LockRetryMilliseconds $script:ShellQualityLockRetryMilliseconds -InstallCommand { param($InstallRoot, $AssetSpec, $RepositoryRoot) Install-ShellQualityToolAsset -InstallRoot $InstallRoot -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot }
}

function Resolve-ShellQualityTargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$InputFiles = @()
    )

    return Resolve-QualityToolingTargetFiles -Context $script:ShellQualityContext -RepositoryRoot $RepositoryRoot -InputFiles $InputFiles
}

function ConvertTo-ShellQualityRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ConvertTo-QualityToolingRelativePath -RepositoryRoot $RepositoryRoot -Path $Path
}

function Invoke-ShfmtQualityCheck {
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

    $arguments = if ($ApplyFix) {
        @("-w", "-i", "2", "-ci", "-sr")
    }
    else {
        @("-d", "-i", "2", "-ci", "-sr")
    }

    foreach ($file in @($Files)) {
        $arguments += (ConvertTo-ShellQualityRelativePath -RepositoryRoot $RepositoryRoot -Path $file)
    }

    $exitCode = Invoke-QualityToolingProcess -Context $script:ShellQualityContext -FilePath $ExecutablePath -ArgumentList $arguments -WorkingDirectory $RepositoryRoot
    if ($exitCode -ne 0) {
        if ($ApplyFix) {
            throw "E_SHFMT_FAILED: shfmt failed while formatting selected shell target(s) (exitCode=$exitCode)."
        }

        throw "E_SHFMT_FORMAT_REQUIRED: shfmt found formatting drift in selected shell target(s) (exitCode=$exitCode). Run this script with -Tool shfmt -Fix."
    }
}

function Invoke-ShellCheckQualityCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Files
    )

    $shellcheckConfigPath = Join-Path -Path $RepositoryRoot -ChildPath ".shellcheckrc"
    if (-not (Test-Path -LiteralPath $shellcheckConfigPath -PathType Leaf)) {
        throw "E_SHELLCHECK_CONFIG_MISSING: .shellcheckrc not found at '$shellcheckConfigPath'."
    }

    $arguments = @("--rcfile", ".shellcheckrc")
    foreach ($file in @($Files)) {
        $arguments += (ConvertTo-ShellQualityRelativePath -RepositoryRoot $RepositoryRoot -Path $file)
    }

    $exitCode = Invoke-QualityToolingProcess -Context $script:ShellQualityContext -FilePath $ExecutablePath -ArgumentList $arguments -WorkingDirectory $RepositoryRoot
    if ($exitCode -ne 0) {
        throw "E_SHELLCHECK_FAILED: shellcheck failed for selected shell target(s) (exitCode=$exitCode)."
    }
}

function Invoke-ShellQualityChecksMain {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("All", "shfmt", "shellcheck")]
        [string]$SelectedTool,

        [Parameter(Mandatory = $true)]
        [bool]$ApplyFix,

        [Parameter(Mandatory = $true)]
        [bool]$OnlyEnsureTools,

        [Parameter(Mandatory = $false)]
        [string[]]$InputFiles = @()
    )

    $repositoryRoot = Get-ShellQualityRepositoryRoot
    $manifest = Read-ShellQualityToolManifest
    $toolNames = if ($SelectedTool -eq "All") { @("shfmt", "shellcheck") } else { @($SelectedTool) }
    $toolExecutables = @{}

    foreach ($toolName in $toolNames) {
        $toolExecutables[$toolName] = Resolve-ShellQualityToolExecutable -Manifest $manifest -ToolName $toolName -RepositoryRoot $repositoryRoot
    }

    if ($OnlyEnsureTools) {
        Write-Host "[shell-quality] Shell quality tools are ready."
        return
    }

    $targetPaths = @(Resolve-ShellQualityTargetFiles -RepositoryRoot $repositoryRoot -InputFiles $InputFiles)
    if ($targetPaths.Count -eq 0) {
        Write-Host "[shell-quality] No existing shell targets selected; skipping."
        return
    }

    if ($toolExecutables.ContainsKey("shfmt")) {
        Invoke-ShfmtQualityCheck -ExecutablePath $toolExecutables["shfmt"] -RepositoryRoot $repositoryRoot -Files $targetPaths -ApplyFix $ApplyFix
    }

    if ($toolExecutables.ContainsKey("shellcheck")) {
        Invoke-ShellCheckQualityCheck -ExecutablePath $toolExecutables["shellcheck"] -RepositoryRoot $repositoryRoot -Files $targetPaths
    }
}

if (-not $NoInvokeMain) {
    Invoke-ShellQualityChecksMain -SelectedTool $Tool -ApplyFix:$Fix.IsPresent -OnlyEnsureTools:$EnsureOnly.IsPresent -InputFiles $TargetFiles
}
