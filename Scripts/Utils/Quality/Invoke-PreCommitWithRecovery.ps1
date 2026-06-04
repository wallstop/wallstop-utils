[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("pre-commit", "pre-push")]
    [string]$HookStage = "pre-commit",

    [Parameter(Mandatory = $false)]
    [switch]$AllFiles,

    [Parameter(Mandatory = $false)]
    [string[]]$Files = @(),

    [Parameter(Mandatory = $false)]
    [string]$FileListPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$InstallHooksOnly,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 3)]
    [int]$RepairAttempts = 1,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 7200)]
    [int]$TimeoutSeconds = 900,

    [Parameter(Mandatory = $false)]
    [switch]$NoInvokeMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_PRECOMMIT_RECOVERY_PREREQ_MISSING: Compatibility helper file not found at '$compatibilityHelpersPath'."
}
. $compatibilityHelpersPath

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -LiteralPath $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_PRECOMMIT_RECOVERY_DIAGNOSTICS_HELPER_MISSING: Diagnostics helper file not found at '$diagnosticsHelpersPath'."
}
. $diagnosticsHelpersPath

$preCommitCliHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/PreCommitCliHelpers.ps1"
if (-not (Test-Path -LiteralPath $preCommitCliHelpersPath -PathType Leaf)) {
    throw "E_PRECOMMIT_RECOVERY_CLI_HELPER_MISSING: pre-commit CLI helper file not found at '$preCommitCliHelpersPath'."
}
. $preCommitCliHelpersPath

$script:PreCommitRecoveryScriptRepositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../../..") -ErrorAction Stop).Path

function Get-PreCommitRecoveryGitExecutableOrThrow {
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_PRECOMMIT_RECOVERY_GIT_NOT_AVAILABLE: git is required for pre-commit recovery but was not found on PATH."
    }

    Write-Verbose ("Pre-commit recovery git diagnostics: gitPath='{0}'" -f $gitCommand.Source)
    return $gitCommand.Source
}

function Resolve-PreCommitRecoveryRepositoryRootOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable
    )

    $repositoryRootOutput = @(& $GitExecutable -C $script:PreCommitRecoveryScriptRepositoryRoot rev-parse --show-toplevel 2>&1)
    if ($LASTEXITCODE -ne 0 -or $repositoryRootOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$repositoryRootOutput[0])) {
        $repositoryRootPreview = Get-OutputPreview -OutputLines $repositoryRootOutput -CollapseWhitespace
        throw (
            "E_PRECOMMIT_RECOVERY_NOT_REPOSITORY: unable to resolve git repository root from script root (scriptRoot='{0}'; outputPreview={1})." -f
            $script:PreCommitRecoveryScriptRepositoryRoot,
            $repositoryRootPreview
        )
    }

    $repositoryRoot = (Resolve-Path -LiteralPath ([string]$repositoryRootOutput[0]).Trim() -ErrorAction Stop).Path
    Write-Verbose ("Pre-commit recovery repository diagnostics: repositoryRoot='{0}'; scriptRoot='{1}'; workingDirectory='{2}'" -f $repositoryRoot, $script:PreCommitRecoveryScriptRepositoryRoot, (Get-Location).Path)
    return $repositoryRoot
}

function Get-PreCommitRecoveryRemainingTimeoutSeconds {
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

function Get-PreCommitRecoveryTargetFiles {
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
            throw "E_PRECOMMIT_RECOVERY_TARGET_LIST_MISSING: target file list not found at '$ListPath'."
        }

        foreach ($listedFile in @([System.IO.File]::ReadAllLines($ListPath, [System.Text.Encoding]::UTF8))) {
            if (-not [string]::IsNullOrWhiteSpace($listedFile)) {
                $targetFiles.Add([string]$listedFile) | Out-Null
            }
        }
    }

    return @($targetFiles.ToArray())
}

function New-PreCommitRecoveryTimeoutResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter(Mandatory = $true)]
        [int]$OverallTimeoutSeconds
    )

    return [pscustomobject]@{
        ExitCode        = 124
        Stdout          = ""
        Stderr          = "E_PRECOMMIT_RECOVERY_TIMEOUT: pre-commit recovery exceeded overall timeout before ${Context} (timeout=${OverallTimeoutSeconds}s)."
        TimedOut        = $true
        CaptureTimedOut = $false
        CaptureFailed   = $false
    }
}

function Receive-PreCommitCommandStreamText {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$StreamTask,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StreamName,

        [Parameter(Mandatory = $true)]
        [ValidateRange(100, 60000)]
        [int]$DrainTimeoutMilliseconds
    )

    try {
        if ($StreamTask.Wait($DrainTimeoutMilliseconds)) {
            return [pscustomobject]@{
                Text       = [string]$StreamTask.GetAwaiter().GetResult()
                TimedOut   = $false
                Failed     = $false
                Diagnostic = ""
            }
        }

        return [pscustomobject]@{
            Text       = ""
            TimedOut   = $true
            Failed     = $false
            Diagnostic = "E_PRECOMMIT_RECOVERY_CAPTURE_TIMEOUT: failed to drain ${StreamName} within ${DrainTimeoutMilliseconds}ms."
        }
    }
    catch {
        return [pscustomobject]@{
            Text       = ""
            TimedOut   = $false
            Failed     = $true
            Diagnostic = "E_PRECOMMIT_RECOVERY_CAPTURE_FAILED: failed to drain ${StreamName}. $($_.Exception.Message)"
        }
    }
}

function Join-PreCommitCapturedStderr {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$PrimaryStderr = "",

        [Parameter(Mandatory = $false)]
        [string[]]$Diagnostics = @()
    )

    $stderrLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($PrimaryStderr)) {
        $stderrLines.Add($PrimaryStderr.TrimEnd()) | Out-Null
    }

    foreach ($diagnostic in @($Diagnostics)) {
        if (-not [string]::IsNullOrWhiteSpace($diagnostic)) {
            $stderrLines.Add($diagnostic) | Out-Null
        }
    }

    return ($stderrLines.ToArray() -join [Environment]::NewLine)
}

function New-PreCommitEnvironmentRepairResult {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Succeeded,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    return [pscustomobject]@{
        Succeeded = $Succeeded
        ExitCode   = $ExitCode
    }
}

function Get-PreCommitExecutableOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc,

        [Parameter(Mandatory = $true)]
        [int]$OverallTimeoutSeconds
    )

    $preCommitCommand = Get-Command -Name "pre-commit" -ErrorAction SilentlyContinue
    if ($null -eq $preCommitCommand) {
        throw "E_PRECOMMIT_RECOVERY_PREREQ_MISSING: pre-commit is required but was not found on PATH."
    }

    $versionProbeTimeoutSeconds = Get-PreCommitRecoveryRemainingTimeoutSeconds -DeadlineUtc $DeadlineUtc
    if ($versionProbeTimeoutSeconds -lt 1) {
        throw "E_PRECOMMIT_RECOVERY_TIMEOUT: pre-commit recovery exceeded overall timeout before pre-commit version probe (timeout=${OverallTimeoutSeconds}s)."
    }
    $versionProbeTimeoutSeconds = [Math]::Min($versionProbeTimeoutSeconds, 120)

    [void](Assert-PreCommitCliVersion -PreCommitExecutable $preCommitCommand.Source -RepositoryRoot $RepositoryRoot -TimeoutSeconds $versionProbeTimeoutSeconds)
    Write-Verbose ("Pre-commit recovery diagnostics: preCommitPath='{0}'" -f $preCommitCommand.Source)
    return $preCommitCommand.Source
}

function Invoke-PreCommitCapturedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc,

        [Parameter(Mandatory = $true)]
        [int]$OverallTimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [string]$CommandContext = "pre-commit command",

        [Parameter(Mandatory = $false)]
        [ValidateRange(100, 60000)]
        [int]$StreamDrainTimeoutMilliseconds = 5000
    )

    $commandTimeoutSeconds = Get-PreCommitRecoveryRemainingTimeoutSeconds -DeadlineUtc $DeadlineUtc
    if ($commandTimeoutSeconds -lt 1) {
        return New-PreCommitRecoveryTimeoutResult -Context $CommandContext -OverallTimeoutSeconds $OverallTimeoutSeconds
    }

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $PreCommitExecutable
    $processStartInfo.WorkingDirectory = $RepositoryRoot
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true

    # ProcessStartInfo.ArgumentList is .NET Core-only; see Set-PortableProcessArguments.
    Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList $Arguments

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($commandTimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Pre-commit recovery cleanup diagnostics: failed to kill timed-out process: $($_.Exception.Message)"
            }

            $stdoutCapture = Receive-PreCommitCommandStreamText -StreamTask $stdoutTask -StreamName "stdout" -DrainTimeoutMilliseconds $StreamDrainTimeoutMilliseconds
            $stderrCapture = Receive-PreCommitCommandStreamText -StreamTask $stderrTask -StreamName "stderr" -DrainTimeoutMilliseconds $StreamDrainTimeoutMilliseconds
            $captureDiagnostics = @(
                [string]$stdoutCapture.Diagnostic,
                [string]$stderrCapture.Diagnostic
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $timeoutDiagnostics = @(
                "E_PRECOMMIT_RECOVERY_TIMEOUT: ${CommandContext} exceeded ${commandTimeoutSeconds}s remaining in overall pre-commit recovery timeout (timeout=${OverallTimeoutSeconds}s)."
            ) + @($captureDiagnostics)

            return [pscustomobject]@{
                ExitCode        = 124
                Stdout          = [string]$stdoutCapture.Text
                Stderr          = Join-PreCommitCapturedStderr -PrimaryStderr ([string]$stderrCapture.Text) -Diagnostics $timeoutDiagnostics
                TimedOut        = $true
                CaptureTimedOut = [bool]($stdoutCapture.TimedOut -or $stderrCapture.TimedOut)
                CaptureFailed   = [bool]($stdoutCapture.Failed -or $stderrCapture.Failed)
            }
        }

        $stdoutCapture = Receive-PreCommitCommandStreamText -StreamTask $stdoutTask -StreamName "stdout" -DrainTimeoutMilliseconds $StreamDrainTimeoutMilliseconds
        $stderrCapture = Receive-PreCommitCommandStreamText -StreamTask $stderrTask -StreamName "stderr" -DrainTimeoutMilliseconds $StreamDrainTimeoutMilliseconds
        $captureDiagnostics = @(
            [string]$stdoutCapture.Diagnostic,
            [string]$stderrCapture.Diagnostic
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $captureTimedOut = [bool]($stdoutCapture.TimedOut -or $stderrCapture.TimedOut)
        $captureFailed = [bool]($stdoutCapture.Failed -or $stderrCapture.Failed)
        $effectiveExitCode = if ($captureTimedOut) {
            124
        }
        elseif ($captureFailed -and $process.ExitCode -eq 0) {
            1
        }
        else {
            [int]$process.ExitCode
        }

        return [pscustomobject]@{
            ExitCode        = $effectiveExitCode
            Stdout          = [string]$stdoutCapture.Text
            Stderr          = Join-PreCommitCapturedStderr -PrimaryStderr ([string]$stderrCapture.Text) -Diagnostics @($captureDiagnostics)
            TimedOut        = $captureTimedOut
            CaptureTimedOut = $captureTimedOut
            CaptureFailed   = $captureFailed
        }
    }
    finally {
        $process.Dispose()
    }
}

function Write-PreCommitCapturedOutput {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    if (-not [string]::IsNullOrEmpty([string]$Result.Stdout)) {
        [Console]::Out.Write([string]$Result.Stdout)
    }
    if (-not [string]::IsNullOrEmpty([string]$Result.Stderr)) {
        [Console]::Error.Write([string]$Result.Stderr)
    }
}

function Test-PreCommitEnvironmentFailure {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    $timedOutProperty = $Result.PSObject.Properties['TimedOut']
    $captureTimedOutProperty = $Result.PSObject.Properties['CaptureTimedOut']
    $timedOut = ($null -ne $timedOutProperty -and [bool]$timedOutProperty.Value)
    $captureTimedOut = ($null -ne $captureTimedOutProperty -and [bool]$captureTimedOutProperty.Value)
    if ($timedOut -or $captureTimedOut) {
        return $false
    }

    $combinedOutput = @([string]$Result.Stdout, [string]$Result.Stderr) -join [Environment]::NewLine
    if ($combinedOutput -match 'files were modified by this hook') {
        return $false
    }

    $environmentFailurePatterns = @(
        'An unexpected error has occurred',
        'CalledProcessError',
        'failed to install',
        'healthy\(\)',
        'environment.*(invalid|corrupt|failed)',
        'nodeenv|npm ERR!|node_modules',
        'rustenv|cargo(\.EXE)?\s+install',
        'go\s+(install|env|version)',
        'sqlite.*pre-commit',
        'Permission denied.*\.cache.*pre-commit'
    )

    foreach ($pattern in $environmentFailurePatterns) {
        if ($combinedOutput -match $pattern) {
            return $true
        }
    }

    return $false
}

function Invoke-PreCommitIndexLockRecovery {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result,

        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc,

        [Parameter(Mandatory = $true)]
        [int]$OverallTimeoutSeconds
    )

    $combinedOutputLines = @([string]$Result.Stdout, [string]$Result.Stderr)
    if (-not (Test-IsGitIndexLockFailure -OutputLines $combinedOutputLines)) {
        return [pscustomobject]@{
            Handled  = $false
            ExitCode = [int]$Result.ExitCode
        }
    }

    $workingDirectory = (Get-Location).Path
    $detectedMessage = "W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED: repositoryRoot='{0}'; workingDirectory='{1}'; context='pre-commit-wrapper'; exitCode={2}." -f $RepositoryRoot, $workingDirectory, [int]$Result.ExitCode
    [Console]::Error.WriteLine($detectedMessage)

    $lockRecovery = Invoke-SafeGitIndexLockRecovery -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -OutputLines $combinedOutputLines -Context "pre-commit-wrapper"
    if ($lockRecovery.ElapsedMilliseconds -gt $lockRecovery.SlowPathThresholdMs) {
        $slowPathMessage = "W_PRECOMMIT_GIT_INDEX_LOCK_SLOW_PATH: context='pre-commit-wrapper'; elapsedMs={0}; thresholdMs={1}." -f $lockRecovery.ElapsedMilliseconds, $lockRecovery.SlowPathThresholdMs
        [Console]::Error.WriteLine($slowPathMessage)
    }

    if (-not $lockRecovery.Recovered) {
        $skipReason = if ([string]::IsNullOrWhiteSpace([string]$lockRecovery.SkippedReason)) {
            "unknown"
        }
        else {
            [string]$lockRecovery.SkippedReason
        }

        $skipMessage = "W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_SKIPPED: context='pre-commit-wrapper'; reason={0}; lockPath='{1}'; lockAgeSeconds={2}; activeGitProcessCount={3}; processScanDegraded={4}." -f $skipReason, [string]$lockRecovery.LockPath, [int]$lockRecovery.LockAgeSeconds, [int]$lockRecovery.ActiveGitProcessCount, [bool]$lockRecovery.ProcessScanDegraded
        [Console]::Error.WriteLine($skipMessage)

        if ($skipReason -eq "recovery_failed") {
            $recoveryFailedMessage = "E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED: context='pre-commit-wrapper'; error={0}." -f [string]$lockRecovery.ErrorMessage
            [Console]::Error.WriteLine($recoveryFailedMessage)
            return [pscustomobject]@{
                Handled  = $true
                ExitCode = [int]$Result.ExitCode
            }
        }

        return [pscustomobject]@{
            Handled  = $true
            ExitCode = [int]$Result.ExitCode
        }
    }

    $retryingMessage = "W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_RETRYING: context='pre-commit-wrapper'; lockPath='{0}'; lockAgeSeconds={1}." -f [string]$lockRecovery.LockPath, [int]$lockRecovery.LockAgeSeconds
    [Console]::Error.WriteLine($retryingMessage)

    $retryResult = Invoke-PreCommitCapturedCommand -PreCommitExecutable $PreCommitExecutable -Arguments $Arguments -RepositoryRoot $RepositoryRoot -DeadlineUtc $DeadlineUtc -OverallTimeoutSeconds $OverallTimeoutSeconds -CommandContext "index-lock recovery retry"
    Write-PreCommitCapturedOutput -Result $retryResult
    if ($retryResult.ExitCode -eq 0) {
        return [pscustomobject]@{
            Handled  = $true
            ExitCode = 0
        }
    }

    if (Test-IsGitIndexLockFailure -OutputLines @([string]$retryResult.Stdout, [string]$retryResult.Stderr)) {
        $persistedMessage = "E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED: context='pre-commit-wrapper'; lock persisted after recovery retry (exitCode={0})." -f [int]$retryResult.ExitCode
        [Console]::Error.WriteLine($persistedMessage)
    }

    return [pscustomobject]@{
        Handled  = $true
        ExitCode = [int]$retryResult.ExitCode
    }
}

function Invoke-PreCommitEnvironmentRepair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc,

        [Parameter(Mandatory = $true)]
        [int]$OverallTimeoutSeconds
    )

    Write-Warning "W_PRECOMMIT_ENV_AUTO_REPAIR: pre-commit environment failure detected; cleaning hook environments and pre-warming pinned hooks before retry."
    $cleanResult = Invoke-PreCommitCapturedCommand -PreCommitExecutable $PreCommitExecutable -Arguments @("clean") -RepositoryRoot $RepositoryRoot -DeadlineUtc $DeadlineUtc -OverallTimeoutSeconds $OverallTimeoutSeconds -CommandContext "pre-commit clean"
    Write-PreCommitCapturedOutput -Result $cleanResult
    if ($cleanResult.ExitCode -ne 0) {
        [Console]::Error.WriteLine("E_PRECOMMIT_ENV_CLEAN_FAILED: pre-commit clean failed (exitCode=$($cleanResult.ExitCode)); cannot auto-repair hook environments.")
        return New-PreCommitEnvironmentRepairResult -Succeeded $false -ExitCode ([int]$cleanResult.ExitCode)
    }

    $installResult = Invoke-PreCommitCapturedCommand -PreCommitExecutable $PreCommitExecutable -Arguments @("install-hooks") -RepositoryRoot $RepositoryRoot -DeadlineUtc $DeadlineUtc -OverallTimeoutSeconds $OverallTimeoutSeconds -CommandContext "pre-commit install-hooks"
    Write-PreCommitCapturedOutput -Result $installResult
    if ($installResult.ExitCode -ne 0) {
        [Console]::Error.WriteLine("E_PRECOMMIT_ENV_PREWARM_FAILED: pre-commit install-hooks failed during auto-repair (exitCode=$($installResult.ExitCode)).")
        return New-PreCommitEnvironmentRepairResult -Succeeded $false -ExitCode ([int]$installResult.ExitCode)
    }

    return New-PreCommitEnvironmentRepairResult -Succeeded $true -ExitCode 0
}

function Get-PreCommitRunArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("pre-commit", "pre-push")]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [bool]$UseAllFiles,

        [Parameter(Mandatory = $false)]
        [string[]]$TargetFiles = @()
    )

    $normalizedTargetFiles = @(
        $TargetFiles |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($UseAllFiles -and $normalizedTargetFiles.Count -gt 0) {
        throw "E_PRECOMMIT_RECOVERY_ARG_CONFLICT: -AllFiles cannot be combined with explicit -Files targets."
    }

    $arguments = @("run", "--hook-stage", $Stage)
    if ($UseAllFiles) {
        $arguments += "--all-files"
    }
    elseif ($normalizedTargetFiles.Count -gt 0) {
        $arguments += "--files"
        $arguments += @($normalizedTargetFiles)
    }

    $arguments += @("--show-diff-on-failure", "--color", "always")
    return @($arguments)
}

function Invoke-PreCommitWithRecoveryMain {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("pre-commit", "pre-push")]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [bool]$UseAllFiles,

        [Parameter(Mandatory = $false)]
        [string[]]$TargetFiles = @(),

        [Parameter(Mandatory = $true)]
        [bool]$OnlyInstallHooks,

        [Parameter(Mandatory = $true)]
        [int]$MaximumRepairAttempts,

        [Parameter(Mandatory = $true)]
        [int]$CommandTimeoutSeconds
    )

    $deadlineUtc = [datetime]::UtcNow.AddSeconds($CommandTimeoutSeconds)
    try {
        $gitExecutable = Get-PreCommitRecoveryGitExecutableOrThrow
        $repositoryRoot = Resolve-PreCommitRecoveryRepositoryRootOrThrow -GitExecutable $gitExecutable
        $preCommitExecutable = Get-PreCommitExecutableOrThrow -RepositoryRoot $repositoryRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds $CommandTimeoutSeconds
    }
    catch {
        [Console]::Error.WriteLine([string]$_.Exception.Message)
        if ($_.Exception.Message -match '\b(E_PRECOMMIT_RECOVERY_TIMEOUT|E_VALIDATION_PRECOMMIT_VERSION_TIMEOUT)\b') {
            return 124
        }

        throw
    }

    $arguments = if ($OnlyInstallHooks) {
        @("install-hooks")
    }
    else {
        @(Get-PreCommitRunArguments -Stage $Stage -UseAllFiles $UseAllFiles -TargetFiles $TargetFiles)
    }

    $result = Invoke-PreCommitCapturedCommand -PreCommitExecutable $preCommitExecutable -Arguments $arguments -RepositoryRoot $repositoryRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds $CommandTimeoutSeconds -CommandContext "initial pre-commit run"
    Write-PreCommitCapturedOutput -Result $result
    if ($result.ExitCode -eq 0) {
        return 0
    }

    $indexLockRecoveryResult = Invoke-PreCommitIndexLockRecovery -Result $result -PreCommitExecutable $preCommitExecutable -Arguments $arguments -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds $CommandTimeoutSeconds
    if ($indexLockRecoveryResult.Handled) {
        return [int]$indexLockRecoveryResult.ExitCode
    }

    if (-not (Test-PreCommitEnvironmentFailure -Result $result)) {
        return $result.ExitCode
    }

    for ($attempt = 1; $attempt -le $MaximumRepairAttempts; $attempt++) {
        $repairResult = Invoke-PreCommitEnvironmentRepair -PreCommitExecutable $preCommitExecutable -RepositoryRoot $repositoryRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds $CommandTimeoutSeconds
        if (-not $repairResult.Succeeded) {
            return [int]$repairResult.ExitCode
        }

        Write-Warning "W_PRECOMMIT_ENV_AUTO_RETRY: retrying pre-commit command after environment repair (attempt=$attempt)."
        $retryResult = Invoke-PreCommitCapturedCommand -PreCommitExecutable $preCommitExecutable -Arguments $arguments -RepositoryRoot $repositoryRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds $CommandTimeoutSeconds -CommandContext "environment repair retry"
        Write-PreCommitCapturedOutput -Result $retryResult
        if ($retryResult.ExitCode -eq 0) {
            return 0
        }

        if (-not (Test-PreCommitEnvironmentFailure -Result $retryResult)) {
            return $retryResult.ExitCode
        }

        $result = $retryResult
    }

    [Console]::Error.WriteLine("E_PRECOMMIT_ENV_AUTO_REPAIR_FAILED: pre-commit environment failure persisted after $MaximumRepairAttempts auto-repair attempt(s).")
    return $result.ExitCode
}

if (-not $NoInvokeMain) {
    $targetFiles = @(Get-PreCommitRecoveryTargetFiles -ExplicitFiles $Files -ListPath $FileListPath)
    $exitCode = Invoke-PreCommitWithRecoveryMain -Stage $HookStage -UseAllFiles:$AllFiles.IsPresent -TargetFiles $targetFiles -OnlyInstallHooks:$InstallHooksOnly.IsPresent -MaximumRepairAttempts $RepairAttempts -CommandTimeoutSeconds $TimeoutSeconds
    exit $exitCode
}
