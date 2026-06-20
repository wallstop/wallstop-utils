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
$script:NativeEmbeddedShellQualityManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "shell-quality-tools.json"
$script:NativeQualityToolRootName = ".tools/native-quality"
$script:NativeEmbeddedShellQualityToolRootName = ".tools/shell-quality"
$script:NativeQualityDownloadTimeoutSeconds = 300
$script:NativeEmbeddedShellQualityDownloadTimeoutSeconds = 180
$script:NativeQualityLockTimeoutSeconds = 60
$script:NativeQualityLockRetryMilliseconds = 200

if (-not [string]::IsNullOrWhiteSpace($env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS)) {
    if ($env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS -notmatch '^[0-9]+$' -or [int]$env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS -lt 30) {
        throw "E_NATIVE_TOOL_TIMEOUT_CONFIG: WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS must be an integer >= 30 seconds (received '$env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS')."
    }

    $script:NativeQualityDownloadTimeoutSeconds = [int]$env:WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS
}

if (-not [string]::IsNullOrWhiteSpace($env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS)) {
    if ($env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS -notmatch '^[0-9]+$' -or [int]$env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS -lt 30) {
        throw "E_SHELL_TOOL_TIMEOUT_CONFIG: WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS must be an integer >= 30 seconds (received '$env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS')."
    }

    $script:NativeEmbeddedShellQualityDownloadTimeoutSeconds = [int]$env:WALLSTOP_SHELL_TOOL_DOWNLOAD_TIMEOUT_SECONDS
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

$script:NativeEmbeddedShellQualityContext = New-QualityToolingContext `
    -DiagnosticPrefix "SHELL_TOOL" `
    -TargetDiagnosticPrefix "SHELL_QUALITY" `
    -LogPrefix "[shell-quality]" `
    -ManifestPath $script:NativeEmbeddedShellQualityManifestPath `
    -ToolRootName $script:NativeEmbeddedShellQualityToolRootName `
    -DownloadTimeoutSeconds $script:NativeEmbeddedShellQualityDownloadTimeoutSeconds `
    -ToolSuiteLabel "shell" `
    -ManifestContextLabel "shell quality tool manifest" `
    -MarkerContextLabel "shell quality asset marker"

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
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [object[]]$ArgumentList = @()
    )

    Invoke-QualityToolingInstallLock -Context $script:NativeQualityContext -LockPath $LockPath -ScriptBlock $ScriptBlock -LockTimeoutSeconds $script:NativeQualityLockTimeoutSeconds -LockRetryMilliseconds $script:NativeQualityLockRetryMilliseconds -ArgumentList $ArgumentList
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

function Read-NativeEmbeddedShellQualityToolManifest {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ManifestPath = $script:NativeEmbeddedShellQualityManifestPath
    )

    return Read-QualityToolingManifest -Context $script:NativeEmbeddedShellQualityContext -ManifestPath $ManifestPath
}

function Install-NativeEmbeddedShellQualityToolAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    Install-QualityToolingToolAsset -Context $script:NativeEmbeddedShellQualityContext -InstallRoot $InstallRoot -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot -DownloadCommand { param($AssetSpec, $DownloadPath) Invoke-QualityToolingDownload -Context $script:NativeEmbeddedShellQualityContext -AssetSpec $AssetSpec -DownloadPath $DownloadPath }
}

function Resolve-NativeEmbeddedShellCheckExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $manifest = Read-NativeEmbeddedShellQualityToolManifest
    return Resolve-QualityToolingToolExecutable -Context $script:NativeEmbeddedShellQualityContext -Manifest $manifest -ToolName "shellcheck" -RepositoryRoot $RepositoryRoot -LockTimeoutSeconds $script:NativeQualityLockTimeoutSeconds -LockRetryMilliseconds $script:NativeQualityLockRetryMilliseconds -InstallCommand { param($InstallRoot, $AssetSpec, $RepositoryRoot) Install-NativeEmbeddedShellQualityToolAsset -InstallRoot $InstallRoot -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot }
}

function Test-UseActionlintEmbeddedAnalyzers {
    return (-not (Test-IsWindowsPlatform))
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
        [string[]]$Files = @()
    )

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

        [Parameter(Mandatory = $false)]
        [string]$ShellCheckExecutablePath = "",

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Files
    )

    $arguments = if ([string]::IsNullOrEmpty($ShellCheckExecutablePath)) {
        @("-shellcheck", "", "-pyflakes", "")
    }
    else {
        @("-shellcheck", $ShellCheckExecutablePath)
    }

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
    $toolNames = if ($SelectedTool -eq "All") { @("stylua", "actionlint") } else { @($SelectedTool) }

    if (-not $OnlyEnsureTools) {
        $targetPaths = @(Resolve-NativeQualityTargetFiles -RepositoryRoot $repositoryRoot -InputFiles $InputFiles)
        if ($targetPaths.Count -eq 0) {
            Write-Host "[native-quality] No existing native quality targets selected; skipping."
            return
        }

        $toolTargetMap = @{}
        foreach ($toolName in $toolNames) {
            $matchingTargets = @(Select-NativeQualityToolTargetFiles -ToolName $toolName -RepositoryRoot $repositoryRoot -Files $targetPaths)
            if ($matchingTargets.Count -gt 0) {
                $toolTargetMap[$toolName] = $matchingTargets
            }
        }

        if ($toolTargetMap.Count -eq 0) {
            Write-Host "[native-quality] No native quality targets matched requested tool selection; skipping."
            return
        }

        $toolNames = @($toolNames | Where-Object { $toolTargetMap.ContainsKey($_) })
    }

    $manifest = Read-NativeQualityToolManifest
    $toolExecutables = @{}

    foreach ($toolName in $toolNames) {
        $toolExecutables[$toolName] = Resolve-NativeQualityToolExecutable -Manifest $manifest -ToolName $toolName -RepositoryRoot $repositoryRoot
    }

    $embeddedShellCheckExecutable = ""
    if ($toolNames -contains "actionlint") {
        if (Test-UseActionlintEmbeddedAnalyzers) {
            $embeddedShellCheckExecutable = Resolve-NativeEmbeddedShellCheckExecutable -RepositoryRoot $repositoryRoot
        }
        else {
            Write-Warning "W_NATIVE_QUALITY_ACTIONLINT_EMBEDDED_ANALYZERS_DISABLED_WINDOWS: actionlint shellcheck/pyflakes subprocess integration is disabled on Windows to avoid native subprocess hangs; Linux CI keeps blocking workflow embedded analyzer coverage."
        }
    }

    if ($OnlyEnsureTools) {
        Write-Host "[native-quality] Native quality tools are ready."
        return
    }

    if ($toolExecutables.ContainsKey("stylua")) {
        $styluaTargets = @($toolTargetMap["stylua"])
        if ($styluaTargets.Count -gt 0) {
            Invoke-StyluaQualityCheck -ExecutablePath $toolExecutables["stylua"] -RepositoryRoot $repositoryRoot -Files $styluaTargets -ApplyFix $ApplyFix
        }
    }

    if ($toolExecutables.ContainsKey("actionlint")) {
        $actionlintTargets = @($toolTargetMap["actionlint"])
        if ($actionlintTargets.Count -gt 0) {
            Invoke-ActionlintQualityCheck -ExecutablePath $toolExecutables["actionlint"] -ShellCheckExecutablePath $embeddedShellCheckExecutable -RepositoryRoot $repositoryRoot -Files $actionlintTargets
        }
    }
}

if (-not $NoInvokeMain) {
    Invoke-NativeQualityChecksMain -SelectedTool $Tool -ApplyFix:$Fix.IsPresent -OnlyEnsureTools:$EnsureOnly.IsPresent -InputFiles $TargetFiles
}
