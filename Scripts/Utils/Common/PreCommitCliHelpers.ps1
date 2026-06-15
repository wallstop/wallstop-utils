# PreCommitCliHelpers.ps1
#
# Shared pre-commit CLI pin validation.

$preCommitCompatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'CompatibilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $preCommitCompatibilityHelpersPath -PathType Leaf)) {
    throw "E_VALIDATION_PRECOMMIT_COMPATIBILITY_HELPER_MISSING: Compatibility helper file not found at '$preCommitCompatibilityHelpersPath'."
}

. $preCommitCompatibilityHelpersPath

$preCommitStrictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'StrictModeHelpers.ps1'
if (-not (Test-Path -LiteralPath $preCommitStrictModeHelpersPath -PathType Leaf)) {
    throw "E_VALIDATION_PRECOMMIT_STRICT_MODE_HELPER_MISSING: Strict mode helper file not found at '$preCommitStrictModeHelpersPath'."
}

. $preCommitStrictModeHelpersPath

$preCommitQualityToolingHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'QualityToolingHelpers.ps1'
if (-not (Test-Path -LiteralPath $preCommitQualityToolingHelpersPath -PathType Leaf)) {
    throw "E_VALIDATION_PRECOMMIT_QUALITY_TOOLING_HELPER_MISSING: Quality tooling helper file not found at '$preCommitQualityToolingHelpersPath'."
}

. $preCommitQualityToolingHelpersPath

$script:PreCommitCliToolManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "../Quality/precommit-cli-tools.json"
$script:PreCommitCliToolRootName = ".tools/precommit-cli"
$script:PreCommitCliToolDownloadTimeoutSeconds = 300
$script:PreCommitCliToolLockTimeoutSeconds = 60
$script:PreCommitCliToolLockRetryMilliseconds = 200

if (-not [string]::IsNullOrWhiteSpace($env:WALLSTOP_PRECOMMIT_CLI_TOOL_DOWNLOAD_TIMEOUT_SECONDS)) {
    if ($env:WALLSTOP_PRECOMMIT_CLI_TOOL_DOWNLOAD_TIMEOUT_SECONDS -notmatch '^[0-9]+$' -or [int]$env:WALLSTOP_PRECOMMIT_CLI_TOOL_DOWNLOAD_TIMEOUT_SECONDS -lt 30) {
        throw "E_VALIDATION_PRECOMMIT_CLI_TOOL_TIMEOUT_CONFIG: WALLSTOP_PRECOMMIT_CLI_TOOL_DOWNLOAD_TIMEOUT_SECONDS must be an integer >= 30 seconds (received '$env:WALLSTOP_PRECOMMIT_CLI_TOOL_DOWNLOAD_TIMEOUT_SECONDS')."
    }

    $script:PreCommitCliToolDownloadTimeoutSeconds = [int]$env:WALLSTOP_PRECOMMIT_CLI_TOOL_DOWNLOAD_TIMEOUT_SECONDS
}

$script:PreCommitCliToolContext = New-QualityToolingContext `
    -DiagnosticPrefix "VALIDATION_PRECOMMIT_CLI_TOOL" `
    -TargetDiagnosticPrefix "VALIDATION_PRECOMMIT_CLI" `
    -LogPrefix "[precommit-cli-tool]" `
    -ManifestPath $script:PreCommitCliToolManifestPath `
    -ToolRootName $script:PreCommitCliToolRootName `
    -DownloadTimeoutSeconds $script:PreCommitCliToolDownloadTimeoutSeconds `
    -ToolSuiteLabel "pre-commit CLI" `
    -ManifestContextLabel "pre-commit CLI tool manifest" `
    -MarkerContextLabel "pre-commit CLI tool asset marker"

function Get-RequiredPreCommitVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $requirementsPath = Join-Path -Path $RepositoryRoot -ChildPath "requirements.txt"
    if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
        throw "E_VALIDATION_PRECOMMIT_REQUIREMENTS_MISSING: requirements.txt is required to pin the pre-commit CLI but was not found at '$requirementsPath'."
    }

    $requirementsContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $requirementsPath -ErrorAction Stop).Path, [System.Text.Encoding]::UTF8)
    $match = [System.Text.RegularExpressions.Regex]::Match($requirementsContent, '(?m)^\s*pre-commit==(?<version>[0-9]+(?:\.[0-9]+){1,3})\s*(?:#.*)?$')
    if (-not $match.Success) {
        throw "E_VALIDATION_PRECOMMIT_REQUIREMENTS_INVALID: requirements.txt must contain an exact 'pre-commit==<version>' pin."
    }

    return $match.Groups["version"].Value
}

function Get-PreCommitBootstrapVersionGuidance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string]$FallbackVersion = "<pinned-version-from-requirements.txt>"
    )

    try {
        $requiredVersion = Get-RequiredPreCommitVersion -RepositoryRoot $RepositoryRoot
        if (-not [string]::IsNullOrWhiteSpace($requiredVersion)) {
            return [pscustomobject]@{
                Version                = $requiredVersion
                IsFallback             = $false
                RequirementsDiagnostic = ""
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Version                = $FallbackVersion
            IsFallback             = $true
            RequirementsDiagnostic = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Version                = $FallbackVersion
        IsFallback             = $true
        RequirementsDiagnostic = "Get-RequiredPreCommitVersion returned an empty version."
    }
}

function Invoke-PreCommitVersionProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $PreCommitExecutable
    $processStartInfo.WorkingDirectory = $RepositoryRoot
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true

    Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList @("--version")
    $preCommitEnvironment = Get-PreCommitManagedEnvironment -RepositoryRoot $RepositoryRoot
    foreach ($environmentKey in @($preCommitEnvironment.Keys)) {
        Set-PortableProcessEnvironmentVariable -StartInfo $processStartInfo -Name ([string]$environmentKey) -Value ([string]$preCommitEnvironment[$environmentKey])
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
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Failed to kill timed-out pre-commit version probe: $($_.Exception.Message)"
            }

            throw "E_VALIDATION_PRECOMMIT_VERSION_TIMEOUT: pre-commit --version exceeded ${TimeoutSeconds}s (executable='$PreCommitExecutable')."
        }

        $stdoutCapture = Read-PreCommitProcessOutputTaskBounded -Task $stdoutTask -StreamName stdout
        $stderrCapture = Read-PreCommitProcessOutputTaskBounded -Task $stderrTask -StreamName stderr
        $captureDiagnostics = Join-PreCommitCaptureDiagnostics -Diagnostics @($stdoutCapture.Diagnostic, $stderrCapture.Diagnostic)
        $stderrText = [string]$stderrCapture.Text
        if (-not [string]::IsNullOrWhiteSpace($captureDiagnostics)) {
            $stderrText = (@($stderrText, $captureDiagnostics) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutCapture.Text
            Stderr   = $stderrText
        }
    }
    finally {
        $process.Dispose()
    }
}

function Assert-PreCommitCliVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    $expectedVersion = Get-RequiredPreCommitVersion -RepositoryRoot $RepositoryRoot
    $versionResult = Invoke-PreCommitVersionProbe -PreCommitExecutable $PreCommitExecutable -RepositoryRoot $RepositoryRoot -TimeoutSeconds $TimeoutSeconds
    $combinedOutput = @([string]$versionResult.Stdout, [string]$versionResult.Stderr) -join [Environment]::NewLine
    if ($versionResult.ExitCode -ne 0) {
        throw "E_VALIDATION_PRECOMMIT_VERSION_FAILED: pre-commit --version failed (exitCode=$($versionResult.ExitCode); executable='$PreCommitExecutable'; output=$combinedOutput)."
    }

    $match = [System.Text.RegularExpressions.Regex]::Match($combinedOutput, '(?m)\bpre-commit\s+(?<version>[0-9]+(?:\.[0-9]+){1,3})\b')
    if (-not $match.Success) {
        throw "E_VALIDATION_PRECOMMIT_VERSION_PARSE_FAILED: unable to parse pre-commit version from output (executable='$PreCommitExecutable'; output=$combinedOutput)."
    }

    $actualVersion = $match.Groups["version"].Value
    if ($actualVersion -ne $expectedVersion) {
        throw "E_VALIDATION_PRECOMMIT_VERSION_MISMATCH: pre-commit CLI version mismatch (expected=$expectedVersion; actual=$actualVersion; executable='$PreCommitExecutable'). Install the pinned CLI with 'pipx install --force pre-commit==$expectedVersion' or a dedicated venv (python3 -m venv ~/.local/venvs/pre-commit; ~/.local/venvs/pre-commit/bin/pip install --requirement requirements.txt; ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit)."
    }

    return [pscustomobject]@{
        ExpectedVersion = $expectedVersion
        ActualVersion   = $actualVersion
        Executable      = $PreCommitExecutable
    }
}

function Get-PreCommitCommandExecutablePath {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$CommandInfo = $null
    )

    if ($null -eq $CommandInfo) {
        return ""
    }

    if ($null -ne $CommandInfo.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$CommandInfo.Source)) {
        return [string]$CommandInfo.Source
    }

    if ($null -ne $CommandInfo.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$CommandInfo.Path)) {
        return [string]$CommandInfo.Path
    }

    return ""
}

function Read-PreCommitProcessOutputTaskBounded {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Task,

        [Parameter(Mandatory = $true)]
        [string]$StreamName,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 30000)]
        [int]$TimeoutMilliseconds = 2000
    )

    try {
        if (-not $Task.Wait($TimeoutMilliseconds)) {
            return [pscustomobject]@{
                Text       = ""
                Diagnostic = "E_VALIDATION_PRECOMMIT_CAPTURE_TIMEOUT: stream=$StreamName timed out after ${TimeoutMilliseconds}ms while draining subprocess output."
                TimedOut   = $true
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Text       = ""
            Diagnostic = "E_VALIDATION_PRECOMMIT_CAPTURE_FAILED: stream=$StreamName failed while draining subprocess output. $($_.Exception.Message)"
            TimedOut   = $false
        }
    }

    try {
        return [pscustomobject]@{
            Text       = [string]$Task.GetAwaiter().GetResult()
            Diagnostic = ""
            TimedOut   = $false
        }
    }
    catch {
        return [pscustomobject]@{
            Text       = ""
            Diagnostic = "E_VALIDATION_PRECOMMIT_CAPTURE_FAILED: stream=$StreamName failed while reading subprocess output. $($_.Exception.Message)"
            TimedOut   = $false
        }
    }
}

function Join-PreCommitCaptureDiagnostics {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Diagnostics = @()
    )

    return (@($Diagnostics) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
}

function Read-PreCommitCliToolManifest {
    return Read-QualityToolingManifest -Context $script:PreCommitCliToolContext
}

function Install-PreCommitCliUvToolAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AssetSpec,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    Install-QualityToolingToolAsset `
        -Context $script:PreCommitCliToolContext `
        -InstallRoot $InstallRoot `
        -AssetSpec $AssetSpec `
        -RepositoryRoot $RepositoryRoot `
        -DownloadCommand { param($AssetSpec, $DownloadPath) Invoke-QualityToolingDownload -Context $script:PreCommitCliToolContext -AssetSpec $AssetSpec -DownloadPath $DownloadPath }
}

function Resolve-PreCommitCliUvExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $manifest = Read-PreCommitCliToolManifest
    return Resolve-QualityToolingToolExecutable `
        -Context $script:PreCommitCliToolContext `
        -Manifest $manifest `
        -ToolName "uv" `
        -RepositoryRoot $RepositoryRoot `
        -LockTimeoutSeconds $script:PreCommitCliToolLockTimeoutSeconds `
        -LockRetryMilliseconds $script:PreCommitCliToolLockRetryMilliseconds `
        -InstallCommand { param($InstallRoot, $AssetSpec, $RepositoryRoot) Install-PreCommitCliUvToolAsset -InstallRoot $InstallRoot -AssetSpec $AssetSpec -RepositoryRoot $RepositoryRoot }
}

function Get-PreCommitManagedUvState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $uvStateRoot = Join-Path -Path $RepositoryRoot -ChildPath ".tools/precommit-cli/uv-state"
    $uvCacheDir = Join-Path -Path $uvStateRoot -ChildPath "cache"
    $uvToolDir = Join-Path -Path $uvStateRoot -ChildPath "tools"
    $uvToolBinDir = Join-Path -Path $uvStateRoot -ChildPath "bin"
    [System.IO.Directory]::CreateDirectory($uvCacheDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($uvToolDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($uvToolBinDir) | Out-Null

    $preCommitExecutableName = if (Test-IsWindowsPlatform) {
        "pre-commit.exe"
    }
    else {
        "pre-commit"
    }

    return [pscustomobject]@{
        CacheDir            = $uvCacheDir
        ToolDir             = $uvToolDir
        ToolBinDir          = $uvToolBinDir
        PreCommitExecutable = Join-Path -Path $uvToolBinDir -ChildPath $preCommitExecutableName
        Environment         = @{
            UV_CACHE_DIR     = $uvCacheDir
            UV_TOOL_DIR      = $uvToolDir
            UV_TOOL_BIN_DIR  = $uvToolBinDir
            UV_NO_MODIFY_PATH = "1"
        }
    }
}

function Get-PreCommitManagedPreCommitHome {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [switch]$EnsureDirectory
    )

    $preCommitHome = Join-Path -Path $RepositoryRoot -ChildPath ".tools/precommit-cli/pre-commit-home"
    if ($EnsureDirectory) {
        [System.IO.Directory]::CreateDirectory($preCommitHome) | Out-Null
    }

    return $preCommitHome
}

function Get-PreCommitManagedEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    return @{
        PRE_COMMIT_HOME = Get-PreCommitManagedPreCommitHome -RepositoryRoot $RepositoryRoot -EnsureDirectory
    }
}

function Get-PreCommitFailureOutputPreview {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Output = "",

        [Parameter(Mandatory = $false)]
        [ValidateRange(120, 2000)]
        [int]$MaxLength = 400
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return "<empty>"
    }

    $collapsed = ($Output -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($collapsed)) {
        return "<empty>"
    }

    if ($collapsed.Length -le $MaxLength) {
        return $collapsed
    }

    return ("{0}..." -f $collapsed.Substring(0, $MaxLength))
}

function Join-PreCommitCommandOutput {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Stdout = "",

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Stderr = ""
    )

    return (@([string]$Stdout, [string]$Stderr) -join [Environment]::NewLine)
}

function Get-PreCommitPyzSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $hashesByVersion = @{
        "4.6.0" = "ea8a0c84902e48c1875558f2f362ed8476773aa5fc8c16c5d8f2acc2a2830a65"
    }

    if ($hashesByVersion.ContainsKey($Version)) {
        return [string]$hashesByVersion[$Version]
    }

    return ""
}

function Get-PreCommitRemainingTimeoutSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc
    )

    $remainingSeconds = [int][math]::Ceiling(($DeadlineUtc - [datetime]::UtcNow).TotalSeconds)
    if ($remainingSeconds -lt 0) {
        return 0
    }

    return $remainingSeconds
}

function Invoke-PreCommitExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1800)]
        [int]$TimeoutSeconds = 120,

        [Parameter(Mandatory = $false)]
        [string]$ContextLabel = "external command",

        [Parameter(Mandatory = $false)]
        [hashtable]$Environment = @{}
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $Executable
    $processStartInfo.WorkingDirectory = $RepositoryRoot
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList $Arguments
    foreach ($environmentKey in @($Environment.Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$environmentKey)) {
            continue
        }

        Set-PortableProcessEnvironmentVariable -StartInfo $processStartInfo -Name ([string]$environmentKey) -Value ([string]$Environment[$environmentKey])
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    try {
        try {
            [void]$process.Start()
        }
        catch {
            return [pscustomobject]@{
                ExitCode    = 1
                Stdout      = ""
                Stderr      = "E_VALIDATION_PRECOMMIT_COMMAND_START_FAILED: failed to start ${ContextLabel} executable '$Executable'. $($_.Exception.Message)"
                TimedOut    = $false
                StartFailed = $true
            }
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Failed to kill timed-out ${ContextLabel}: $($_.Exception.Message)"
            }

            $stdoutCapture = Read-PreCommitProcessOutputTaskBounded -Task $stdoutTask -StreamName stdout
            $stderrCapture = Read-PreCommitProcessOutputTaskBounded -Task $stderrTask -StreamName stderr
            $captureDiagnostics = Join-PreCommitCaptureDiagnostics -Diagnostics @($stdoutCapture.Diagnostic, $stderrCapture.Diagnostic)
            $timeoutStderr = "E_VALIDATION_PRECOMMIT_COMMAND_TIMEOUT: ${ContextLabel} exceeded ${TimeoutSeconds}s (executable='$Executable')."
            if (-not [string]::IsNullOrWhiteSpace($stderrCapture.Text)) {
                $timeoutStderr = "${timeoutStderr}`n$($stderrCapture.Text)"
            }
            if (-not [string]::IsNullOrWhiteSpace($captureDiagnostics)) {
                $timeoutStderr = "${timeoutStderr}`n${captureDiagnostics}"
            }

            return [pscustomobject]@{
                ExitCode    = 124
                Stdout      = $stdoutCapture.Text
                Stderr      = $timeoutStderr
                TimedOut    = $true
                StartFailed = $false
            }
        }

        $normalStdoutCapture = Read-PreCommitProcessOutputTaskBounded -Task $stdoutTask -StreamName stdout
        $normalStderrCapture = Read-PreCommitProcessOutputTaskBounded -Task $stderrTask -StreamName stderr
        $normalCaptureDiagnostics = Join-PreCommitCaptureDiagnostics -Diagnostics @($normalStdoutCapture.Diagnostic, $normalStderrCapture.Diagnostic)
        $normalStderr = [string]$normalStderrCapture.Text
        if (-not [string]::IsNullOrWhiteSpace($normalCaptureDiagnostics)) {
            $normalStderr = (@($normalStderr, $normalCaptureDiagnostics) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }

        return [pscustomobject]@{
            ExitCode    = [int]$process.ExitCode
            Stdout      = $normalStdoutCapture.Text
            Stderr      = $normalStderr
            TimedOut    = $false
            StartFailed = $false
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-PreCommitCandidateExecutablePaths {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$RepositoryRoot = ""
    )

    $candidatePaths = New-Object System.Collections.Generic.List[string]
    $pathComparer = if (Test-IsWindowsPlatform) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)

    $preCommitCommands = @(Get-Command -Name "pre-commit" -All -ErrorAction SilentlyContinue)
    foreach ($preCommitCommand in $preCommitCommands) {
        $candidatePath = Get-PreCommitCommandExecutablePath -CommandInfo $preCommitCommand
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }

        if ($seenPaths.Add($candidatePath)) {
            $candidatePaths.Add($candidatePath) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $managedPreCommitExecutableName = if (Test-IsWindowsPlatform) {
            "pre-commit.exe"
        }
        else {
            "pre-commit"
        }
        $managedUvPreCommitCandidate = Join-Path -Path (Join-Path -Path $RepositoryRoot -ChildPath ".tools/precommit-cli/uv-state/bin") -ChildPath $managedPreCommitExecutableName
        if ($seenPaths.Add($managedUvPreCommitCandidate)) {
            $candidatePaths.Add($managedUvPreCommitCandidate) | Out-Null
        }
    }

    $homePathVariable = Get-Variable -Name "HOME" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $homePathVariable -and -not [string]::IsNullOrWhiteSpace([string]$homePathVariable)) {
        $homePath = [string]$homePathVariable
        $preCommitExecutableName = if (Test-IsWindowsPlatform) {
            "pre-commit.exe"
        }
        else {
            "pre-commit"
        }

        $venvFallbackCandidate = if (Test-IsWindowsPlatform) {
            Join-Path -Path $homePath -ChildPath ".local/venvs/pre-commit/Scripts/pre-commit.exe"
        }
        else {
            Join-Path -Path $homePath -ChildPath ".local/venvs/pre-commit/bin/pre-commit"
        }

        $fallbackCandidates = @(
            (Join-Path -Path $homePath -ChildPath (Join-Path -Path ".local/bin" -ChildPath $preCommitExecutableName)),
            $venvFallbackCandidate
        )

        if (-not (Test-IsWindowsPlatform)) {
            $pyzRoot = Join-Path -Path $homePath -ChildPath ".local/share/wallstop/pre-commit"
            if (Test-Path -LiteralPath $pyzRoot -PathType Container) {
                $pyzCandidates = @(
                    foreach ($pyzCandidate in @(Get-ChildItem -LiteralPath $pyzRoot -Filter "pre-commit-*.pyz" -File -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)) {
                        $versionMatch = [System.Text.RegularExpressions.Regex]::Match($pyzCandidate.Name, '^pre-commit-(?<version>[0-9]+(?:\.[0-9]+){1,3})\.pyz$')
                        if (-not $versionMatch.Success) {
                            continue
                        }

                        $expectedPyzHash = Get-PreCommitPyzSha256 -Version $versionMatch.Groups["version"].Value
                        if ([string]::IsNullOrWhiteSpace($expectedPyzHash)) {
                            continue
                        }

                        $actualPyzHash = (Get-FileHash -LiteralPath $pyzCandidate.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                        if ($actualPyzHash -eq $expectedPyzHash) {
                            $pyzCandidate.FullName
                        }
                    }
                )
                $fallbackCandidates += $pyzCandidates
            }
        }

        foreach ($fallbackCandidate in $fallbackCandidates) {
            if ([string]::IsNullOrWhiteSpace([string]$fallbackCandidate)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $fallbackCandidate -PathType Leaf)) {
                continue
            }

            if ($seenPaths.Add($fallbackCandidate)) {
                $candidatePaths.Add($fallbackCandidate) | Out-Null
            }
        }
    }

    return @($candidatePaths.ToArray())
}

function Install-PreCommitPyzFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc
    )

    if (Test-IsWindowsPlatform) {
        return [pscustomobject]@{
            Succeeded          = $false
            Strategy           = "pyz"
            RepairedExecutable = ""
            Diagnostics        = @("pyz strategy skipped on Windows because direct .pyz execution is not portable under the current process launcher.")
        }
    }

    $expectedSha256 = Get-PreCommitPyzSha256 -Version $ExpectedVersion
    if ([string]::IsNullOrWhiteSpace($expectedSha256)) {
        return [pscustomobject]@{
            Succeeded          = $false
            Strategy           = "pyz"
            RepairedExecutable = ""
            Diagnostics        = @("pyz strategy skipped because no pinned SHA256 is recorded for pre-commit $ExpectedVersion.")
        }
    }

    $python3Command = Get-Command -Name "python3" -ErrorAction SilentlyContinue
    $python3Path = Get-PreCommitCommandExecutablePath -CommandInfo $python3Command
    if ([string]::IsNullOrWhiteSpace($python3Path)) {
        return [pscustomobject]@{
            Succeeded          = $false
            Strategy           = "pyz"
            RepairedExecutable = ""
            Diagnostics        = @("pyz strategy skipped because python3 is unavailable on PATH.")
        }
    }

    $homePathVariable = Get-Variable -Name "HOME" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $homePathVariable -or [string]::IsNullOrWhiteSpace([string]$homePathVariable)) {
        return [pscustomobject]@{
            Succeeded          = $false
            Strategy           = "pyz"
            RepairedExecutable = ""
            Diagnostics        = @("pyz strategy skipped because HOME is unavailable.")
        }
    }

    $homePath = [string]$homePathVariable
    $pyzRoot = Join-Path -Path $homePath -ChildPath ".local/share/wallstop/pre-commit"
    [System.IO.Directory]::CreateDirectory($pyzRoot) | Out-Null
    $pyzPath = Join-Path -Path $pyzRoot -ChildPath "pre-commit-$ExpectedVersion.pyz"

    $needsDownload = $true
    if (Test-Path -LiteralPath $pyzPath -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $pyzPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $needsDownload = ($existingHash -ne $expectedSha256)
    }

    if ($needsDownload) {
        $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $DeadlineUtc
        if ($remainingSeconds -le 0) {
            return [pscustomobject]@{
                Succeeded          = $false
                Strategy           = "pyz"
                RepairedExecutable = ""
                Diagnostics        = @("pyz strategy skipped because auto-repair timeout expired before download.")
            }
        }

        $downloadTimeoutSeconds = [Math]::Min($remainingSeconds, 120)
        $downloadUrl = "https://github.com/pre-commit/pre-commit/releases/download/v$ExpectedVersion/pre-commit-$ExpectedVersion.pyz"
        $temporaryDownloadPath = Join-Path -Path $pyzRoot -ChildPath ("pre-commit-$ExpectedVersion.{0}.tmp" -f [guid]::NewGuid().ToString("N"))
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $temporaryDownloadPath -UseBasicParsing -TimeoutSec $downloadTimeoutSeconds -ErrorAction Stop
            $actualSha256 = (Get-FileHash -LiteralPath $temporaryDownloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualSha256 -ne $expectedSha256) {
                return [pscustomobject]@{
                    Succeeded          = $false
                    Strategy           = "pyz"
                    RepairedExecutable = ""
                    Diagnostics        = @("pyz strategy failed SHA256 verification for pre-commit $ExpectedVersion (expected=$expectedSha256; actual=$actualSha256).")
                }
            }

            Move-Item -LiteralPath $temporaryDownloadPath -Destination $pyzPath -Force
        }
        catch {
            return [pscustomobject]@{
                Succeeded          = $false
                Strategy           = "pyz"
                RepairedExecutable = ""
                Diagnostics        = @("pyz strategy failed to download pre-commit $ExpectedVersion. $($_.Exception.Message)")
            }
        }
        finally {
            Remove-Item -LiteralPath $temporaryDownloadPath -Force -ErrorAction SilentlyContinue
        }
    }

    $chmodCommand = Get-Command -Name "chmod" -ErrorAction SilentlyContinue
    $chmodPath = Get-PreCommitCommandExecutablePath -CommandInfo $chmodCommand
    if (-not [string]::IsNullOrWhiteSpace($chmodPath)) {
        [void](Invoke-PreCommitExternalCommand -Executable $chmodPath -Arguments @("+x", $pyzPath) -RepositoryRoot $RepositoryRoot -TimeoutSeconds 10 -ContextLabel "chmod pre-commit pyz")
    }

    $remainingProbeSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $DeadlineUtc
    if ($remainingProbeSeconds -le 0) {
        return [pscustomobject]@{
            Succeeded          = $false
            Strategy           = "pyz"
            RepairedExecutable = ""
            Diagnostics        = @("pyz strategy installed pre-commit $ExpectedVersion but auto-repair timeout expired before version probe.")
        }
    }

    $probeTimeoutSeconds = [Math]::Min($remainingProbeSeconds, 30)
    $probeResult = Invoke-PreCommitExternalCommand -Executable $pyzPath -Arguments @("--version") -RepositoryRoot $RepositoryRoot -TimeoutSeconds $probeTimeoutSeconds -ContextLabel "pre-commit pyz version probe"
    if ($probeResult.ExitCode -eq 0 -and (Join-PreCommitCommandOutput -Stdout $probeResult.Stdout -Stderr $probeResult.Stderr) -match "\bpre-commit\s+$([regex]::Escape($ExpectedVersion))\b") {
        return [pscustomobject]@{
            Succeeded          = $true
            Strategy           = "pyz"
            RepairedExecutable = $pyzPath
            Diagnostics        = @()
        }
    }

    return [pscustomobject]@{
        Succeeded          = $false
        Strategy           = "pyz"
        RepairedExecutable = ""
        Diagnostics        = @("pyz strategy installed pre-commit $ExpectedVersion but version probe failed (exitCode=$([int]$probeResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (Join-PreCommitCommandOutput -Stdout $probeResult.Stdout -Stderr $probeResult.Stderr))).")
    }
}

function Get-PreCommitVersionProbeClassification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    try {
        $versionResult = Invoke-PreCommitVersionProbe -PreCommitExecutable $PreCommitExecutable -RepositoryRoot $RepositoryRoot -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        return [pscustomobject]@{
            Status        = if ($_.Exception.Message -match "\bE_VALIDATION_PRECOMMIT_VERSION_TIMEOUT\b") { "timeout" } else { "probe_failed" }
            ActualVersion = ""
            Diagnostic    = [string]$_.Exception.Message
        }
    }

    $combinedOutput = @([string]$versionResult.Stdout, [string]$versionResult.Stderr) -join [Environment]::NewLine
    if ($versionResult.ExitCode -ne 0) {
        return [pscustomobject]@{
            Status        = "invoke_failed"
            ActualVersion = ""
            Diagnostic    = "E_VALIDATION_PRECOMMIT_VERSION_FAILED: pre-commit --version failed (exitCode=$($versionResult.ExitCode); executable='$PreCommitExecutable'; output=$(Get-PreCommitFailureOutputPreview -Output $combinedOutput))."
        }
    }

    $versionMatch = [System.Text.RegularExpressions.Regex]::Match($combinedOutput, '(?m)\bpre-commit\s+(?<version>[0-9]+(?:\.[0-9]+){1,3})\b')
    if (-not $versionMatch.Success) {
        return [pscustomobject]@{
            Status        = "parse_failed"
            ActualVersion = ""
            Diagnostic    = "E_VALIDATION_PRECOMMIT_VERSION_PARSE_FAILED: unable to parse pre-commit version from output (executable='$PreCommitExecutable'; output=$(Get-PreCommitFailureOutputPreview -Output $combinedOutput))."
        }
    }

    $actualVersion = $versionMatch.Groups["version"].Value
    if ($actualVersion -ne $ExpectedVersion) {
        return [pscustomobject]@{
            Status        = "mismatch"
            ActualVersion = $actualVersion
            Diagnostic    = "E_VALIDATION_PRECOMMIT_VERSION_MISMATCH: pre-commit CLI version mismatch (expected=$ExpectedVersion; actual=$actualVersion; executable='$PreCommitExecutable')."
        }
    }

    return [pscustomobject]@{
        Status        = "ok"
        ActualVersion = $actualVersion
        Diagnostic    = ""
    }
}

function Resolve-PreCommitVerifiedRepairCandidate {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CandidatePaths,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc,

        [Parameter(Mandatory = $true)]
        [string]$StrategyLabel,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Diagnostics
    )

    $pathComparer = if (Test-IsWindowsPlatform) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }
    $seenCandidates = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $existingCandidateCount = 0

    foreach ($candidatePath in @($CandidatePaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidatePath)) {
            continue
        }

        $candidatePath = [string]$candidatePath
        if (-not $seenCandidates.Add($candidatePath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            continue
        }

        $existingCandidateCount++
        $remainingProbeSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $DeadlineUtc
        if ($remainingProbeSeconds -le 0) {
            $Diagnostics.Add("${StrategyLabel} strategy produced candidate '$candidatePath' but auto-repair timeout expired before version probe.") | Out-Null
            return ""
        }

        $probeTimeoutSeconds = [Math]::Min($remainingProbeSeconds, 30)
        $probeResult = Get-PreCommitVersionProbeClassification -PreCommitExecutable $candidatePath -RepositoryRoot $RepositoryRoot -ExpectedVersion $ExpectedVersion -TimeoutSeconds $probeTimeoutSeconds
        if ($probeResult.Status -eq "ok") {
            return $candidatePath
        }

        $Diagnostics.Add("${StrategyLabel} strategy produced candidate '$candidatePath' but version probe did not pass. $($probeResult.Diagnostic)") | Out-Null
    }

    if ($existingCandidateCount -eq 0) {
        $candidateText = @($CandidatePaths) -join " "
        $candidatePreview = Get-PreCommitFailureOutputPreview -Output $candidateText
        $Diagnostics.Add("${StrategyLabel} strategy completed but no expected pre-commit executable candidate was found. candidates=$candidatePreview") | Out-Null
    }

    return ""
}

function Invoke-PreCommitCliAutoRepair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory = $false)]
        [ValidateRange(30, 1800)]
        [int]$TimeoutSeconds = 240
    )

    $repairDeadlineUtc = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $repairDiagnostics = New-Object System.Collections.Generic.List[string]
    $uvCandidates = New-Object System.Collections.Generic.List[object]

    $uvCommand = Get-Command -Name "uv" -ErrorAction SilentlyContinue
    $uvCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $uvCommand
    if (-not [string]::IsNullOrWhiteSpace($uvCommandPath)) {
        $uvCandidates.Add([pscustomobject]@{
                Label = "ambient uv"
                Path  = $uvCommandPath
            }) | Out-Null
    }

    $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
    if ($remainingSeconds -gt 0) {
        try {
            $managedUvCommandPath = Resolve-PreCommitCliUvExecutable -RepositoryRoot $RepositoryRoot
            $hasManagedUvCandidate = $false
            foreach ($uvCandidate in $uvCandidates) {
                if ([string]::Equals([string]$uvCandidate.Path, $managedUvCommandPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasManagedUvCandidate = $true
                    break
                }
            }

            if (-not $hasManagedUvCandidate -and -not [string]::IsNullOrWhiteSpace($managedUvCommandPath)) {
                $uvCandidates.Add([pscustomobject]@{
                        Label = "repo-managed uv"
                        Path  = $managedUvCommandPath
                    }) | Out-Null
            }
        }
        catch {
            $repairDiagnostics.Add("repo-managed uv strategy unavailable. $($_.Exception.Message)") | Out-Null
        }
    }

    foreach ($uvCandidate in $uvCandidates) {
        $uvCommandPath = [string]$uvCandidate.Path
        $uvCandidateLabel = [string]$uvCandidate.Label
        $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
        if ($remainingSeconds -gt 0) {
            $uvTimeoutSeconds = [Math]::Min($remainingSeconds, 180)
            $uvState = Get-PreCommitManagedUvState -RepositoryRoot $RepositoryRoot
            $uvResult = Invoke-PreCommitExternalCommand `
                -Executable $uvCommandPath `
                -Arguments @("tool", "install", "--force", "pre-commit==$ExpectedVersion") `
                -RepositoryRoot $RepositoryRoot `
                -TimeoutSeconds $uvTimeoutSeconds `
                -ContextLabel "uv tool install pre-commit==$ExpectedVersion" `
                -Environment $uvState.Environment
            $verifiedUvExecutable = ""
            if ($uvResult.ExitCode -eq 0) {
                $verifiedUvExecutable = Resolve-PreCommitVerifiedRepairCandidate `
                    -CandidatePaths @($uvState.PreCommitExecutable) `
                    -RepositoryRoot $RepositoryRoot `
                    -ExpectedVersion $ExpectedVersion `
                    -DeadlineUtc $repairDeadlineUtc `
                    -StrategyLabel $uvCandidateLabel `
                    -Diagnostics $repairDiagnostics
            }

            if (-not [string]::IsNullOrWhiteSpace($verifiedUvExecutable)) {
                return [pscustomobject]@{
                    Succeeded          = $true
                    Strategy           = "uv-tool-install"
                    RepairedExecutable = $verifiedUvExecutable
                    Diagnostics        = @()
                }
            }

            if ($uvResult.ExitCode -ne 0) {
                $repairDiagnostics.Add("${uvCandidateLabel} strategy failed (exitCode=$([int]$uvResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (Join-PreCommitCommandOutput -Stdout $uvResult.Stdout -Stderr $uvResult.Stderr))).") | Out-Null
            }
        }
    }

    $pipxCommand = Get-Command -Name "pipx" -ErrorAction SilentlyContinue
    $pipxCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $pipxCommand
    if (-not [string]::IsNullOrWhiteSpace($pipxCommandPath)) {
        $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
        if ($remainingSeconds -gt 0) {
            $pipxTimeoutSeconds = [Math]::Min($remainingSeconds, 180)
            $pipxResult = Invoke-PreCommitExternalCommand -Executable $pipxCommandPath -Arguments @("install", "--force", "pre-commit==$ExpectedVersion") -RepositoryRoot $RepositoryRoot -TimeoutSeconds $pipxTimeoutSeconds -ContextLabel "pipx install pre-commit==$ExpectedVersion"
            if ($pipxResult.ExitCode -eq 0) {
                $verifiedPipxExecutable = Resolve-PreCommitVerifiedRepairCandidate `
                    -CandidatePaths @(Get-PreCommitCandidateExecutablePaths -RepositoryRoot $RepositoryRoot) `
                    -RepositoryRoot $RepositoryRoot `
                    -ExpectedVersion $ExpectedVersion `
                    -DeadlineUtc $repairDeadlineUtc `
                    -StrategyLabel "pipx" `
                    -Diagnostics $repairDiagnostics
                if (-not [string]::IsNullOrWhiteSpace($verifiedPipxExecutable)) {
                    return [pscustomobject]@{
                        Succeeded          = $true
                        Strategy           = "pipx-install"
                        RepairedExecutable = $verifiedPipxExecutable
                        Diagnostics        = @()
                    }
                }
            }
            else {
                $repairDiagnostics.Add("pipx strategy failed (exitCode=$([int]$pipxResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (Join-PreCommitCommandOutput -Stdout $pipxResult.Stdout -Stderr $pipxResult.Stderr))).") | Out-Null
            }
        }
    }

    $homePathVariable = Get-Variable -Name "HOME" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $homePathVariable -or [string]::IsNullOrWhiteSpace([string]$homePathVariable)) {
        $repairDiagnostics.Add("venv strategy skipped because HOME is unavailable.") | Out-Null
    }
    else {
        $homePath = [string]$homePathVariable
        $venvPath = Join-Path -Path $homePath -ChildPath ".local/venvs/pre-commit"
        $venvPythonPath = if (Test-IsWindowsPlatform) {
            Join-Path -Path $venvPath -ChildPath "Scripts/python.exe"
        }
        else {
            Join-Path -Path $venvPath -ChildPath "bin/python"
        }
        $venvPreCommitPath = if (Test-IsWindowsPlatform) {
            Join-Path -Path $venvPath -ChildPath "Scripts/pre-commit.exe"
        }
        else {
            Join-Path -Path $venvPath -ChildPath "bin/pre-commit"
        }

        $pythonLauncherPath = ""
        $pythonLauncherArguments = @()
        if (Test-IsWindowsPlatform) {
            $pyCommand = Get-Command -Name "py" -ErrorAction SilentlyContinue
            $pyCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $pyCommand
            if (-not [string]::IsNullOrWhiteSpace($pyCommandPath)) {
                $pythonLauncherPath = $pyCommandPath
                $pythonLauncherArguments = @("-3", "-m", "venv", $venvPath)
            }
        }

        if ([string]::IsNullOrWhiteSpace($pythonLauncherPath)) {
            foreach ($pythonCandidate in @("python3", "python")) {
                $pythonCommand = Get-Command -Name $pythonCandidate -ErrorAction SilentlyContinue
                $pythonCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $pythonCommand
                if (-not [string]::IsNullOrWhiteSpace($pythonCommandPath)) {
                    $pythonLauncherPath = $pythonCommandPath
                    $pythonLauncherArguments = @("-m", "venv", $venvPath)
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($pythonLauncherPath)) {
            $repairDiagnostics.Add("venv strategy skipped because no python launcher was found (tried: py, python3, python).") | Out-Null
        }
        else {
            if (Test-Path -LiteralPath $venvPath) {
                try {
                    Remove-Item -LiteralPath $venvPath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    $repairDiagnostics.Add("venv strategy could not remove stale venv at '$venvPath'. $($_.Exception.Message)") | Out-Null
                }
            }

            $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
            if ($remainingSeconds -gt 0) {
                $venvCreateTimeoutSeconds = [Math]::Min($remainingSeconds, 180)
                $venvCreateResult = Invoke-PreCommitExternalCommand -Executable $pythonLauncherPath -Arguments $pythonLauncherArguments -RepositoryRoot $RepositoryRoot -TimeoutSeconds $venvCreateTimeoutSeconds -ContextLabel "python venv bootstrap"
                if ($venvCreateResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $venvPythonPath -PathType Leaf)) {
                    $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
                    if ($remainingSeconds -gt 0) {
                        $pipInstallTimeoutSeconds = [Math]::Min($remainingSeconds, 240)
                        $pipInstallResult = Invoke-PreCommitExternalCommand -Executable $venvPythonPath -Arguments @("-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pre-commit==$ExpectedVersion") -RepositoryRoot $RepositoryRoot -TimeoutSeconds $pipInstallTimeoutSeconds -ContextLabel "venv pip install pre-commit==$ExpectedVersion"
                        $verifiedVenvExecutable = ""
                        if ($pipInstallResult.ExitCode -eq 0) {
                            $verifiedVenvExecutable = Resolve-PreCommitVerifiedRepairCandidate `
                                -CandidatePaths @($venvPreCommitPath) `
                                -RepositoryRoot $RepositoryRoot `
                                -ExpectedVersion $ExpectedVersion `
                                -DeadlineUtc $repairDeadlineUtc `
                                -StrategyLabel "venv" `
                                -Diagnostics $repairDiagnostics
                        }

                        if (-not [string]::IsNullOrWhiteSpace($verifiedVenvExecutable)) {
                            return [pscustomobject]@{
                                Succeeded          = $true
                                Strategy           = "python-venv"
                                RepairedExecutable = $verifiedVenvExecutable
                                Diagnostics        = @()
                            }
                        }

                        if ($pipInstallResult.ExitCode -ne 0) {
                            $repairDiagnostics.Add("venv pip install failed (exitCode=$([int]$pipInstallResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (Join-PreCommitCommandOutput -Stdout $pipInstallResult.Stdout -Stderr $pipInstallResult.Stderr))).") | Out-Null
                        }
                    }
                }
                else {
                    $repairDiagnostics.Add("venv bootstrap failed (exitCode=$([int]$venvCreateResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (Join-PreCommitCommandOutput -Stdout $venvCreateResult.Stdout -Stderr $venvCreateResult.Stderr))).") | Out-Null
                }
            }
        }
    }

    $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
    if ($remainingSeconds -gt 0) {
        $pyzResult = Install-PreCommitPyzFallback -RepositoryRoot $RepositoryRoot -ExpectedVersion $ExpectedVersion -DeadlineUtc $repairDeadlineUtc
        if ($pyzResult.Succeeded) {
            return $pyzResult
        }

        foreach ($pyzDiagnostic in @($pyzResult.Diagnostics)) {
            $repairDiagnostics.Add([string]$pyzDiagnostic) | Out-Null
        }
    }

    return [pscustomobject]@{
        Succeeded          = $false
        Strategy           = ""
        RepairedExecutable = ""
        Diagnostics        = @($repairDiagnostics.ToArray())
    }
}

function Resolve-PreCommitCliExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30,

        [Parameter(Mandatory = $false)]
        [switch]$EnableAutoRepair,

        [Parameter(Mandatory = $false)]
        [ValidateRange(30, 1800)]
        [int]$AutoRepairTimeoutSeconds = 240
    )

    $expectedVersion = Get-RequiredPreCommitVersion -RepositoryRoot $RepositoryRoot
    $probeDiagnostics = New-Object System.Collections.Generic.List[string]
    $mismatchDiagnostics = New-Object System.Collections.Generic.List[string]

    $probeCandidates = @(Get-PreCommitCandidateExecutablePaths -RepositoryRoot $RepositoryRoot)
    $resolved = $null

    foreach ($probeCandidate in $probeCandidates) {
        if (-not (Test-Path -LiteralPath $probeCandidate -PathType Leaf)) {
            continue
        }

        $probeResult = Get-PreCommitVersionProbeClassification -PreCommitExecutable $probeCandidate -RepositoryRoot $RepositoryRoot -ExpectedVersion $expectedVersion -TimeoutSeconds $TimeoutSeconds
        if ($probeResult.Status -eq "ok") {
            $resolved = [pscustomobject]@{
                Executable      = $probeCandidate
                ExpectedVersion = $expectedVersion
                ActualVersion   = [string]$probeResult.ActualVersion
                AutoRepaired    = $false
            }
            break
        }

        if ($probeResult.Status -eq "timeout") {
            throw [string]$probeResult.Diagnostic
        }

        if ($probeResult.Status -eq "mismatch") {
            $mismatchDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
        }
        else {
            $probeDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
        }
    }

    if ($null -eq $resolved -and $EnableAutoRepair) {
        Write-Warning "W_VALIDATION_PRECOMMIT_AUTO_REPAIR: no healthy pinned pre-commit executable found; attempting automatic CLI repair."
        $repairResult = Invoke-PreCommitCliAutoRepair -RepositoryRoot $RepositoryRoot -ExpectedVersion $expectedVersion -TimeoutSeconds $AutoRepairTimeoutSeconds
        foreach ($repairDiagnostic in @($repairResult.Diagnostics)) {
            $probeDiagnostics.Add([string]$repairDiagnostic) | Out-Null
        }

        if (-not $repairResult.Succeeded) {
            $diagnosticPreview = Get-PreCommitFailureOutputPreview -Output ($probeDiagnostics.ToArray() -join " ")
            throw (
                "E_VALIDATION_PRECOMMIT_AUTO_REPAIR_FAILED: unable to automatically repair pre-commit CLI to pinned version $expectedVersion. diagnostics=$diagnosticPreview"
            )
        }

        $postRepairCandidates = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace([string]$repairResult.RepairedExecutable)) {
            $postRepairCandidates.Add([string]$repairResult.RepairedExecutable) | Out-Null
        }
        foreach ($candidatePath in @(Get-PreCommitCandidateExecutablePaths -RepositoryRoot $RepositoryRoot)) {
            $postRepairCandidates.Add([string]$candidatePath) | Out-Null
        }

        $pathComparer = if (Test-IsWindowsPlatform) {
            [System.StringComparer]::OrdinalIgnoreCase
        }
        else {
            [System.StringComparer]::Ordinal
        }
        $seenPostRepair = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
        foreach ($postRepairCandidate in @($postRepairCandidates.ToArray())) {
            if ([string]::IsNullOrWhiteSpace([string]$postRepairCandidate)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $postRepairCandidate -PathType Leaf)) {
                continue
            }

            if (-not $seenPostRepair.Add([string]$postRepairCandidate)) {
                continue
            }

            $probeResult = Get-PreCommitVersionProbeClassification -PreCommitExecutable $postRepairCandidate -RepositoryRoot $RepositoryRoot -ExpectedVersion $expectedVersion -TimeoutSeconds $TimeoutSeconds
            if ($probeResult.Status -eq "ok") {
                $resolved = [pscustomobject]@{
                    Executable      = [string]$postRepairCandidate
                    ExpectedVersion = $expectedVersion
                    ActualVersion   = [string]$probeResult.ActualVersion
                    AutoRepaired    = $true
                }
                break
            }

            if ($probeResult.Status -eq "timeout") {
                throw [string]$probeResult.Diagnostic
            }

            if ($probeResult.Status -eq "mismatch") {
                $mismatchDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
            }
            else {
                $probeDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
            }
        }
    }

    if ($null -ne $resolved) {
        return $resolved
    }

    if ($mismatchDiagnostics.Count -gt 0 -and $probeDiagnostics.Count -eq 0) {
        $mismatchPreview = Get-PreCommitFailureOutputPreview -Output ($mismatchDiagnostics.ToArray() -join " ")
        throw (
            "E_VALIDATION_PRECOMMIT_VERSION_MISMATCH: no discovered pre-commit executable matches the pinned version $expectedVersion. diagnostics=$mismatchPreview Install the pinned CLI with 'pipx install --force pre-commit==$expectedVersion' or a dedicated venv (python3 -m venv ~/.local/venvs/pre-commit; ~/.local/venvs/pre-commit/bin/pip install --requirement requirements.txt; ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit)."
        )
    }

    if ($probeCandidates.Count -eq 0) {
        throw (
            "E_VALIDATION_PRECOMMIT_NOT_AVAILABLE: pre-commit is not available on PATH and no managed fallback executable was found. Install the pinned CLI with 'pipx install --force pre-commit==$expectedVersion' or a dedicated venv (python3 -m venv ~/.local/venvs/pre-commit; ~/.local/venvs/pre-commit/bin/pip install --requirement requirements.txt; ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit)."
        )
    }

    $diagnosticPreview = Get-PreCommitFailureOutputPreview -Output ($probeDiagnostics.ToArray() -join " ")
    throw (
        "E_VALIDATION_PRECOMMIT_RESOLUTION_FAILED: unable to execute a healthy pinned pre-commit CLI (expectedVersion=$expectedVersion; candidatesTried=$($probeCandidates.Count); diagnostics=$diagnosticPreview)."
    )
}
