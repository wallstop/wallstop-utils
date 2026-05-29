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

$qualityToolingHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/QualityToolingHelpers.ps1"
if (-not (Test-Path -LiteralPath $qualityToolingHelpersPath -PathType Leaf)) {
    throw "E_NATIVE_TOOL_QUALITY_HELPER_MISSING: quality tooling helper file not found at '$qualityToolingHelpersPath'."
}

. $qualityToolingHelpersPath

$script:NativeQualityContext = New-QualityToolingContext `
    -DiagnosticPrefix "NATIVE_TOOL" `
    -TargetDiagnosticPrefix "NATIVE_QUALITY" `
    -LogPrefix "[native-quality]" `
    -ManifestPath $script:NativeQualityManifestPath `
    -ToolRootName $script:NativeQualityToolRootName `
    -DownloadTimeoutSeconds $script:NativeQualityDownloadTimeoutSeconds `
    -ToolSuiteLabel "native" `
    -ManifestContextLabel "native quality tool manifest" `
    -MarkerContextLabel "native quality asset marker"

function Get-NativeQualityRepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../../..") -ErrorAction Stop).Path
}

function Read-NativeQualityToolManifest {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ManifestPath = $script:NativeQualityManifestPath
    )

    return Read-QualityToolingManifest -Context $script:NativeQualityContext -ManifestPath $ManifestPath
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

    return Resolve-QualityToolingAssetSpec -Context $script:NativeQualityContext -Manifest $Manifest -ToolName $ToolName -OperatingSystem $OperatingSystem -Architecture $Architecture
}

function Invoke-NativeQualityDownload {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$DownloadPath
    )

    Invoke-QualityToolingDownload -Context $script:NativeQualityContext -AssetSpec $AssetSpec -DownloadPath $DownloadPath
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

    Install-QualityToolingToolAsset -Context $script:NativeQualityContext -InstallRoot $InstallRoot -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot -DownloadCommand { param($AssetSpec, $DownloadPath) Invoke-NativeQualityDownload -AssetSpec $AssetSpec -DownloadPath $DownloadPath }
}

function Invoke-NativeQualityInstallLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    Invoke-QualityToolingInstallLock -Context $script:NativeQualityContext -LockPath $LockPath -ScriptBlock $ScriptBlock -LockTimeoutSeconds $script:NativeQualityLockTimeoutSeconds -LockRetryMilliseconds $script:NativeQualityLockRetryMilliseconds
}

function Test-NativeQualityArchiveEntryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryPath
    )

    return Test-QualityToolingArchiveEntryPath -EntryPath $EntryPath
}

function Test-NativeQualityTarMetadataLineSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetadataLine
    )

    return Test-QualityToolingTarMetadataLineSafe -MetadataLine $MetadataLine
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

    return Resolve-QualityToolingToolExecutable -Context $script:NativeQualityContext -Manifest $Manifest -ToolName $ToolName -RepositoryRoot $RepositoryRoot -LockTimeoutSeconds $script:NativeQualityLockTimeoutSeconds -LockRetryMilliseconds $script:NativeQualityLockRetryMilliseconds -InstallCommand { param($InstallRoot, $AssetSpec, $RepositoryRoot) Install-NativeQualityToolAsset -InstallRoot $InstallRoot -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot }
}

function Resolve-NativeQualityTargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$InputFiles = @()
    )

    return Resolve-QualityToolingTargetFiles -Context $script:NativeQualityContext -RepositoryRoot $RepositoryRoot -InputFiles $InputFiles
}

function ConvertTo-NativeQualityRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ConvertTo-QualityToolingRelativePath -RepositoryRoot $RepositoryRoot -Path $Path
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

    $exitCode = Invoke-QualityToolingProcess -Context $script:NativeQualityContext -FilePath $ExecutablePath -ArgumentList $arguments -WorkingDirectory $RepositoryRoot
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

    $exitCode = Invoke-QualityToolingProcess -Context $script:NativeQualityContext -FilePath $ExecutablePath -ArgumentList $arguments -WorkingDirectory $RepositoryRoot
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
