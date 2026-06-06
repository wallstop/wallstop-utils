[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAnalyzer,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 7200)]
    [int]$PesterTimeoutSeconds = 900,

    [Parameter(Mandatory = $false)]
    [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
    [string]$PesterOutputVerbosity = "None",

    [Parameter(Mandatory = $false)]
    [switch]$IncludePreCommitOwnedChecks,

    [Parameter(Mandatory = $false)]
    [switch]$AllowPreCommitOwnedFixes,

    [Parameter(Mandatory = $false)]
    [string]$TargetFileListPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$NoInvokeMain,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetFiles = @(),

    [Parameter(Mandatory = $false, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingTargetFiles = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$moduleHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/ModuleHelpers.ps1"
if (-not (Test-Path -Path $moduleHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Module helper file not found at '$moduleHelpersPath'."
}

.$moduleHelpersPath

$formatSafetyHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/FormatOperatorSafetyHelpers.ps1"
if (-not (Test-Path -Path $formatSafetyHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Format-operator safety helper file not found at '$formatSafetyHelpersPath'."
}

.$formatSafetyHelpersPath

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -Path $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Diagnostics helper file not found at '$diagnosticsHelpersPath'."
}

.$diagnosticsHelpersPath

$llmWrapperHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/LlmWrapperContractHelpers.ps1"
if (-not (Test-Path -Path $llmWrapperHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: LLM wrapper helper file not found at '$llmWrapperHelpersPath'."
}

.$llmWrapperHelpersPath

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -Path $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath'."
}

.$compatibilityHelpersPath

$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/StrictModeHelpers.ps1"
if (-not (Test-Path -Path $strictModeHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Strict mode helper file not found at '$strictModeHelpersPath'."
}

.$strictModeHelpersPath

function New-LlmHarnessPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$WrapperFiles
    )

    $patternSegments = New-Object 'System.Collections.Generic.List[string]'
    [void]$patternSegments.Add('\.llm/.+\.md')

    $normalizedWrappers = @(
        $WrapperFiles |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ -replace '[\\/]+', '/' } |
            Sort-Object -Unique
    )

    foreach ($wrapperFile in $normalizedWrappers) {
        [void]$patternSegments.Add([regex]::Escape($wrapperFile))
    }

    [void]$patternSegments.Add('\.github/dependabot\.yml')
    [void]$patternSegments.Add('Scripts/Utils/Quality/(Update-LlmSkillsIndex|Test-LlmHarness)\.ps1')
    [void]$patternSegments.Add('Tests/Utils/LlmHarness\.Tests\.ps1')

    return ('^({0})$' -f ($patternSegments -join '|'))
}

function Get-GitExecutableOrThrow {
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_PRECOMMIT_VALIDATION_GIT_NOT_AVAILABLE: git is required to read staged files but was not found on PATH."
    }

    Write-Verbose ("Pre-commit validation git diagnostics: gitPath='{0}'" -f $gitCommand.Source)
    return $gitCommand.Source
}

function Get-PwshExecutableOrThrow {
    $pwshCommand = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $pwshCommand) {
        throw "E_CONFIG_ERROR: pwsh is required for isolated Pester execution but was not found on PATH."
    }

    Write-Verbose ("Pre-commit validation pwsh diagnostics: pwshPath='{0}'" -f $pwshCommand.Source)
    return $pwshCommand.Source
}

function Get-LastNativeExitCodeOrDefault {
    $lastExitCode = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $lastExitCode) {
        return 0
    }

    return [int]$lastExitCode
}

function Invoke-GitCommandWithSplitOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $gitStderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = @(& $GitExecutable @Arguments 2> $gitStderrPath)
        $exitCode = Get-LastNativeExitCodeOrDefault
        $stderr = Read-RedirectedProcessText -Path $gitStderrPath
    }
    finally {
        Remove-Item -LiteralPath $gitStderrPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout   = @($stdout)
        Stderr   = $stderr
    }
}

function Join-GitCommandDiagnosticOutput {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Stdout,

        [Parameter(Mandatory = $false)]
        [string]$Stderr = ""
    )

    $outputLines = @($Stdout)
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
        $outputLines += @($Stderr -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($outputLines)
}

function Invoke-GitStdoutOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $gitResult = Invoke-GitCommandWithSplitOutput -GitExecutable $GitExecutable -Arguments $Arguments
    if ([int]$gitResult.ExitCode -eq 0) {
        return @($gitResult.Stdout)
    }

    $diagnosticOutput = @(Join-GitCommandDiagnosticOutput -Stdout @($gitResult.Stdout) -Stderr $gitResult.Stderr)
    $gitOutputPreview = Get-OutputPreview -OutputLines $diagnosticOutput -CollapseWhitespace
    throw ("{0} (exitCode={1}). Git output: {2}" -f $FailureMessage, [int]$gitResult.ExitCode, $gitOutputPreview)
}

function Get-StagedFilesWithIndexLockRecoveryOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $stagedFileQuery = 'git -C <repositoryRoot> diff --cached --name-only --diff-filter=ACMRD'
    $stagedFileArgs = @("-C", $RepositoryRoot, "diff", "--cached", "--name-only", "--diff-filter=ACMRD")
    $stagedFileResult = Invoke-GitCommandWithSplitOutput -GitExecutable $GitExecutable -Arguments $stagedFileArgs
    $stagedFileOutput = @($stagedFileResult.Stdout)
    $stagedFileDiagnosticOutput = @(Join-GitCommandDiagnosticOutput -Stdout $stagedFileOutput -Stderr $stagedFileResult.Stderr)
    $stagedFileExitCode = [int]$stagedFileResult.ExitCode
    if ($stagedFileExitCode -eq 0) {
        return @($stagedFileOutput)
    }

    if (Test-IsGitIndexLockFailure -OutputLines $stagedFileDiagnosticOutput) {
        Write-Warning (
            "W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED: context='staged-file-discovery'; repositoryRoot='{0}'." -f
            $RepositoryRoot
        )

        $lockRecovery = Invoke-SafeGitIndexLockRecovery -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -OutputLines $stagedFileDiagnosticOutput -Context 'staged-file-discovery'
        if ($lockRecovery.ElapsedMilliseconds -gt $lockRecovery.SlowPathThresholdMs) {
            Write-Warning (
                "W_PRECOMMIT_GIT_INDEX_LOCK_SLOW_PATH: context='staged-file-discovery'; elapsedMs={0}; thresholdMs={1}." -f
                [int]$lockRecovery.ElapsedMilliseconds,
                [int]$lockRecovery.SlowPathThresholdMs
            )
        }

        if (-not $lockRecovery.Recovered) {
            $skipReason = if ([string]::IsNullOrWhiteSpace([string]$lockRecovery.SkippedReason)) {
                'unknown'
            }
            else {
                [string]$lockRecovery.SkippedReason
            }

            $ambiguousGitProcessCount = if ($null -ne $lockRecovery.PSObject.Properties["AmbiguousGitProcessCount"]) {
                [int]$lockRecovery.AmbiguousGitProcessCount
            }
            else {
                0
            }

            Write-Warning (
                "W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_SKIPPED: context='staged-file-discovery'; reason={0}; lockPath='{1}'; lockAgeSeconds={2}; activeGitProcessCount={3}; ambiguousGitProcessCount={4}; processScanDegraded={5}." -f
                $skipReason,
                [string]$lockRecovery.LockPath,
                [int]$lockRecovery.LockAgeSeconds,
                [int]$lockRecovery.ActiveGitProcessCount,
                $ambiguousGitProcessCount,
                [bool]$lockRecovery.ProcessScanDegraded
            )

            if ($skipReason -eq 'recovery_failed') {
                throw (
                    "E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED: staged-file discovery failed to recover index lock (repositoryRoot='{0}'; lockPath='{1}'; error={2})." -f
                    $RepositoryRoot,
                    [string]$lockRecovery.LockPath,
                    [string]$lockRecovery.ErrorMessage
                )
            }

            $failurePreview = Get-OutputPreview -OutputLines $stagedFileDiagnosticOutput
            throw (
                "E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED: staged-file discovery blocked by index lock (repositoryRoot='{0}'; lockPath='{1}'; reason={2}; outputPreview={3})." -f
                $RepositoryRoot,
                [string]$lockRecovery.LockPath,
                $skipReason,
                $failurePreview
            )
        }

        Write-Warning (
            "W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_RETRYING: context='staged-file-discovery'; lockPath='{0}'; lockAgeSeconds={1}." -f
            [string]$lockRecovery.LockPath,
            [int]$lockRecovery.LockAgeSeconds
        )

        $stagedFileResult = Invoke-GitCommandWithSplitOutput -GitExecutable $GitExecutable -Arguments $stagedFileArgs
        $stagedFileOutput = @($stagedFileResult.Stdout)
        $stagedFileDiagnosticOutput = @(Join-GitCommandDiagnosticOutput -Stdout $stagedFileOutput -Stderr $stagedFileResult.Stderr)
        $stagedFileExitCode = [int]$stagedFileResult.ExitCode
        if ($stagedFileExitCode -eq 0) {
            return @($stagedFileOutput)
        }

        if (Test-IsGitIndexLockFailure -OutputLines $stagedFileDiagnosticOutput) {
            $failurePreview = Get-OutputPreview -OutputLines $stagedFileDiagnosticOutput
            throw (
                "E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED: staged-file discovery still blocked after recovery retry (repositoryRoot='{0}'; lockPath='{1}'; outputPreview={2})." -f
                $RepositoryRoot,
                [string]$lockRecovery.LockPath,
                $failurePreview
            )
        }
    }

    $gitErrorText = Get-OutputPreview -OutputLines $stagedFileDiagnosticOutput -CollapseWhitespace
    throw "E_CONFIG_ERROR: Failed to read staged files using '$stagedFileQuery' (exitCode=$stagedFileExitCode). Git output: $gitErrorText"
}

function ConvertTo-NormalizedRelativeTargetPath {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return (([string]$Path).Trim() -replace '[\\/]+', '/') -replace '^\./+', ''
}

function Get-PreCommitValidationTargetFiles {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$ExplicitFiles = @(),

        [Parameter(Mandatory = $false)]
        [string]$ListPath = ""
    )

    $targetFiles = New-Object System.Collections.Generic.List[string]

    foreach ($explicitFile in @($ExplicitFiles)) {
        if (-not [string]::IsNullOrWhiteSpace($explicitFile)) {
            $targetFiles.Add([string]$explicitFile) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ListPath)) {
        if (-not (Test-Path -LiteralPath $ListPath -PathType Leaf)) {
            throw "E_PRECOMMIT_VALIDATION_TARGET_LIST_MISSING: target file list not found at '$ListPath'."
        }

        foreach ($listedFile in @([System.IO.File]::ReadAllLines($ListPath, [System.Text.Encoding]::UTF8))) {
            if (-not [string]::IsNullOrWhiteSpace($listedFile)) {
                $targetFiles.Add([string]$listedFile) | Out-Null
            }
        }
    }

    return @($targetFiles.ToArray())
}

function Get-FileContentHashOrMissing {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return '(missing)'
    }

    try {
        return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        throw "E_CONFIG_ERROR: Failed to hash file '$Path'. $($_.Exception.Message)"
    }
}

function Get-RelativeFileHashSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativePaths = @()
    )

    $snapshot = @{}
    $normalizedRelativePaths = @(
        $RelativePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    foreach ($relativePath in $normalizedRelativePaths) {
        $targetPath = Join-Path -Path $RepoRoot -ChildPath $relativePath
        $snapshot[$relativePath] = Get-FileContentHashOrMissing -Path $targetPath
    }

    return $snapshot
}

function Assert-GovernanceFileHasTrailingLf {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GovernanceRelativePath
    )

    $fullPath = Join-Path -Path $RepoRoot -ChildPath $GovernanceRelativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -eq 0) {
        throw "E_PRECOMMIT_GOVERNANCE_EMPTY_FILE: Governance file '$GovernanceRelativePath' must not be empty."
    }

    if ($bytes[$bytes.Length - 1] -ne 10) {
        throw "E_PRECOMMIT_GOVERNANCE_TRAILING_NEWLINE: Governance file '$GovernanceRelativePath' must end with LF."
    }
}

function Get-RequiredGovernanceObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$GovernanceObject,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GovernancePropertyName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GovernanceContextLabel
    )

    $property = $GovernanceObject.PSObject.Properties[$GovernancePropertyName]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "E_PRECOMMIT_GOVERNANCE_PROPERTY_MISSING: $GovernanceContextLabel must define '$GovernancePropertyName'."
    }

    return $property.Value
}

function Assert-GovernanceQualityManifest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$GovernanceManifest,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GovernanceManifestPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$GovernanceExpectedToolAssets
    )

    $toolsObject = Get-RequiredGovernanceObjectProperty -GovernanceObject $GovernanceManifest -GovernancePropertyName "tools" -GovernanceContextLabel $GovernanceManifestPath
    foreach ($governanceToolName in @($GovernanceExpectedToolAssets.Keys | Sort-Object)) {
        $toolDefinition = Get-RequiredGovernanceObjectProperty -GovernanceObject $toolsObject -GovernancePropertyName $governanceToolName -GovernanceContextLabel "$GovernanceManifestPath tools"

        foreach ($requiredToolProperty in @("version", "releaseTag", "repository", "versionPattern", "executableBaseName", "assets")) {
            $requiredToolPropertyValue = Get-RequiredGovernanceObjectProperty -GovernanceObject $toolDefinition -GovernancePropertyName $requiredToolProperty -GovernanceContextLabel "$GovernanceManifestPath tool '$governanceToolName'"
            if ($requiredToolProperty -ne "assets" -and [string]::IsNullOrWhiteSpace([string]$requiredToolPropertyValue)) {
                throw "E_PRECOMMIT_GOVERNANCE_QUALITY_MANIFEST_TOOL_INVALID: '$GovernanceManifestPath' tool '$governanceToolName' must define non-empty '$requiredToolProperty'."
            }
        }

        $assetsObject = Get-RequiredGovernanceObjectProperty -GovernanceObject $toolDefinition -GovernancePropertyName "assets" -GovernanceContextLabel "$GovernanceManifestPath tool '$governanceToolName'"
        foreach ($requiredAssetKey in @($GovernanceExpectedToolAssets[$governanceToolName])) {
            $assetDefinition = Get-RequiredGovernanceObjectProperty -GovernanceObject $assetsObject -GovernancePropertyName $requiredAssetKey -GovernanceContextLabel "$GovernanceManifestPath tool '$governanceToolName' assets"
            $assetName = [string](Get-RequiredGovernanceObjectProperty -GovernanceObject $assetDefinition -GovernancePropertyName "assetName" -GovernanceContextLabel "$GovernanceManifestPath tool '$governanceToolName' asset '$requiredAssetKey'")
            $assetKind = [string](Get-RequiredGovernanceObjectProperty -GovernanceObject $assetDefinition -GovernancePropertyName "kind" -GovernanceContextLabel "$GovernanceManifestPath tool '$governanceToolName' asset '$requiredAssetKey'")
            $assetSha256 = [string](Get-RequiredGovernanceObjectProperty -GovernanceObject $assetDefinition -GovernancePropertyName "sha256" -GovernanceContextLabel "$GovernanceManifestPath tool '$governanceToolName' asset '$requiredAssetKey'")

            if ([string]::IsNullOrWhiteSpace($assetName)) {
                throw "E_PRECOMMIT_GOVERNANCE_QUALITY_MANIFEST_ASSET_INVALID: '$GovernanceManifestPath' tool '$governanceToolName' asset '$requiredAssetKey' must define assetName."
            }
            if ($assetKind -notin @("executable", "zip", "tar.gz")) {
                throw "E_PRECOMMIT_GOVERNANCE_QUALITY_MANIFEST_ASSET_INVALID: '$GovernanceManifestPath' tool '$governanceToolName' asset '$requiredAssetKey' has unsupported kind '$assetKind'."
            }
            if ($assetSha256 -notmatch '^[0-9a-f]{64}$') {
                throw "E_PRECOMMIT_GOVERNANCE_QUALITY_MANIFEST_ASSET_INVALID: '$GovernanceManifestPath' tool '$governanceToolName' asset '$requiredAssetKey' must define a lowercase 64-character SHA256."
            }
        }
    }
}

function Assert-ShellCheckGovernanceConfig {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string]$ShellCheckConfigContent
    )

    $normalizedShellCheckConfig = $ShellCheckConfigContent -replace "`r", ''
    foreach ($requiredShellCheckPattern in @(
            '(?m)^external-sources=true$',
            '(?m)^source-path=SCRIPTDIR$',
            '(?m)^severity=style$'
        )) {
        if ($normalizedShellCheckConfig -notmatch $requiredShellCheckPattern) {
            throw "E_PRECOMMIT_GOVERNANCE_SHELLCHECKRC_INVALID: .shellcheckrc must keep required setting pattern '$requiredShellCheckPattern'."
        }
    }

    if ($normalizedShellCheckConfig -match '(?m)^\s*disable\s*=\s*all\s*$') {
        throw "E_PRECOMMIT_GOVERNANCE_SHELLCHECKRC_DISABLE_ALL: .shellcheckrc must not disable all ShellCheck diagnostics."
    }
}

function Assert-StyLuaGovernanceConfig {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string]$StyLuaConfigContent
    )

    $normalizedStyLuaConfig = $StyLuaConfigContent -replace "`r", ''
    $requiredStyLuaSettings = @{
        "call_parentheses" = '"Always"'
        "column_width"     = "100"
        "indent_type"      = '"Spaces"'
        "indent_width"     = "2"
        "line_endings"     = '"Unix"'
        "quote_style"      = '"AutoPreferDouble"'
    }

    foreach ($styLuaSettingName in @($requiredStyLuaSettings.Keys | Sort-Object)) {
        $styLuaSettingValuePattern = [regex]::Escape([string]$requiredStyLuaSettings[$styLuaSettingName])
        if ($normalizedStyLuaConfig -notmatch "(?m)^$([regex]::Escape($styLuaSettingName))\s*=\s*$styLuaSettingValuePattern\s*$") {
            throw "E_PRECOMMIT_GOVERNANCE_STYLUA_INVALID: .stylua.toml must keep '$styLuaSettingName = $($requiredStyLuaSettings[$styLuaSettingName])'."
        }
    }
}

function Invoke-PreCommitGovernanceValidation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$TargetFiles = @()
    )

    $governanceTargets = @(
        $TargetFiles |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    foreach ($relativePath in $governanceTargets) {
        Assert-GovernanceFileHasTrailingLf -RepoRoot $RepoRoot -GovernanceRelativePath $relativePath
    }

    if ($governanceTargets -contains ".pre-commit-config.yaml") {
        $preCommitCommand = Get-Command -Name "pre-commit" -ErrorAction SilentlyContinue
        if ($null -eq $preCommitCommand) {
            throw "E_PRECOMMIT_GOVERNANCE_PRECOMMIT_NOT_AVAILABLE: pre-commit is required to validate .pre-commit-config.yaml but was not found on PATH."
        }

        $preCommitConfigOutput = @(& $preCommitCommand.Source validate-config 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $preCommitConfigPreview = Get-OutputPreview -OutputLines $preCommitConfigOutput -CollapseWhitespace
            throw "E_PRECOMMIT_GOVERNANCE_PRECOMMIT_CONFIG_INVALID: pre-commit validate-config failed. Output: $preCommitConfigPreview"
        }
    }

    if ($governanceTargets -contains "requirements.txt") {
        $requirementsPath = Join-Path -Path $RepoRoot -ChildPath "requirements.txt"
        $requirements = (Get-Content -LiteralPath $requirementsPath -Raw) -replace "`r", ''
        if ($requirements -notmatch '(?m)^pre-commit==\d+(?:\.\d+){1,3}$') {
            throw "E_PRECOMMIT_GOVERNANCE_REQUIREMENTS_PIN: requirements.txt must pin pre-commit with an exact 'pre-commit==x.y.z' requirement."
        }
    }

    foreach ($psDataFile in @(".psscriptanalyzer.psd1", ".psscriptanalyzer.format.psd1")) {
        if ($governanceTargets -contains $psDataFile) {
            $psDataPath = Join-Path -Path $RepoRoot -ChildPath $psDataFile
            try {
                [void](Import-PowerShellDataFile -LiteralPath $psDataPath -ErrorAction Stop)
            }
            catch {
                throw "E_PRECOMMIT_GOVERNANCE_PSD1_INVALID: '$psDataFile' must parse as a PowerShell data file. $($_.Exception.Message)"
            }
        }
    }

    foreach ($jsonConfigFile in @("Scripts/Utils/Quality/native-quality-tools.json", "Scripts/Utils/Quality/shell-quality-tools.json")) {
        if ($governanceTargets -contains $jsonConfigFile) {
            $jsonConfigPath = Join-Path -Path $RepoRoot -ChildPath $jsonConfigFile
            try {
                $jsonConfigManifest = ConvertFrom-JsonSingleObject -Json (Get-Content -LiteralPath $jsonConfigPath -Raw) -Context $jsonConfigFile
                if ($jsonConfigFile -eq "Scripts/Utils/Quality/native-quality-tools.json") {
                    Assert-GovernanceQualityManifest -GovernanceManifest $jsonConfigManifest -GovernanceManifestPath $jsonConfigFile -GovernanceExpectedToolAssets @{
                        "actionlint" = @("darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-arm64", "windows-x64")
                        "stylua"     = @("darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-x64")
                    }
                }
                else {
                    Assert-GovernanceQualityManifest -GovernanceManifest $jsonConfigManifest -GovernanceManifestPath $jsonConfigFile -GovernanceExpectedToolAssets @{
                        "shellcheck" = @("darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-x64")
                        "shfmt"      = @("darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-x64")
                    }
                }
            }
            catch {
                throw "E_PRECOMMIT_GOVERNANCE_JSON_INVALID: '$jsonConfigFile' must be a valid quality-tool manifest. $($_.Exception.Message)"
            }
        }
    }

    if ($governanceTargets -contains ".shellcheckrc") {
        Assert-ShellCheckGovernanceConfig -ShellCheckConfigContent (Get-Content -LiteralPath (Join-Path -Path $RepoRoot -ChildPath ".shellcheckrc") -Raw)
    }

    if ($governanceTargets -contains ".stylua.toml") {
        Assert-StyLuaGovernanceConfig -StyLuaConfigContent (Get-Content -LiteralPath (Join-Path -Path $RepoRoot -ChildPath ".stylua.toml") -Raw)
    }

    if ($governanceTargets -contains ".gitattributes") {
        $gitattributes = (Get-Content -LiteralPath (Join-Path -Path $RepoRoot -ChildPath ".gitattributes") -Raw) -replace "`r", ''
        if ($gitattributes -notmatch '(?m)^\*\s+text=auto\s+eol=lf\s*$') {
            throw "E_PRECOMMIT_GOVERNANCE_GITATTRIBUTES_LF: .gitattributes must default text files to LF."
        }
        if ($gitattributes -notmatch '(?m)^\*\.bat\s+text\s+eol=crlf\s*$' -or $gitattributes -notmatch '(?m)^\*\.cmd\s+text\s+eol=crlf\s*$') {
            throw "E_PRECOMMIT_GOVERNANCE_GITATTRIBUTES_CMD_CRLF: .gitattributes must keep .bat and .cmd files as CRLF."
        }
    }

    if ($governanceTargets -contains ".editorconfig") {
        $editorconfig = (Get-Content -LiteralPath (Join-Path -Path $RepoRoot -ChildPath ".editorconfig") -Raw) -replace "`r", ''
        if ($editorconfig -notmatch '(?m)^\[\*\.\{bat,cmd\}\]\s*$' -or $editorconfig -notmatch '(?ms)\[\*\.\{bat,cmd\}\]\s*\n\s*end_of_line\s*=\s*crlf') {
            throw "E_PRECOMMIT_GOVERNANCE_EDITORCONFIG_CMD_CRLF: .editorconfig must keep .bat and .cmd files as CRLF."
        }
    }

    if ($governanceTargets -contains ".gitignore") {
        $gitignore = (Get-Content -LiteralPath (Join-Path -Path $RepoRoot -ChildPath ".gitignore") -Raw) -replace "`r", ''
        if ($gitignore -notmatch '(?m)^\.tools/$') {
            throw "E_PRECOMMIT_GOVERNANCE_GITIGNORE_TOOLS_CACHE: .gitignore must ignore the .tools/ cache."
        }
    }
}

function Get-FirstRootErrorCode {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$OutputLines = @()
    )

    foreach ($line in @($OutputLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $match = [regex]::Match($line, '\b(E_[A-Z0-9_]+)\b')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return "unknown"
}

function Get-RedactedFailureLine {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Line
    )

    if ($null -eq $Line) {
        return ""
    }

    $redacted = $Line
    $redacted = [regex]::Replace($redacted, '(?i)(authorization\s*[:=]\s*).+$', '$1[REDACTED]')
    $redacted = [regex]::Replace($redacted, '(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b', '[REDACTED_TOKEN]')
    $redacted = [regex]::Replace($redacted, '(?i)(\b(?:token|password|secret|api[_-]?key|client[_-]?secret|github[_-]?token|access[_-]?token|refresh[_-]?token)\b\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s;]+)', '$1[REDACTED]')

    return $redacted
}

function Test-IsLinkOrReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.IO.FileSystemInfo]$Item
    )

    $linkTypeProperty = $Item.PSObject.Properties['LinkType']
    $hasLinkType = ($null -ne $linkTypeProperty -and -not [string]::IsNullOrWhiteSpace([string]$Item.LinkType))
    $hasReparsePointAttribute = (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    return ($hasReparsePointAttribute -or $hasLinkType)
}

function Resolve-CanonicalPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($rootPath)) {
        throw "E_CONFIG_ERROR: unable to resolve canonical path root for '$Path'."
    }

    $relativePath = $fullPath.Substring($rootPath.Length)
    $pathSeparators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $segments = @($relativePath.Split($pathSeparators, [System.StringSplitOptions]::RemoveEmptyEntries))

    $currentPath = $rootPath
    foreach ($segment in $segments) {
        $candidatePath = Join-Path -Path $currentPath -ChildPath $segment
        if (-not (Test-Path -LiteralPath $candidatePath)) {
            $currentPath = [System.IO.Path]::GetFullPath($candidatePath)
            continue
        }

        $candidateItem = Get-Item -LiteralPath $candidatePath -Force
        if (Test-IsLinkOrReparsePoint -Item $candidateItem) {
            # Get-PortableLinkTarget resolves the final link target portably: it uses the
            # native FileSystemInfo.ResolveLinkTarget($true) on PowerShell 7+ and the
            # LinkTarget/Target ETS members on Windows PowerShell 5.1, whose .NET Framework
            # FileSystemInfo has no ResolveLinkTarget method.
            try {
                $linkTargetPath = Get-PortableLinkTarget -Item $candidateItem
            }
            catch {
                throw "E_CONFIG_ERROR: unable to resolve symbolic link or reparse point '$candidatePath': $($_.Exception.Message)"
            }

            if ([string]::IsNullOrWhiteSpace($linkTargetPath)) {
                throw "E_CONFIG_ERROR: symbolic link or reparse point '$candidatePath' has no resolvable target."
            }

            $currentPath = [System.IO.Path]::GetFullPath($linkTargetPath)
            continue
        }

        $currentPath = [System.IO.Path]::GetFullPath($candidateItem.FullName)
    }

    return [System.IO.Path]::GetFullPath($currentPath)
}

function Convert-ToRedactedOutputLines {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$OutputLines = @()
    )

    if ($null -eq $OutputLines -or $OutputLines.Count -eq 0) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $redactedLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($OutputLines)) {
        $redactedLines.Add((Get-RedactedFailureLine -Line $line)) | Out-Null
    }

    return @($redactedLines.ToArray()) # array-unwrap-safe: callers always wrap with @()
}

function Write-IsolatedPesterFailureArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SuiteLabel,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootCode,

        [Parameter(Mandatory = $false)]
        [string[]]$StdoutLines = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$StderrLines = @(),

        [Parameter(Mandatory = $false)]
        [bool]$StdoutTruncated = $false,

        [Parameter(Mandatory = $false)]
        [bool]$StderrTruncated = $false,

        [Parameter(Mandatory = $true)]
        [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
        [string]$OutputVerbosity,

        [Parameter(Mandatory = $true)]
        [ValidateRange(30, 7200)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int]$StreamDrainTimeoutMilliseconds,

        [Parameter(Mandatory = $true)]
        [int]$ProcessBookkeepingTimeoutMilliseconds
    )

    $tempRoot = [System.IO.Path]::GetTempPath()
    $resolvedTempRoot = Resolve-CanonicalPath -Path $tempRoot
    $artifactDirectory = Join-Path -Path $resolvedTempRoot -ChildPath "wallstop-precommit-validation"

    $safeSuiteLabel = [regex]::Replace($SuiteLabel, '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeSuiteLabel)) {
        $safeSuiteLabel = "unknown-suite"
    }

    $timestampUtc = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssfffffffZ")
    $artifactNonce = [guid]::NewGuid().ToString("N")
    $artifactFileName = "isolated-pester-{0}-{1}-{2}.log" -f $safeSuiteLabel, $timestampUtc, $artifactNonce
    $artifactPath = Join-Path -Path $artifactDirectory -ChildPath $artifactFileName

    $resolvedRepoRoot = Resolve-CanonicalPath -Path $RepoRoot
    $resolvedArtifactPath = [System.IO.Path]::GetFullPath($artifactPath)
    $comparison = if (Test-IsWindowsPlatform) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    $normalizedRepoRoot = $resolvedRepoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $repoRootPrefix = "$normalizedRepoRoot$([System.IO.Path]::DirectorySeparatorChar)"
    if ($resolvedArtifactPath.StartsWith($repoRootPrefix, $comparison) -or $resolvedArtifactPath.Equals($normalizedRepoRoot, $comparison)) {
        throw "E_CONFIG_ERROR: isolated Pester failure artifact path must be outside repository root (repoRoot='$resolvedRepoRoot'; logPath='$resolvedArtifactPath')."
    }

    if (Test-Path -LiteralPath $artifactDirectory -PathType Container) {
        $artifactDirectoryItem = Get-Item -LiteralPath $artifactDirectory -Force
        if (Test-IsLinkOrReparsePoint -Item $artifactDirectoryItem) {
            throw "E_CONFIG_ERROR: isolated Pester failure artifact directory must not be a symbolic link or reparse point (logDirectory='$artifactDirectory')."
        }
    }
    else {
        [void](New-Item -ItemType Directory -Path $artifactDirectory -Force)
    }

    $resolvedArtifactDirectory = Resolve-CanonicalPath -Path $artifactDirectory
    $resolvedArtifactDirectoryItem = Get-Item -LiteralPath $resolvedArtifactDirectory -Force
    if (Test-IsLinkOrReparsePoint -Item $resolvedArtifactDirectoryItem) {
        throw "E_CONFIG_ERROR: isolated Pester failure artifact directory must not be a symbolic link or reparse point (logDirectory='$resolvedArtifactDirectory')."
    }

    $resolvedArtifactPath = Resolve-CanonicalPath -Path (Join-Path -Path $resolvedArtifactDirectory -ChildPath $artifactFileName)
    if ($resolvedArtifactPath.StartsWith($repoRootPrefix, $comparison) -or $resolvedArtifactPath.Equals($normalizedRepoRoot, $comparison)) {
        throw "E_CONFIG_ERROR: isolated Pester failure artifact path must be outside repository root (repoRoot='$resolvedRepoRoot'; logPath='$resolvedArtifactPath')."
    }

    $redactedStdoutLines = @(Convert-ToRedactedOutputLines -OutputLines $StdoutLines)
    $redactedStderrLines = @(Convert-ToRedactedOutputLines -OutputLines $StderrLines)

    $artifactLines = New-Object System.Collections.Generic.List[string]
    $artifactLines.Add("suite=$SuiteLabel") | Out-Null
    $artifactLines.Add("exitCode=$ExitCode") | Out-Null
    $artifactLines.Add("rootCode=$RootCode") | Out-Null
    $artifactLines.Add("capturedAtUtc=$([datetime]::UtcNow.ToString('o'))") | Out-Null
    $artifactLines.Add("outputVerbosity=$OutputVerbosity") | Out-Null
    $artifactLines.Add("timeoutSeconds=$TimeoutSeconds") | Out-Null
    $artifactLines.Add("streamDrainTimeoutMs=$StreamDrainTimeoutMilliseconds") | Out-Null
    $artifactLines.Add("processBookkeepingTimeoutMs=$ProcessBookkeepingTimeoutMilliseconds") | Out-Null
    $artifactLines.Add("stdoutLines=$($redactedStdoutLines.Count)") | Out-Null
    $artifactLines.Add("stderrLines=$($redactedStderrLines.Count)") | Out-Null
    $artifactLines.Add("stdoutTruncated=$StdoutTruncated") | Out-Null
    $artifactLines.Add("stderrTruncated=$StderrTruncated") | Out-Null
    $artifactLines.Add("") | Out-Null
    $artifactLines.Add("[stdout]") | Out-Null
    if ($redactedStdoutLines.Count -eq 0) {
        $artifactLines.Add("(no output)") | Out-Null
    }
    else {
        foreach ($stdoutLine in $redactedStdoutLines) {
            $artifactLines.Add($stdoutLine) | Out-Null
        }
    }

    $artifactLines.Add("") | Out-Null
    $artifactLines.Add("[stderr]") | Out-Null
    if ($redactedStderrLines.Count -eq 0) {
        $artifactLines.Add("(no output)") | Out-Null
    }
    else {
        foreach ($stderrLine in $redactedStderrLines) {
            $artifactLines.Add($stderrLine) | Out-Null
        }
    }

    $artifactContent = (($artifactLines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine
    $fileStream = [System.IO.FileStream]::new(
        $resolvedArtifactPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )

    try {
        $writer = [System.IO.StreamWriter]::new($fileStream, [System.Text.UTF8Encoding]::new($false))
        try {
            $writer.Write($artifactContent)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }

    return $resolvedArtifactPath
}

function Initialize-BoundedProcessCaptureType {
    if ($null -ne ("Wallstop.Utils.BoundedProcessCapture" -as [type])) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;

namespace Wallstop.Utils {
    public sealed class BoundedProcessCapture {
        private readonly int _maxLines;
        private readonly int _maxCharactersPerStream;
        private readonly object _stdoutLock = new object();
        private readonly object _stderrLock = new object();
        private readonly List<string> _stdoutLines = new List<string>();
        private readonly List<string> _stderrLines = new List<string>();
        private int _stdoutCharacterCount;
        private int _stderrCharacterCount;
        private bool _stdoutTruncated;
        private bool _stderrTruncated;
        // Keep continuations off the event-handler thread to avoid context-sensitive callbacks
        // running where no PowerShell runspace exists.
        private readonly TaskCompletionSource<bool> _stdoutCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _stderrCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        public BoundedProcessCapture(int maxLines, int maxCharactersPerStream) {
            _maxLines = maxLines;
            _maxCharactersPerStream = maxCharactersPerStream;
        }

        public bool StdoutTruncated {
            get { return _stdoutTruncated; }
        }

        public bool StderrTruncated {
            get { return _stderrTruncated; }
        }

        public bool IsStdoutCompleted {
            get { return _stdoutCompleted.Task.IsCompleted; }
        }

        public bool IsStderrCompleted {
            get { return _stderrCompleted.Task.IsCompleted; }
        }

        public bool HasStreamFaults {
            get { return _stdoutCompleted.Task.IsFaulted || _stderrCompleted.Task.IsFaulted; }
        }

        public string GetFaultSummary() {
            var faults = new List<string>();

            if (_stdoutCompleted.Task.IsFaulted && _stdoutCompleted.Task.Exception != null) {
                faults.Add("stdout=" + _stdoutCompleted.Task.Exception.GetBaseException().Message);
            }

            if (_stderrCompleted.Task.IsFaulted && _stderrCompleted.Task.Exception != null) {
                faults.Add("stderr=" + _stderrCompleted.Task.Exception.GetBaseException().Message);
            }

            if (faults.Count == 0) {
                return "unknown stream failure";
            }

            return string.Join("; ", faults);
        }

        public bool WaitForDrain(int timeoutMilliseconds) {
            return Task.WaitAll(new Task[] { _stdoutCompleted.Task, _stderrCompleted.Task }, timeoutMilliseconds);
        }

        public string[] GetStdoutLines() {
            lock (_stdoutLock) {
                return _stdoutLines.ToArray();
            }
        }

        public string[] GetStderrLines() {
            lock (_stderrLock) {
                return _stderrLines.ToArray();
            }
        }

        public void Attach(Process process) {
            process.OutputDataReceived += OnOutputDataReceived;
            process.ErrorDataReceived += OnErrorDataReceived;
        }

        public void Detach(Process process) {
            process.OutputDataReceived -= OnOutputDataReceived;
            process.ErrorDataReceived -= OnErrorDataReceived;
        }

        private void OnOutputDataReceived(object sender, DataReceivedEventArgs eventArgs) {
            HandleData(
                eventArgs,
                _stdoutLines,
                _stdoutLock,
                ref _stdoutCharacterCount,
                ref _stdoutTruncated,
                _stdoutCompleted,
                "stdout"
            );
        }

        private void OnErrorDataReceived(object sender, DataReceivedEventArgs eventArgs) {
            HandleData(
                eventArgs,
                _stderrLines,
                _stderrLock,
                ref _stderrCharacterCount,
                ref _stderrTruncated,
                _stderrCompleted,
                "stderr"
            );
        }

        private void HandleData(
            DataReceivedEventArgs eventArgs,
            List<string> lineList,
            object lineLock,
            ref int characterCount,
            ref bool truncated,
            TaskCompletionSource<bool> completion,
            string streamName
        ) {
            try {
                if (eventArgs.Data == null) {
                    completion.TrySetResult(true);
                    return;
                }

                lock (lineLock) {
                    if (truncated) {
                        return;
                    }

                    string line = eventArgs.Data;
                    int nextCharacterCount = characterCount + line.Length + 1;
                    if (lineList.Count >= _maxLines || nextCharacterCount > _maxCharactersPerStream) {
                        truncated = true;
                        lineList.Add("[" + streamName + " output truncated after " + lineList.Count + " line(s)]");
                        return;
                    }

                    lineList.Add(line);
                    characterCount = nextCharacterCount;
                }
            }
            catch (Exception exception) {
                completion.TrySetException(exception);
            }
        }
    }
}
"@
}

function Assert-PreCommitPowerShellModuleAvailability {
    param(
        [Parameter(Mandatory = $false)]
        [switch]$RequirePester,

        [Parameter(Mandatory = $false)]
        [switch]$RequireScriptAnalyzer
    )

    $requirements = New-Object System.Collections.Generic.List[object]

    if ($RequirePester) {
        $requirements.Add([pscustomobject]@{
                ModuleName      = "Pester"
                MinimumVersion  = [version]"5.5.0"
                CommandNames    = @("Invoke-Pester")
                InstallCommand  = "pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules Pester"
                AdditionalNotes = @(
                    "Manual fallback: Install-Module Pester -Repository PSGallery -Scope CurrentUser -MinimumVersion 5.5.0 -Force"
                    "Windows note: built-in Windows PowerShell ships Pester 3.4.0, which is incompatible with this suite."
                )
            }) | Out-Null
    }

    if ($RequireScriptAnalyzer) {
        $requirements.Add([pscustomobject]@{
                ModuleName      = "PSScriptAnalyzer"
                MinimumVersion  = [version]"1.21.0"
                CommandNames    = @("Invoke-ScriptAnalyzer")
                InstallCommand  = "pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules PSScriptAnalyzer"
                AdditionalNotes = @("Manual fallback: Install-Module PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -MinimumVersion 1.21.0 -Force")
            }) | Out-Null
    }

    Assert-ModuleCommandRequirements -Requirements ($requirements.ToArray()) -ErrorCode "E_PRECOMMIT_VALIDATION_MODULES_MISSING" -ContextLabel "Pre-commit module prerequisites"
}

function Invoke-PesterQualityGateInIsolatedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TestPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SuiteLabel,

        [Parameter(Mandatory = $true)]
        [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
        [string]$OutputVerbosity,

        [Parameter(Mandatory = $true)]
        [ValidateRange(30, 7200)]
        [int]$TimeoutSeconds
    )

    $pesterGateScriptPath = Join-Path -Path $RepoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
    if (-not (Test-Path -Path $pesterGateScriptPath -PathType Leaf)) {
        throw "E_CONFIG_ERROR: Pester quality gate script is missing at '$pesterGateScriptPath'."
    }

    if (-not (Test-Path -Path $TestPath)) {
        throw "E_CONFIG_ERROR: Pester test path was not found at '$TestPath'."
    }

    $pwshExecutable = Get-PwshExecutableOrThrow
    $timeoutMilliseconds = $TimeoutSeconds * 1000
    $streamDrainTimeoutMilliseconds = [math]::Min([math]::Max([int]($timeoutMilliseconds / 10), 2000), 15000)
    $processBookkeepingTimeoutMilliseconds = 5000
    $maxCapturedOutputLinesPerStream = 2000
    $maxCapturedOutputCharactersPerStream = 262144
    $process = $null
    $capture = $null

    Initialize-BoundedProcessCaptureType

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshExecutable
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "PSModulePath" -Value $env:PSModulePath
        $pathSeparator = [System.IO.Path]::PathSeparator
        $modulePathEntryCount = @($env:PSModulePath -split [regex]::Escape([string]$pathSeparator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        Write-Verbose ("Isolated Pester environment diagnostics: inheritedModulePathEntryCount={0}" -f $modulePathEntryCount)

        # ProcessStartInfo.ArgumentList is .NET Core-only; Set-PortableProcessArguments uses it
        # on PowerShell 7+ and an equivalently escaped .Arguments string on Windows PowerShell
        # 5.1, whose .NET Framework ProcessStartInfo has no ArgumentList property.
        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            $pesterGateScriptPath,
            "-TestPath",
            $TestPath,
            "-DiagnosticsPrefix",
            $SuiteLabel,
            "-OutputVerbosity",
            $OutputVerbosity
        )

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $capture = [Wallstop.Utils.BoundedProcessCapture]::new($maxCapturedOutputLinesPerStream, $maxCapturedOutputCharactersPerStream)
        $capture.Attach($process)

        if (-not $process.Start()) {
            throw "E_TEST_PROCESS_START_FAILED: unable to start isolated Pester process for $SuiteLabel."
        }

        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        if (-not $process.WaitForExit($timeoutMilliseconds)) {
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                # Preserve timeout diagnostics if process termination fails.
            }

            throw "E_TEST_TIMEOUT: $SuiteLabel timed out after $TimeoutSeconds seconds in isolated Pester execution."
        }

        # After process exit, allow a full bounded drain window for async stream callbacks.
        $remainingStreamWaitMilliseconds = $streamDrainTimeoutMilliseconds

        if (-not $capture.WaitForDrain($remainingStreamWaitMilliseconds)) {
            $pendingStreams = New-Object System.Collections.Generic.List[string]
            if (-not $capture.IsStdoutCompleted) {
                $pendingStreams.Add("stdout") | Out-Null
            }
            if (-not $capture.IsStderrCompleted) {
                $pendingStreams.Add("stderr") | Out-Null
            }

            $pendingStreamsText = if ($pendingStreams.Count -gt 0) { $pendingStreams -join "," } else { "unknown" }
            throw "E_TEST_CAPTURE_TIMEOUT: $SuiteLabel output capture exceeded ${remainingStreamWaitMilliseconds}ms after process exit (pendingStreams=$pendingStreamsText)."
        }

        if ($capture.HasStreamFaults) {
            $faultSummary = $capture.GetFaultSummary()
            throw "E_TEST_CAPTURE_FAILED: $SuiteLabel stream capture failed ($faultSummary)."
        }

        $stdoutLines = @($capture.GetStdoutLines())
        $stderrLines = @($capture.GetStderrLines())
        $stdoutWasTruncated = $capture.StdoutTruncated
        $stderrWasTruncated = $capture.StderrTruncated

        try {
            $process.CancelOutputRead()
        }
        catch {
            Write-Verbose "Isolated Pester cleanup diagnostics: unable to cancel stdout read after capture completion."
        }

        try {
            $process.CancelErrorRead()
        }
        catch {
            Write-Verbose "Isolated Pester cleanup diagnostics: unable to cancel stderr read after capture completion."
        }

        # Ensure process bookkeeping has fully settled before reading ExitCode.
        # Use a bounded wait to avoid indefinite hangs in degraded host environments.
        if (-not $process.WaitForExit($processBookkeepingTimeoutMilliseconds)) {
            throw "E_TEST_CAPTURE_TIMEOUT: $SuiteLabel process bookkeeping wait exceeded ${processBookkeepingTimeoutMilliseconds}ms after stream drain completion."
        }

        $combinedLines = @($stdoutLines)
        if ($stderrLines.Count -gt 0) {
            $combinedLines += @($stderrLines | ForEach-Object { "stderr: $_" })
        }

        Write-Verbose (
            "Isolated Pester diagnostics: suite={0}; exitCode={1}; timeoutSeconds={2}; stdoutLines={3}; stderrLines={4}; outputVerbosity={5}; stdoutTruncated={6}; stderrTruncated={7}; streamDrainTimeoutMs={8}; processBookkeepingTimeoutMs={9}" -f
            $SuiteLabel,
            $process.ExitCode,
            $TimeoutSeconds,
            $stdoutLines.Count,
            $stderrLines.Count,
            $OutputVerbosity,
            $stdoutWasTruncated,
            $stderrWasTruncated,
            $streamDrainTimeoutMilliseconds,
            $processBookkeepingTimeoutMilliseconds
        )

        if ($process.ExitCode -ne 0) {
            $rootCode = Get-FirstRootErrorCode -OutputLines $combinedLines
            $redactedCombinedLines = @(Convert-ToRedactedOutputLines -OutputLines $combinedLines)
            $preview = Get-OutputPreview -OutputLines $redactedCombinedLines -MaxPreviewLines 4 -FilterBlankLines -HeadTailWhenTruncated -PerLineMaxCharacters 240
            $artifactLogPath = "(artifact-unavailable)"

            try {
                $artifactLogPath = Write-IsolatedPesterFailureArtifact -RepoRoot $RepoRoot -SuiteLabel $SuiteLabel -ExitCode $process.ExitCode -RootCode $rootCode -StdoutLines $stdoutLines -StderrLines $stderrLines -StdoutTruncated:$stdoutWasTruncated -StderrTruncated:$stderrWasTruncated -OutputVerbosity $OutputVerbosity -TimeoutSeconds $TimeoutSeconds -StreamDrainTimeoutMilliseconds $streamDrainTimeoutMilliseconds -ProcessBookkeepingTimeoutMilliseconds $processBookkeepingTimeoutMilliseconds
            }
            catch {
                Write-Verbose (
                    "Isolated Pester artifact diagnostics: suite={0}; exitCode={1}; rootCode={2}; artifactWriteFailure={3}" -f
                    $SuiteLabel,
                    $process.ExitCode,
                    $rootCode,
                    $_.Exception.Message
                )
            }

            Write-Warning (
                "W_TEST_FAILURE_OUTPUT_PREVIEW: suite={0}; exitCode={1}; stdoutLines={2}; stderrLines={3}; preview={4}" -f
                $SuiteLabel,
                $process.ExitCode,
                $stdoutLines.Count,
                $stderrLines.Count,
                $preview
            )
            Write-Warning (
                "W_TEST_FAILURE_ARTIFACT: suite={0}; exitCode={1}; rootCode={2}; logPath={3}" -f
                $SuiteLabel,
                $process.ExitCode,
                $rootCode,
                $artifactLogPath
            )
            throw "E_TEST_FAILURE: $SuiteLabel failed in isolated Pester execution (exitCode=$($process.ExitCode); rootCode=$rootCode; details=see W_TEST_FAILURE_ARTIFACT)."
        }
    }
    finally {
        if ($null -ne $process) {
            if ($null -ne $capture) {
                try {
                    $capture.Detach($process)
                }
                catch {
                    Write-Verbose "Isolated Pester cleanup diagnostics: failed to detach stream capture handlers."
                }
            }

            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Isolated Pester cleanup diagnostics: failed to kill process '$SuiteLabel': $($_.Exception.Message)"
            }

            try {
                $process.Dispose()
            }
            catch {
                Write-Verbose "Isolated Pester cleanup diagnostics: process resource disposal raised exception: $($_.Exception.Message)"
            }
        }
    }
}

if ($NoInvokeMain) {
    return
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
Push-Location -LiteralPath $repoRoot

try {
    $gitExecutable = Get-GitExecutableOrThrow
    $normalizedTargetFiles = @(
        @(Get-PreCommitValidationTargetFiles -ExplicitFiles (@($TargetFiles) + @($RemainingTargetFiles)) -ListPath $TargetFileListPath) |
            ForEach-Object { ConvertTo-NormalizedRelativeTargetPath -Path $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    if ($All -and $normalizedTargetFiles.Count -gt 0) {
        throw "E_PRECOMMIT_VALIDATION_ARG_CONFLICT: -All cannot be combined with explicit target files."
    }
    if ($AllowPreCommitOwnedFixes -and -not $IncludePreCommitOwnedChecks) {
        throw "E_PRECOMMIT_VALIDATION_ARG_CONFLICT: -AllowPreCommitOwnedFixes requires -IncludePreCommitOwnedChecks."
    }

    $stagedFiles = @()
    if (-not $All) {
        if ($normalizedTargetFiles.Count -gt 0) {
            $stagedFiles = @($normalizedTargetFiles)
        }
        else {
            $stagedFiles = @(Get-StagedFilesWithIndexLockRecoveryOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repoRoot)
        }
    }

    $utilsScriptPattern = '^Scripts/Utils/.+\.ps1$'
    $utilsPesterPattern = '^Tests/Utils/.+\.Tests\.ps1$'
    $githubTestPattern = '^(Scripts/Utils/GitHub|Tests/GitHub)/.+\.ps1$'
    $scriptPattern = '^Scripts/Utils/.+\.ps1$'
    $shellQualityPattern = '^(Scripts/.+\.sh|\.devcontainer/.+\.sh|\.githooks/(pre-commit|pre-push))$'
    $shellSafetyTriggerPattern = '^(Scripts/.+\.sh|\.devcontainer/.+\.sh|\.githooks/(pre-commit|pre-push)|Tests/Utils/ScriptSafetyConventions\.Tests\.ps1)$'
    $nativeQualityPattern = '^(Config/Wezterm/wezterm\.lua|\.github/workflows/.+\.(yml|yaml))$'
    $windowsLanguagePattern = '^(Scripts/AutoHotKey/.+\.ahk|Config/\.config/.+\.ahk|Scripts/.+\.bat)$'
    $compatibilityTargetPattern = '^(Scripts|Config|Tests)/.+\.(ps1|psm1)$'
    $governanceConfigFiles = @(
        ".pre-commit-config.yaml",
        ".gitattributes",
        ".editorconfig",
        ".gitignore",
        ".psscriptanalyzer.psd1",
        ".psscriptanalyzer.format.psd1",
        ".shellcheckrc",
        ".stylua.toml",
        "requirements.txt",
        "Scripts/Utils/Quality/native-quality-tools.json",
        "Scripts/Utils/Quality/shell-quality-tools.json"
    )
    $governanceConfigPattern = '^(\.pre-commit-config\.yaml|\.gitattributes|\.editorconfig|\.gitignore|requirements\.txt|\.psscriptanalyzer(\.format)?\.psd1|\.shellcheckrc|\.stylua\.toml|Scripts/Utils/Quality/(native-quality-tools|shell-quality-tools)\.json)$'

    $contextPath = Join-Path -Path $repoRoot -ChildPath '.llm/context.md'
    $llmHarnessPatternSource = 'wrapper-contract'
    $llmHarnessWrapperFiles = @()
    if (Test-Path -Path $contextPath -PathType Leaf) {
        $llmHarnessWrapperFiles = @(Get-WrapperContractEntries -ContextFilePath $contextPath)
        if ($llmHarnessWrapperFiles.Count -eq 0) {
            throw 'E_CONFIG_ERROR: Wrapper Contract section in .llm/context.md lists no wrapper files; cannot derive LLM harness trigger pattern.'
        }
    }
    else {
        $llmHarnessPatternSource = 'fallback-default-wrapper-set'
        $llmHarnessWrapperFiles = @('AGENTS.md', '.github/copilot-instructions.md', 'CLAUDE.md')
    }

    $llmHarnessPattern = New-LlmHarnessPattern -WrapperFiles $llmHarnessWrapperFiles
    Write-Verbose ("LLM harness trigger diagnostics: source={0}; wrapperCount={1}; wrappers={2}; pattern={3}" -f $llmHarnessPatternSource, $llmHarnessWrapperFiles.Count, ($llmHarnessWrapperFiles -join ','), $llmHarnessPattern)

    $utilsScriptFiles = @($stagedFiles | Where-Object { $_ -match $utilsScriptPattern })
    $utilsTestFiles = @($stagedFiles | Where-Object { $_ -match $utilsPesterPattern })
    $githubTestFiles = @($stagedFiles | Where-Object { $_ -match $githubTestPattern })
    $scriptFiles = @($stagedFiles | Where-Object { $_ -match $scriptPattern })
    $compatibilityTargetFiles = @()
    if ($All) {
        $trackedFileOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments @("-C", $repoRoot, "ls-files") -FailureMessage "E_CONFIG_ERROR: Failed to read tracked files using 'git ls-files'")

        $shellQualityFiles = @($trackedFileOutput | Where-Object { $_ -match $shellQualityPattern })
        $nativeQualityFiles = @($trackedFileOutput | Where-Object { $_ -match $nativeQualityPattern })
        $compatibilityTargetFiles = @(
            $trackedFileOutput |
                Where-Object { $_ -match $compatibilityTargetPattern } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Sort-Object -Unique
        )
    }
    elseif ($IncludePreCommitOwnedChecks) {
        $shellQualityFiles = @($stagedFiles | Where-Object { $_ -match $shellQualityPattern })
        $nativeQualityFiles = @($stagedFiles | Where-Object { $_ -match $nativeQualityPattern })
        $compatibilityTargetFiles = @(
            $stagedFiles |
                Where-Object { $_ -match $compatibilityTargetPattern } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Sort-Object -Unique
        )
    }
    else {
        $shellQualityFiles = @()
        $nativeQualityFiles = @()
        $compatibilityTargetFiles = @(
            $stagedFiles |
                Where-Object { $_ -match $compatibilityTargetPattern } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Sort-Object -Unique
        )
    }
    $shellSafetyFiles = @($stagedFiles | Where-Object { $_ -match $shellSafetyTriggerPattern })
    $windowsLanguageFiles = @($stagedFiles | Where-Object { $_ -match $windowsLanguagePattern })
    $llmHarnessFiles = @($stagedFiles | Where-Object { $_ -match $llmHarnessPattern })
    $governanceFiles = @(
        if ($All) {
            $governanceConfigFiles | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        }
        else {
            $stagedFiles | Where-Object { $_ -match $governanceConfigPattern }
        }
    )

    $utilsTestTargets = @()
    if ($All) {
        $utilsTestTargets = @((Join-Path -Path $repoRoot -ChildPath 'Tests/Utils'))
    }
    else {
        $utilsTestTargets = @()
    }

    $analyzerTargets = @()
    if ($All) {
        $analyzerTargets = @("Scripts/Utils")
    }
    elseif ($scriptFiles.Count -gt 0) {
        $missingAnalyzerTargets = @(
            $scriptFiles |
                Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) } |
                Sort-Object -Unique
        )
        if ($missingAnalyzerTargets.Count -gt 0) {
            Write-Verbose (
                "ScriptAnalyzer staged-path diagnostics: skippedMissingCount={0}; skippedMissingTargets={1}" -f
                $missingAnalyzerTargets.Count,
                ($missingAnalyzerTargets -join ', ')
            )
        }

        $analyzerTargets = @(
            $scriptFiles |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Sort-Object -Unique
        )
    }

    $runUtilsTests = $All -and $utilsTestTargets.Count -gt 0
    $runGitHubTests = $All
    $runShellQualityChecks = $All -or $shellQualityFiles.Count -gt 0
    $runNativeQualityChecks = $All -or $nativeQualityFiles.Count -gt 0
    $runShellSafetySuite = $All -and -not $runUtilsTests
    $runWindowsLanguageChecks = $All -or $windowsLanguageFiles.Count -gt 0
    $runCompatibilityGate = $compatibilityTargetFiles.Count -gt 0
    $runAnalyzer = $analyzerTargets.Count -gt 0
    $runFormatOperatorSafetyCheck = $All -or $scriptFiles.Count -gt 0 -or $utilsTestFiles.Count -gt 0 -or $githubTestFiles.Count -gt 0
    $runLlmHarnessValidation = $All -or $llmHarnessFiles.Count -gt 0
    $runGovernanceValidation = $All -or $governanceFiles.Count -gt 0
    $preCommitOwnedFixesEnabled = $All -or $AllowPreCommitOwnedFixes
    $analyzerTargetsText = if ($analyzerTargets.Count -gt 0) { $analyzerTargets -join ', ' } else { '(none)' }
    $utilsTestTargetsText = if ($utilsTestTargets.Count -gt 0) { $utilsTestTargets -join ', ' } else { '(none)' }
    $compatibilityTargetFilesText = if ($compatibilityTargetFiles.Count -gt 0) { $compatibilityTargetFiles -join ', ' } else { '(none)' }
    $shellQualityMatchedFilesText = if ($shellQualityFiles.Count -gt 0) { $shellQualityFiles -join ', ' } else { '(none)' }
    $nativeQualityMatchedFilesText = if ($nativeQualityFiles.Count -gt 0) { $nativeQualityFiles -join ', ' } else { '(none)' }
    $shellSafetyMatchedFilesText = if ($shellSafetyFiles.Count -gt 0) { $shellSafetyFiles -join ', ' } else { '(none)' }
    $windowsLanguageMatchedFilesText = if ($windowsLanguageFiles.Count -gt 0) { $windowsLanguageFiles -join ', ' } else { '(none)' }
    $llmHarnessMatchedFilesText = if ($llmHarnessFiles.Count -gt 0) { $llmHarnessFiles -join ', ' } else { '(none)' }
    $governanceMatchedFilesText = if ($governanceFiles.Count -gt 0) { $governanceFiles -join ', ' } else { '(none)' }

    Write-Verbose (
        "Validation trigger summary: allMode={0}; stagedCount={1}; runUtilsTests={2}; runGitHubTests={3}; runShellQualityChecks={4}; runNativeQualityChecks={5}; runShellSafetySuite={6}; runWindowsLanguageChecks={7}; runCompatibilityGate={8}; runAnalyzer={9}; analyzerTargetCount={10}; runLlmHarnessValidation={11}; runGovernanceValidation={12}" -f
        $All.IsPresent,
        $stagedFiles.Count,
        $runUtilsTests,
        $runGitHubTests,
        $runShellQualityChecks,
        $runNativeQualityChecks,
        $runShellSafetySuite,
        $runWindowsLanguageChecks,
        $runCompatibilityGate,
        $runAnalyzer,
        $analyzerTargets.Count,
        $runLlmHarnessValidation,
        $runGovernanceValidation
    )
    Write-Verbose ("ScriptAnalyzer target diagnostics: allMode={0}; targetCount={1}; targets={2}" -f $All.IsPresent, $analyzerTargets.Count, $analyzerTargetsText)
    Write-Verbose ("Utils test target diagnostics: allMode={0}; targetCount={1}; targets={2}" -f $All.IsPresent, $utilsTestTargets.Count, $utilsTestTargetsText)
    Write-Verbose ("Compatibility target diagnostics: allMode={0}; targetCount={1}; targets={2}" -f $All.IsPresent, $compatibilityTargetFiles.Count, $compatibilityTargetFilesText)

    if (-not $All -and $utilsScriptFiles.Count -gt 0 -and $utilsTestTargets.Count -eq 0) {
        Write-Verbose (
            "Skipping Tests/Utils Pester suite for script-only staged changes in fast local mode; full suite remains enforced in -All/full validation. Staged utils scripts: {0}" -f
            ($utilsScriptFiles -join ', ')
        )
    }

    if ($runLlmHarnessValidation) {
        Write-Host ("Running LLM harness validation... allMode={0}; source={1}; matchedCount={2}" -f $All.IsPresent, $llmHarnessPatternSource, $llmHarnessFiles.Count)
        Write-Verbose ("LLM harness staged-file diagnostics: allMode={0}; source={1}; matchedCount={2}; matchedFiles={3}" -f $All.IsPresent, $llmHarnessPatternSource, $llmHarnessFiles.Count, $llmHarnessMatchedFilesText)
    }
    else {
        Write-Verbose ("Skipping LLM harness validation: allMode={0}; source={1}; matchedCount={2}" -f $All.IsPresent, $llmHarnessPatternSource, $llmHarnessFiles.Count)
    }

    if (-not $runUtilsTests -and -not $runGitHubTests -and -not $runShellQualityChecks -and -not $runNativeQualityChecks -and -not $runShellSafetySuite -and -not $runWindowsLanguageChecks -and -not $runCompatibilityGate -and -not $runAnalyzer -and -not $runLlmHarnessValidation -and -not $runGovernanceValidation) {
        Write-Verbose "No staged files requiring utility validation; skipping validation."
        return
    }

    if ($runGovernanceValidation) {
        Write-Host ("Running hook governance validation... allMode={0}; matchedCount={1}" -f $All.IsPresent, $governanceFiles.Count)
        Write-Verbose ("Governance validation trigger diagnostics: allMode={0}; matchedCount={1}; matchedFiles={2}" -f $All.IsPresent, $governanceFiles.Count, $governanceMatchedFilesText)
        Invoke-PreCommitGovernanceValidation -RepoRoot $repoRoot -TargetFiles $governanceFiles
    }

    if ($runWindowsLanguageChecks) {
        Write-Verbose (
            "Windows language trigger diagnostics: allMode={0}; matchedCount={1}; matchedFiles={2}" -f
            $All.IsPresent,
            $windowsLanguageFiles.Count,
            $windowsLanguageMatchedFilesText
        )

        if (-not $All) {
            $windowsLanguageDiffArgs = @("-C", $repoRoot, "diff", "--name-only", "--") + @($windowsLanguageFiles)
            $unstagedWindowsLanguageDiffOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments $windowsLanguageDiffArgs -FailureMessage "E_CONFIG_ERROR: Failed to check unstaged Windows language drift with git diff")

            $unstagedWindowsLanguageFiles = @(
                $unstagedWindowsLanguageDiffOutput |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )
            if ($unstagedWindowsLanguageFiles.Count -gt 0) {
                $unstagedWindowsLanguageText = $unstagedWindowsLanguageFiles -join ', '
                throw "E_PRECOMMIT_WINDOWS_LANGUAGE_RESTAGE_REQUIRED: Staged Windows language files have unstaged working-tree changes: $unstagedWindowsLanguageText. Run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1 -TargetFiles <paths> -Fix', stage the updated files, then rerun pre-commit validation."
            }
        }
    }

    if ($runShellSafetySuite) {
        Write-Verbose (
            "Shell safety trigger diagnostics: allMode={0}; matchedCount={1}; matchedFiles={2}" -f
            $All.IsPresent,
            $shellSafetyFiles.Count,
            $shellSafetyMatchedFilesText
        )
    }

    if ($runShellQualityChecks) {
        Write-Verbose (
            "Shell quality trigger diagnostics: allMode={0}; matchedCount={1}; matchedFiles={2}" -f
            $All.IsPresent,
            $shellQualityFiles.Count,
            $shellQualityMatchedFilesText
        )

        $shellQualityScriptPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1"
        if (-not (Test-Path -LiteralPath $shellQualityScriptPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: Shell quality checker is missing at '$shellQualityScriptPath'."
        }

        if ($shellQualityFiles.Count -gt 0) {
            $shellQualityDiffArgs = @("-C", $repoRoot, "diff", "--name-only", "--") + @($shellQualityFiles)
            $preShellQualityDiffOutput = @()
            $preShellQualityDirtyFileHashes = @{}
            if ($All) {
                $preShellQualityDiffOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments $shellQualityDiffArgs -FailureMessage "E_CONFIG_ERROR: Failed to check pre-format shell quality drift with git diff")

                $preShellQualityDiffOutput = @(
                    $preShellQualityDiffOutput |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Sort-Object -Unique
                )
                $preShellQualityDirtyFileHashes = Get-RelativeFileHashSnapshot -RepoRoot $repoRoot -RelativePaths $preShellQualityDiffOutput
            }
            elseif ($preCommitOwnedFixesEnabled) {
                $unstagedShellQualityDiffOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments $shellQualityDiffArgs -FailureMessage "E_CONFIG_ERROR: Failed to check unstaged shell quality drift with git diff")

                $unstagedShellQualityFiles = @(
                    $unstagedShellQualityDiffOutput |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Sort-Object -Unique
                )
                if ($unstagedShellQualityFiles.Count -gt 0) {
                    $unstagedShellQualityText = $unstagedShellQualityFiles -join ', '
                    throw "E_PRECOMMIT_SHELL_QUALITY_RESTAGE_REQUIRED: Staged shell files have unstaged working-tree changes: $unstagedShellQualityText. Run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1 -Tool All -Fix <paths>', stage the updated files, then rerun pre-commit validation."
                }
            }

            $shellQualityModeText = if ($preCommitOwnedFixesEnabled) { "formatting and lint" } else { "lint/format-check" }
            Write-Host "Running shell $shellQualityModeText validation..."
            if ($preCommitOwnedFixesEnabled) {
                & $shellQualityScriptPath -Tool All -Fix @shellQualityFiles
            }
            else {
                & $shellQualityScriptPath -Tool All @shellQualityFiles
            }

            if ($preCommitOwnedFixesEnabled) {
                $postShellQualityDiffOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments $shellQualityDiffArgs -FailureMessage "E_CONFIG_ERROR: Failed to check post-format shell quality drift with git diff")

                $formattedShellQualityFiles = @(
                    $postShellQualityDiffOutput |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Sort-Object -Unique
                )

                $allModeFormatterModifiedDirtyFiles = @()
                if ($All -and $preShellQualityDiffOutput.Count -gt 0) {
                    $postShellQualityDirtyFileHashes = Get-RelativeFileHashSnapshot -RepoRoot $repoRoot -RelativePaths $preShellQualityDiffOutput
                    $allModeFormatterModifiedDirtyFiles = @(
                        foreach ($relativePath in $preShellQualityDiffOutput) {
                            $beforeHash = [string]$preShellQualityDirtyFileHashes[$relativePath]
                            $afterHash = [string]$postShellQualityDirtyFileHashes[$relativePath]
                            if ($beforeHash -ne $afterHash) {
                                $relativePath
                            }
                        }
                    )
                }

                if ($All) {
                    Write-Verbose (
                        "Shell quality all-mode drift snapshots: beforeCount={0}; afterCount={1}; beforeFiles={2}; afterFiles={3}; preDirtyModifiedCount={4}" -f
                        $preShellQualityDiffOutput.Count,
                        $formattedShellQualityFiles.Count,
                        ($(if ($preShellQualityDiffOutput.Count -gt 0) { $preShellQualityDiffOutput -join ', ' } else { '(none)' })),
                        ($(if ($formattedShellQualityFiles.Count -gt 0) { $formattedShellQualityFiles -join ', ' } else { '(none)' })),
                        $allModeFormatterModifiedDirtyFiles.Count
                    )
                }

                $shellFormatterChangedFiles = @(
                    if ($All) {
                        $allModeNewlyDirtyFiles = @(
                            Compare-Object -ReferenceObject $preShellQualityDiffOutput -DifferenceObject $formattedShellQualityFiles |
                                Where-Object { $_.SideIndicator -eq '=>' } |
                                ForEach-Object { [string]$_.InputObject }
                        )

                        $allModeNewlyDirtyFiles + $allModeFormatterModifiedDirtyFiles |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                            Sort-Object -Unique
                    }
                    else {
                        $formattedShellQualityFiles
                    }
                )

                if ($shellFormatterChangedFiles.Count -gt 0) {
                    $formattedShellQualityText = $shellFormatterChangedFiles -join ', '
                    throw "E_PRECOMMIT_SHELL_QUALITY_RESTAGE_REQUIRED: Shell formatter updated file(s): $formattedShellQualityText. Stage the updated files, then rerun pre-commit validation."
                }
            }
        }
    }

    if ($runNativeQualityChecks) {
        Write-Verbose (
            "Native quality trigger diagnostics: allMode={0}; matchedCount={1}; matchedFiles={2}" -f
            $All.IsPresent,
            $nativeQualityFiles.Count,
            $nativeQualityMatchedFilesText
        )

        $nativeQualityScriptPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1"
        if (-not (Test-Path -LiteralPath $nativeQualityScriptPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: Native quality checker is missing at '$nativeQualityScriptPath'."
        }

        if ($nativeQualityFiles.Count -gt 0) {
            $nativeQualityDiffArgs = @("-C", $repoRoot, "diff", "--name-only", "--") + @($nativeQualityFiles)
            $preNativeQualityDiffOutput = @()
            $preNativeQualityDirtyFileHashes = @{}
            if ($All) {
                $preNativeQualityDiffOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments $nativeQualityDiffArgs -FailureMessage "E_CONFIG_ERROR: Failed to check pre-format native quality drift with git diff")

                $preNativeQualityDiffOutput = @(
                    $preNativeQualityDiffOutput |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Sort-Object -Unique
                )
                $preNativeQualityDirtyFileHashes = Get-RelativeFileHashSnapshot -RepoRoot $repoRoot -RelativePaths $preNativeQualityDiffOutput
            }
            elseif ($preCommitOwnedFixesEnabled) {
                $unstagedNativeQualityDiffOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments $nativeQualityDiffArgs -FailureMessage "E_CONFIG_ERROR: Failed to check unstaged native quality drift with git diff")

                $unstagedNativeQualityFiles = @(
                    $unstagedNativeQualityDiffOutput |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Sort-Object -Unique
                )
                if ($unstagedNativeQualityFiles.Count -gt 0) {
                    $unstagedNativeQualityText = $unstagedNativeQualityFiles -join ', '
                    throw "E_PRECOMMIT_NATIVE_QUALITY_RESTAGE_REQUIRED: Staged native quality files have unstaged working-tree changes: $unstagedNativeQualityText. Run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1 -Tool All -Fix <paths>', stage the updated files, then rerun pre-commit validation."
                }
            }

            Write-Host "Running Lua and GitHub workflow native quality validation..."
            if ($preCommitOwnedFixesEnabled) {
                & $nativeQualityScriptPath -Tool All -Fix @nativeQualityFiles
            }
            else {
                & $nativeQualityScriptPath -Tool All @nativeQualityFiles
            }

            if ($preCommitOwnedFixesEnabled) {
                $postNativeQualityDiffOutput = @(Invoke-GitStdoutOrThrow -GitExecutable $gitExecutable -Arguments $nativeQualityDiffArgs -FailureMessage "E_CONFIG_ERROR: Failed to check post-format native quality drift with git diff")

                $formattedNativeQualityFiles = @(
                    $postNativeQualityDiffOutput |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Sort-Object -Unique
                )

                $allModeFormatterModifiedDirtyFiles = @()
                if ($All -and $preNativeQualityDiffOutput.Count -gt 0) {
                    $postNativeQualityDirtyFileHashes = Get-RelativeFileHashSnapshot -RepoRoot $repoRoot -RelativePaths $preNativeQualityDiffOutput
                    $allModeFormatterModifiedDirtyFiles = @(
                        foreach ($relativePath in $preNativeQualityDiffOutput) {
                            $beforeHash = [string]$preNativeQualityDirtyFileHashes[$relativePath]
                            $afterHash = [string]$postNativeQualityDirtyFileHashes[$relativePath]
                            if ($beforeHash -ne $afterHash) {
                                $relativePath
                            }
                        }
                    )
                }

                if ($All) {
                    Write-Verbose (
                        "Native quality all-mode drift snapshots: beforeCount={0}; afterCount={1}; beforeFiles={2}; afterFiles={3}; preDirtyModifiedCount={4}" -f
                        $preNativeQualityDiffOutput.Count,
                        $formattedNativeQualityFiles.Count,
                        ($(if ($preNativeQualityDiffOutput.Count -gt 0) { $preNativeQualityDiffOutput -join ', ' } else { '(none)' })),
                        ($(if ($formattedNativeQualityFiles.Count -gt 0) { $formattedNativeQualityFiles -join ', ' } else { '(none)' })),
                        $allModeFormatterModifiedDirtyFiles.Count
                    )
                }

                $nativeFormatterChangedFiles = @(
                    if ($All) {
                        $allModeNewlyDirtyFiles = @(
                            Compare-Object -ReferenceObject $preNativeQualityDiffOutput -DifferenceObject $formattedNativeQualityFiles |
                                Where-Object { $_.SideIndicator -eq '=>' } |
                                ForEach-Object { [string]$_.InputObject }
                        )

                        $allModeNewlyDirtyFiles + $allModeFormatterModifiedDirtyFiles |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                            Sort-Object -Unique
                    }
                    else {
                        $formattedNativeQualityFiles
                    }
                )

                if ($nativeFormatterChangedFiles.Count -gt 0) {
                    $formattedNativeQualityText = $nativeFormatterChangedFiles -join ', '
                    throw "E_PRECOMMIT_NATIVE_QUALITY_RESTAGE_REQUIRED: Native formatter updated file(s): $formattedNativeQualityText. Stage the updated files, then rerun pre-commit validation."
                }
            }
        }
    }

    if ($runFormatOperatorSafetyCheck) {
        Write-Verbose (
            "Running format-operator safety validation: allMode={0}; scriptCount={1}; utilsTestCount={2}; githubTestCount={3}" -f
            $All.IsPresent,
            $scriptFiles.Count,
            $utilsTestFiles.Count,
            $githubTestFiles.Count
        )
        if ($All) {
            Assert-NoFormatOperatorContinuationViolations -RootPath $repoRoot -RelativeRoots @("Scripts", "Tests") -ErrorCode "E_PRECOMMIT_FORMAT_OPERATOR_BINDING" -ContextLabel "Pre-commit PowerShell format-operator safety"
        }
        else {
            $formatOperatorTargetFiles = @(
                @($scriptFiles) + @($utilsTestFiles) + @($githubTestFiles) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )
            Assert-NoFormatOperatorContinuationViolations -RootPath $repoRoot -TargetFiles $formatOperatorTargetFiles -ErrorCode "E_PRECOMMIT_FORMAT_OPERATOR_BINDING" -ContextLabel "Pre-commit PowerShell format-operator safety"
        }
    }

    if ($runWindowsLanguageChecks) {
        $windowsLanguageScriptPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1"
        if (-not (Test-Path -Path $windowsLanguageScriptPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: Windows language checker is missing at '$windowsLanguageScriptPath'."
        }

        Write-Host "Running Windows language static validation..."
        if ($All) {
            & $windowsLanguageScriptPath
        }
        else {
            & $windowsLanguageScriptPath -TargetFiles $windowsLanguageFiles -StaticOnly
        }
    }

    $requiresPesterModule = $runUtilsTests -or $runGitHubTests -or $runShellSafetySuite
    $requiresCompatibilityAnalyzerModule = $runCompatibilityGate
    $requiresLintAnalyzerModule = (-not $SkipAnalyzer) -and $runAnalyzer
    $requiresScriptAnalyzerModule = $requiresCompatibilityAnalyzerModule -or $requiresLintAnalyzerModule
    if ($requiresPesterModule -or $requiresScriptAnalyzerModule) {
        Write-Host "Running PowerShell module prerequisite validation..."
        Assert-PreCommitPowerShellModuleAvailability -RequirePester:$requiresPesterModule -RequireScriptAnalyzer:$requiresScriptAnalyzerModule
    }

    if ($runCompatibilityGate) {
        $compatibilityGatePath = Join-Path -Path $repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-CompatibilityChecks.ps1'
        if (-not (Test-Path -LiteralPath $compatibilityGatePath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: Compatibility checker is missing at '$compatibilityGatePath'."
        }

        $pwshExecutable = Get-PwshExecutableOrThrow
        $compatibilityTargetListPath = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllLines($compatibilityTargetListPath, $compatibilityTargetFiles, [System.Text.UTF8Encoding]::new($false))

            $compatibilityGateLiteral = "'{0}'" -f ([string]$compatibilityGatePath).Replace("'", "''")
            $compatibilityTargetListLiteral = "'{0}'" -f ([string]$compatibilityTargetListPath).Replace("'", "''")
            $compatibilityCommandText = (
                "& {{ `$targets = @((Get-Content -LiteralPath {0} -ErrorAction Stop) | Where-Object {{ -not [string]::IsNullOrWhiteSpace(`$_) }}); & {1} -OutputFormat json -TargetFiles `$targets }}" -f
                $compatibilityTargetListLiteral,
                $compatibilityGateLiteral
            )
            $compatibilityEncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($compatibilityCommandText))

            Write-Host ("Running cross-version compatibility gate for {0} staged target(s)..." -f $compatibilityTargetFiles.Count)
            $compatibilityOutput = @(& $pwshExecutable -NoLogo -NoProfile -EncodedCommand $compatibilityEncodedCommand 2>&1)
            $compatibilityExitCode = $LASTEXITCODE
            if ($compatibilityExitCode -ne 0) {
                $compatibilityPreview = Get-OutputPreview -OutputLines $compatibilityOutput -MaxLines 6 -FilterBlankLines -HeadTailWhenTruncated -PerLineMaxCharacters 220
                throw (
                    "E_PRECOMMIT_COMPATIBILITY_FAILED: cross-version compatibility gate failed for staged targets (targetCount={0}; outputPreview={1})." -f
                    $compatibilityTargetFiles.Count,
                    $compatibilityPreview
                )
            }
        }
        finally {
            Remove-Item -LiteralPath $compatibilityTargetListPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($runUtilsTests -or $runGitHubTests -or $runShellSafetySuite) {
        $pesterGateScriptPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
        if (-not (Test-Path -Path $pesterGateScriptPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: Pester quality gate script is missing at '$pesterGateScriptPath'."
        }

        Write-Verbose (
            "Pre-commit Pester execution diagnostics: timeoutSeconds={0}; outputVerbosity={1}; pesterGatePath={2}" -f
            $PesterTimeoutSeconds,
            $PesterOutputVerbosity,
            $pesterGateScriptPath
        )
    }

    if ($runUtilsTests) {
        foreach ($utilsTestTarget in $utilsTestTargets) {
            $resolvedUtilsTestPath = if ($All) {
                $utilsTestTarget
            }
            else {
                Join-Path -Path $repoRoot -ChildPath $utilsTestTarget
            }

            $utilsSuiteLabel = if ($All) {
                'PreCommitUtils'
            }
            else {
                'PreCommitUtils-{0}' -f [System.IO.Path]::GetFileNameWithoutExtension($utilsTestTarget)
            }

            $utilsTargetDisplay = if ($All) {
                'Tests/Utils'
            }
            else {
                $utilsTestTarget
            }

            Write-Host ("Running {0} Pester suite in isolated process..." -f $utilsTargetDisplay)
            Invoke-PesterQualityGateInIsolatedProcess -RepoRoot $repoRoot -TestPath $resolvedUtilsTestPath -SuiteLabel $utilsSuiteLabel -OutputVerbosity $PesterOutputVerbosity -TimeoutSeconds $PesterTimeoutSeconds
        }
    }

    if ($runGitHubTests) {
        Write-Host "Running Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1 Pester suite in isolated process..."
        Invoke-PesterQualityGateInIsolatedProcess -RepoRoot $repoRoot -TestPath (Join-Path -Path $repoRoot -ChildPath "Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1") -SuiteLabel "PreCommitGitHub" -OutputVerbosity $PesterOutputVerbosity -TimeoutSeconds $PesterTimeoutSeconds
    }

    if ($runShellSafetySuite) {
        Write-Host "Running Tests/Utils/ScriptSafetyConventions.Tests.ps1 Pester suite in isolated process..."
        Invoke-PesterQualityGateInIsolatedProcess -RepoRoot $repoRoot -TestPath (Join-Path -Path $repoRoot -ChildPath "Tests/Utils/ScriptSafetyConventions.Tests.ps1") -SuiteLabel "PreCommitScriptSafety" -OutputVerbosity $PesterOutputVerbosity -TimeoutSeconds $PesterTimeoutSeconds
    }

    if (-not $SkipAnalyzer -and $runAnalyzer) {
        $minimumScriptAnalyzerVersion = [version]"1.21.0"
        $scriptAnalyzerCommand = Get-CommandWithOptionalModuleImport -CommandName "Invoke-ScriptAnalyzer" -ModuleName "PSScriptAnalyzer" -MinimumVersion $minimumScriptAnalyzerVersion
        if ($null -eq $scriptAnalyzerCommand) {
            $installedScriptAnalyzerVersions = Get-AvailableModuleVersionsText -ModuleName "PSScriptAnalyzer"
            throw (
                "E_CONFIG_ERROR: Invoke-ScriptAnalyzer from PSScriptAnalyzer {0} or newer is required but unavailable. Installed versions: {1}. Run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules PSScriptAnalyzer' (or install manually with 'Install-Module PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -MinimumVersion {0} -Force') or re-run with -SkipAnalyzer to skip only the ScriptAnalyzer lint step; the cross-version compatibility gate still requires PSScriptAnalyzer when PowerShell targets are present." -f
                $minimumScriptAnalyzerVersion,
                $installedScriptAnalyzerVersions
            )
        }

        $analyzerRecurse = $All
        Write-Host ("Running ScriptAnalyzer for {0} target(s)..." -f $analyzerTargets.Count)
        Write-Verbose ("ScriptAnalyzer execution diagnostics: recurse={0}; targets={1}" -f $analyzerRecurse, $analyzerTargetsText)
        $analysisResult = New-Object System.Collections.Generic.List[object]
        foreach ($analyzerTarget in $analyzerTargets) {
            $analysisRaw = Invoke-ScriptAnalyzer -Path $analyzerTarget -Settings ".psscriptanalyzer.psd1" -Recurse:$analyzerRecurse -ErrorAction Stop
            if ($null -eq $analysisRaw) {
                continue
            }

            foreach ($analysisIssue in @($analysisRaw)) {
                $analysisResult.Add($analysisIssue) | Out-Null
            }
        }

        $analysisCount = $analysisResult.Count
        if ($analysisCount -gt 0) {
            $firstIssue = $analysisResult[0]
            throw "E_LINT_FAILURE: ScriptAnalyzer reported $analysisCount issue(s). First issue: $($firstIssue.RuleName) at $($firstIssue.ScriptName):$($firstIssue.Line)"
        }
    }

    if ($runLlmHarnessValidation) {
        $llmValidatorPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Test-LlmHarness.ps1"
        if (-not (Test-Path -Path $llmValidatorPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: LLM harness validator is missing at '$llmValidatorPath'."
        }

        & $llmValidatorPath -RootPath $repoRoot
    }

    Write-Host "Pre-commit validation passed."
}
finally {
    Pop-Location
}
