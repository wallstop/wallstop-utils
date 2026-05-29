[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("pre-commit", "pre-push")]
    [string]$HookStage = "pre-commit",

    [Parameter(Mandatory = $false)]
    [switch]$AllFiles,

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

function Get-PreCommitExecutableOrThrow {
    $preCommitCommand = Get-Command -Name "pre-commit" -ErrorAction SilentlyContinue
    if ($null -eq $preCommitCommand) {
        throw "E_PRECOMMIT_RECOVERY_PREREQ_MISSING: pre-commit is required but was not found on PATH."
    }

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
        [int]$CommandTimeoutSeconds
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $PreCommitExecutable
    $processStartInfo.WorkingDirectory = (Get-Location).Path
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true

    foreach ($argument in @($Arguments)) {
        [void]$processStartInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($CommandTimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-Verbose "Pre-commit recovery cleanup diagnostics: failed to kill timed-out process: $($_.Exception.Message)"
            }

            return [pscustomobject]@{
                ExitCode = 124
                Stdout   = $stdoutTask.GetAwaiter().GetResult()
                Stderr   = "E_PRECOMMIT_RECOVERY_TIMEOUT: pre-commit command exceeded ${CommandTimeoutSeconds}s."
                TimedOut = $true
            }
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.GetAwaiter().GetResult()
            Stderr   = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $false
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

function Invoke-PreCommitEnvironmentRepair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [int]$CommandTimeoutSeconds
    )

    Write-Warning "W_PRECOMMIT_ENV_AUTO_REPAIR: pre-commit environment failure detected; cleaning hook environments and pre-warming pinned hooks before retry."
    $cleanResult = Invoke-PreCommitCapturedCommand -PreCommitExecutable $PreCommitExecutable -Arguments @("clean") -CommandTimeoutSeconds $CommandTimeoutSeconds
    Write-PreCommitCapturedOutput -Result $cleanResult
    if ($cleanResult.ExitCode -ne 0) {
        [Console]::Error.WriteLine("E_PRECOMMIT_ENV_CLEAN_FAILED: pre-commit clean failed (exitCode=$($cleanResult.ExitCode)); cannot auto-repair hook environments.")
        return $false
    }

    $installResult = Invoke-PreCommitCapturedCommand -PreCommitExecutable $PreCommitExecutable -Arguments @("install-hooks") -CommandTimeoutSeconds $CommandTimeoutSeconds
    Write-PreCommitCapturedOutput -Result $installResult
    if ($installResult.ExitCode -ne 0) {
        [Console]::Error.WriteLine("E_PRECOMMIT_ENV_PREWARM_FAILED: pre-commit install-hooks failed during auto-repair (exitCode=$($installResult.ExitCode)).")
        return $false
    }

    return $true
}

function Get-PreCommitRunArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("pre-commit", "pre-push")]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [bool]$UseAllFiles
    )

    $arguments = @("run", "--hook-stage", $Stage)
    if ($UseAllFiles) {
        $arguments += "--all-files"
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

        [Parameter(Mandatory = $true)]
        [bool]$OnlyInstallHooks,

        [Parameter(Mandatory = $true)]
        [int]$MaximumRepairAttempts,

        [Parameter(Mandatory = $true)]
        [int]$CommandTimeoutSeconds
    )

    $preCommitExecutable = Get-PreCommitExecutableOrThrow
    $arguments = if ($OnlyInstallHooks) {
        @("install-hooks")
    }
    else {
        @(Get-PreCommitRunArguments -Stage $Stage -UseAllFiles $UseAllFiles)
    }

    $result = Invoke-PreCommitCapturedCommand -PreCommitExecutable $preCommitExecutable -Arguments $arguments -CommandTimeoutSeconds $CommandTimeoutSeconds
    Write-PreCommitCapturedOutput -Result $result
    if ($result.ExitCode -eq 0) {
        return 0
    }

    if (-not (Test-PreCommitEnvironmentFailure -Result $result)) {
        return $result.ExitCode
    }

    for ($attempt = 1; $attempt -le $MaximumRepairAttempts; $attempt++) {
        if (-not (Invoke-PreCommitEnvironmentRepair -PreCommitExecutable $preCommitExecutable -CommandTimeoutSeconds $CommandTimeoutSeconds)) {
            return $result.ExitCode
        }

        Write-Warning "W_PRECOMMIT_ENV_AUTO_RETRY: retrying pre-commit command after environment repair (attempt=$attempt)."
        $retryResult = Invoke-PreCommitCapturedCommand -PreCommitExecutable $preCommitExecutable -Arguments $arguments -CommandTimeoutSeconds $CommandTimeoutSeconds
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
    $exitCode = Invoke-PreCommitWithRecoveryMain -Stage $HookStage -UseAllFiles:$AllFiles.IsPresent -OnlyInstallHooks:$InstallHooksOnly.IsPresent -MaximumRepairAttempts $RepairAttempts -CommandTimeoutSeconds $TimeoutSeconds
    exit $exitCode
}
