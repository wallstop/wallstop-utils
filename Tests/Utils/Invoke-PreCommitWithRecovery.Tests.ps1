Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:preCommitRecoveryScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1"
    . $script:preCommitRecoveryScriptPath -NoInvokeMain
}

Describe "Invoke-PreCommitWithRecovery environment failure classification" {
    BeforeEach {
        Mock Get-PreCommitRecoveryGitExecutableOrThrow { return "git" }
        Mock Resolve-PreCommitRecoveryRepositoryRootOrThrow { return $script:repoRoot }
    }

    It "classifies hook environment installation failures as repairable" {
        $result = [pscustomobject]@{
            ExitCode = 1
            Stdout   = "[INFO] Installing environment for https://github.com/example/hook."
            Stderr   = "An unexpected error has occurred: CalledProcessError: cargo install failed"
            TimedOut = $false
        }

        Test-PreCommitEnvironmentFailure -Result $result | Should -BeTrue
    }

    It "does not classify formatter drift as environment corruption" {
        $result = [pscustomobject]@{
            ExitCode = 1
            Stdout   = "files were modified by this hook"
            Stderr   = ""
            TimedOut = $false
        }

        Test-PreCommitEnvironmentFailure -Result $result | Should -BeFalse
    }

    It "does not classify timed-out commands as repairable environment corruption" {
        $result = [pscustomobject]@{
            ExitCode        = 124
            Stdout          = "[INFO] Installing environment for https://github.com/example/hook."
            Stderr          = "An unexpected error has occurred: CalledProcessError"
            TimedOut        = $true
            CaptureTimedOut = $false
        }

        Test-PreCommitEnvironmentFailure -Result $result | Should -BeFalse
    }

    It "does not classify capture-timeout commands as repairable environment corruption" {
        $result = [pscustomobject]@{
            ExitCode        = 124
            Stdout          = "[INFO] Installing environment for https://github.com/example/hook."
            Stderr          = "E_PRECOMMIT_RECOVERY_CAPTURE_TIMEOUT: failed to drain stderr within 5000ms.`nCalledProcessError"
            TimedOut        = $false
            CaptureTimedOut = $true
        }

        Test-PreCommitEnvironmentFailure -Result $result | Should -BeFalse
    }

    It "does not classify hook failures as environment corruption only because pre-commit installed environments" {
        $result = [pscustomobject]@{
            ExitCode = 1
            Stdout   = "[INFO] Installing environment for https://github.com/pre-commit/pre-commit-hooks.`nRun Shell Quality Checks................................................Failed"
            Stderr   = "E_PRECOMMIT_SHELL_QUALITY_RESTAGE_REQUIRED: Staged shell files have unstaged working-tree changes."
            TimedOut = $false
        }

        Test-PreCommitEnvironmentFailure -Result $result | Should -BeFalse
    }

    It "builds hook-stage run arguments without collapsing entries" {
        $arguments = @(Get-PreCommitRunArguments -Stage pre-push -UseAllFiles $true)

        $arguments | Should -Be @("run", "--hook-stage", "pre-push", "--all-files", "--show-diff-on-failure", "--color", "always")
    }

    It "builds file-scoped hook-stage run arguments without all-files mode" {
        $arguments = @(Get-PreCommitRunArguments -Stage pre-push -UseAllFiles $false -TargetFiles @("Scripts/Utils/example.ps1", ".githooks/pre-push"))

        $arguments | Should -Be @("run", "--hook-stage", "pre-push", "--files", "Scripts/Utils/example.ps1", ".githooks/pre-push", "--show-diff-on-failure", "--color", "always")
    }

    It "loads file-scoped hook targets from a list file" {
        $targetListPath = Join-Path -Path $TestDrive -ChildPath "targets.txt"
        [System.IO.File]::WriteAllLines(
            $targetListPath,
            [string[]]@("README.md", "Scripts/Utils/Run-PreCommitValidation.ps1"),
            [System.Text.UTF8Encoding]::new($false)
        )

        $targets = @(Get-PreCommitRecoveryTargetFiles -ListPath $targetListPath)

        $targets | Should -Be @("README.md", "Scripts/Utils/Run-PreCommitValidation.ps1")
    }

    It "bounds stream drain after process timeout or exit" {
        $completedStream = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
        $completedStream.SetResult("captured output")
        $completedResult = Receive-PreCommitCommandStreamText -StreamTask $completedStream.Task -StreamName "stdout" -DrainTimeoutMilliseconds 100

        $blockedStream = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
        $blockedResult = Receive-PreCommitCommandStreamText -StreamTask $blockedStream.Task -StreamName "stderr" -DrainTimeoutMilliseconds 100

        $completedResult.Text | Should -Be "captured output"
        $completedResult.TimedOut | Should -BeFalse
        $blockedResult.Text | Should -Be ""
        $blockedResult.TimedOut | Should -BeTrue
        $blockedResult.Diagnostic | Should -Match 'E_PRECOMMIT_RECOVERY_CAPTURE_TIMEOUT'
    }

    It "runs clean then install-hooks during environment repair" {
        $script:capturedPreCommitCommands = New-Object System.Collections.Generic.List[string]
        $script:capturedRepairRoots = New-Object System.Collections.Generic.List[string]
        $script:capturedRepairTimeouts = New-Object System.Collections.Generic.List[int]
        $script:capturedRepairDeadlines = New-Object System.Collections.Generic.List[datetime]
        $deadlineUtc = [datetime]::UtcNow.AddSeconds(30)
        Mock Invoke-PreCommitCapturedCommand {
            param($PreCommitExecutable, $Arguments, $RepositoryRoot, $DeadlineUtc, $OverallTimeoutSeconds, $CommandContext)
            $script:capturedPreCommitCommands.Add(($Arguments -join " ")) | Out-Null
            $script:capturedRepairRoots.Add($RepositoryRoot) | Out-Null
            $script:capturedRepairTimeouts.Add([int]$OverallTimeoutSeconds) | Out-Null
            $script:capturedRepairDeadlines.Add($DeadlineUtc) | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
                TimedOut = $false
            }
        }
        Mock Write-PreCommitCapturedOutput {}

        $repairResult = Invoke-PreCommitEnvironmentRepair -PreCommitExecutable "pre-commit" -RepositoryRoot $script:repoRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds 30
        $repairResult.Succeeded | Should -BeTrue
        $repairResult.ExitCode | Should -Be 0
        @($script:capturedPreCommitCommands.ToArray()) | Should -Be @("clean", "install-hooks")
        @($script:capturedRepairRoots.ToArray()) | Should -Be @($script:repoRoot, $script:repoRoot)
        @($script:capturedRepairTimeouts.ToArray()) | Should -Be @(30, 30)
        @($script:capturedRepairDeadlines.ToArray()) | Should -Be @($deadlineUtc, $deadlineUtc)
    }

    It "propagates clean timeout exit code from environment repair" {
        $deadlineUtc = [datetime]::UtcNow.AddSeconds(30)
        Mock Invoke-PreCommitCapturedCommand {
            return [pscustomobject]@{
                ExitCode = 124
                Stdout   = ""
                Stderr   = "E_PRECOMMIT_RECOVERY_TIMEOUT: pre-commit clean exceeded timeout."
                TimedOut = $true
            }
        }
        Mock Write-PreCommitCapturedOutput {}

        $repairResult = Invoke-PreCommitEnvironmentRepair -PreCommitExecutable "pre-commit" -RepositoryRoot $script:repoRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds 30

        $repairResult.Succeeded | Should -BeFalse
        $repairResult.ExitCode | Should -Be 124
    }

    It "propagates install-hooks timeout exit code from environment repair" {
        $script:repairCommandCount = 0
        $deadlineUtc = [datetime]::UtcNow.AddSeconds(30)
        Mock Invoke-PreCommitCapturedCommand {
            $script:repairCommandCount++
            if ($script:repairCommandCount -eq 1) {
                return [pscustomobject]@{
                    ExitCode = 0
                    Stdout   = ""
                    Stderr   = ""
                    TimedOut = $false
                }
            }

            return [pscustomobject]@{
                ExitCode = 124
                Stdout   = ""
                Stderr   = "E_PRECOMMIT_RECOVERY_TIMEOUT: pre-commit install-hooks exceeded timeout."
                TimedOut = $true
            }
        }
        Mock Write-PreCommitCapturedOutput {}

        $repairResult = Invoke-PreCommitEnvironmentRepair -PreCommitExecutable "pre-commit" -RepositoryRoot $script:repoRoot -DeadlineUtc $deadlineUtc -OverallTimeoutSeconds 30

        $repairResult.Succeeded | Should -BeFalse
        $repairResult.ExitCode | Should -Be 124
    }

    It "retries the original command once after successful repair" {
        $script:capturedRunCommands = New-Object System.Collections.Generic.List[string]
        $script:capturedRunRoots = New-Object System.Collections.Generic.List[string]
        $script:capturedRunTimeouts = New-Object System.Collections.Generic.List[int]
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitEnvironmentRepair {
            return [pscustomobject]@{
                Succeeded = $true
                ExitCode   = 0
            }
        }
        Mock Invoke-PreCommitCapturedCommand {
            param($PreCommitExecutable, $Arguments, $RepositoryRoot, $DeadlineUtc, $OverallTimeoutSeconds, $CommandContext)
            $script:capturedRunCommands.Add(($Arguments -join " ")) | Out-Null
            $script:capturedRunRoots.Add($RepositoryRoot) | Out-Null
            $script:capturedRunTimeouts.Add([int]$OverallTimeoutSeconds) | Out-Null
            if ($script:capturedRunCommands.Count -eq 1) {
                return [pscustomobject]@{
                    ExitCode = 1
                    Stdout   = "[INFO] Installing environment for https://github.com/example/hook."
                    Stderr   = "An unexpected error has occurred: CalledProcessError"
                    TimedOut = $false
                }
            }

            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
                TimedOut = $false
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 0
        @($script:capturedRunCommands.ToArray()).Count | Should -Be 2
        @($script:capturedRunRoots.ToArray()) | Should -Be @($script:repoRoot, $script:repoRoot)
        @($script:capturedRunTimeouts.ToArray()) | Should -Be @(30, 30)
    }

    It "starts the overall deadline before setup probes" {
        $script:capturedCommandRemainingMilliseconds = 0
        Mock Get-PreCommitRecoveryGitExecutableOrThrow { return "git" }
        Mock Resolve-PreCommitRecoveryRepositoryRootOrThrow {
            Start-Sleep -Milliseconds 1200
            return $script:repoRoot
        }
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitCapturedCommand {
            param($PreCommitExecutable, $Arguments, $RepositoryRoot, $DeadlineUtc, $OverallTimeoutSeconds, $CommandContext)

            $script:capturedCommandRemainingMilliseconds = [int][math]::Floor(($DeadlineUtc - [datetime]::UtcNow).TotalMilliseconds)
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
                TimedOut = $false
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 0

        $script:capturedCommandRemainingMilliseconds | Should -BeLessThan 29500
    }

    It "returns timeout exit code when setup version probe times out" {
        Mock Get-PreCommitRecoveryGitExecutableOrThrow { return "git" }
        Mock Resolve-PreCommitRecoveryRepositoryRootOrThrow { return $script:repoRoot }
        Mock Get-PreCommitExecutableOrThrow { throw "E_VALIDATION_PRECOMMIT_VERSION_TIMEOUT: pre-commit --version exceeded 30s." }
        Mock Invoke-PreCommitCapturedCommand { throw "pre-commit command should not run after setup timeout" }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 124
    }

    It "caps pre-commit version probe timeout to helper range" {
        $script:capturedVersionProbeTimeout = 0
        Mock Get-Command {
            return [pscustomobject]@{
                Source = "pre-commit"
            }
        } -ParameterFilter { $Name -eq "pre-commit" }
        Mock Assert-PreCommitCliVersion {
            param($PreCommitExecutable, $RepositoryRoot, $TimeoutSeconds)

            $script:capturedVersionProbeTimeout = [int]$TimeoutSeconds
            return [pscustomobject]@{
                ExpectedVersion = "4.6.0"
                ActualVersion   = "4.6.0"
                Executable      = $PreCommitExecutable
            }
        }

        Get-PreCommitExecutableOrThrow -RepositoryRoot $script:repoRoot -DeadlineUtc ([datetime]::UtcNow.AddSeconds(500)) -OverallTimeoutSeconds 500 |
            Should -Be "pre-commit"

        $script:capturedVersionProbeTimeout | Should -Be 120
    }

    It "returns environment repair timeout exit code from main" {
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitCapturedCommand {
            return [pscustomobject]@{
                ExitCode = 1
                Stdout   = "[INFO] Installing environment for https://github.com/example/hook."
                Stderr   = "An unexpected error has occurred: CalledProcessError"
                TimedOut = $false
            }
        }
        Mock Invoke-PreCommitEnvironmentRepair {
            return [pscustomobject]@{
                Succeeded = $false
                ExitCode   = 124
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 124
    }

    It "preserves non-environment hook exit codes without repair" {
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Invoke-PreCommitEnvironmentRepair { throw "repair should not run" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitCapturedCommand {
            return [pscustomobject]@{
                ExitCode = 7
                Stdout   = "hook id: powershell-format"
                Stderr   = "formatting failed"
                TimedOut = $false
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 7
    }

    It "preserves timeout exits without environment repair" {
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Invoke-PreCommitEnvironmentRepair { throw "repair should not run for timeout exits" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitCapturedCommand {
            return [pscustomobject]@{
                ExitCode = 124
                Stdout   = ""
                Stderr   = "E_PRECOMMIT_RECOVERY_TIMEOUT: pre-commit command exceeded 30s."
                TimedOut = $true
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 124
        Assert-MockCalled -CommandName Invoke-PreCommitEnvironmentRepair -Times 0 -Exactly
    }

    It "recovers from git index lock failures before environment repair" {
        $script:capturedRunCommands = New-Object System.Collections.Generic.List[string]
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitEnvironmentRepair { throw "environment repair should not run for index lock recovery" }
        Mock Invoke-SafeGitIndexLockRecovery {
            return [pscustomobject]@{
                Recovered            = $true
                SkippedReason        = ""
                ErrorMessage         = ""
                LockPath             = "/tmp/repo/.git/index.lock"
                LockAgeSeconds       = 42
                ActiveGitProcessCount = 0
                ProcessScanDegraded  = $false
                ElapsedMilliseconds  = 4
                SlowPathThresholdMs  = 250
            }
        }
        Mock Invoke-PreCommitCapturedCommand {
            param($PreCommitExecutable, $Arguments, $RepositoryRoot, $DeadlineUtc, $OverallTimeoutSeconds, $CommandContext)

            $script:capturedRunCommands.Add(($Arguments -join " ")) | Out-Null
            if ($script:capturedRunCommands.Count -eq 1) {
                return [pscustomobject]@{
                    ExitCode = 1
                    Stdout   = ""
                    Stderr   = "fatal: Unable to create '/tmp/repo/.git/index.lock': File exists.`nAnother git process seems to be running in this repository"
                    TimedOut = $false
                }
            }

            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
                TimedOut = $false
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 0

        Assert-MockCalled -CommandName Invoke-SafeGitIndexLockRecovery -Times 1 -Exactly
        @($script:capturedRunCommands.ToArray()).Count | Should -Be 2
    }

    It "returns retry exit code when git index lock persists after recovery" {
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitEnvironmentRepair { throw "environment repair should not run for index lock recovery" }
        Mock Invoke-SafeGitIndexLockRecovery {
            return [pscustomobject]@{
                Recovered            = $true
                SkippedReason        = ""
                ErrorMessage         = ""
                LockPath             = "/tmp/repo/.git/index.lock"
                LockAgeSeconds       = 42
                ActiveGitProcessCount = 0
                ProcessScanDegraded  = $false
                ElapsedMilliseconds  = 5
                SlowPathThresholdMs  = 250
            }
        }
        Mock Invoke-PreCommitCapturedCommand {
            return [pscustomobject]@{
                ExitCode = 23
                Stdout   = ""
                Stderr   = "fatal: Unable to create '/tmp/repo/.git/index.lock': File exists.`nAnother git process seems to be running in this repository"
                TimedOut = $false
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 23

        Assert-MockCalled -CommandName Invoke-SafeGitIndexLockRecovery -Times 1 -Exactly
        Assert-MockCalled -CommandName Invoke-PreCommitEnvironmentRepair -Times 0 -Exactly
    }

    It "passes explicit repository root to index-lock recovery from a different working directory" {
        $script:capturedRecoveryRoot = ""
        $script:capturedRecoveryGit = ""
        $deadlineUtc = [datetime]::UtcNow.AddSeconds(30)
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-SafeGitIndexLockRecovery {
            param($GitExecutable, $RepositoryRoot, $OutputLines, $Context)

            $script:capturedRecoveryGit = $GitExecutable
            $script:capturedRecoveryRoot = $RepositoryRoot
            return [pscustomobject]@{
                Recovered            = $false
                SkippedReason        = "lock_too_new"
                ErrorMessage         = ""
                LockPath             = "/tmp/repo/.git/index.lock"
                LockAgeSeconds       = 1
                ActiveGitProcessCount = 0
                ProcessScanDegraded  = $false
                ElapsedMilliseconds  = 5
                SlowPathThresholdMs  = 250
            }
        }

        Push-Location -LiteralPath $TestDrive
        try {
            $result = Invoke-PreCommitIndexLockRecovery `
                -Result ([pscustomobject]@{
                    ExitCode = 1
                    Stdout   = ""
                    Stderr   = "fatal: Unable to create '/tmp/repo/.git/index.lock': File exists.`nAnother git process seems to be running in this repository"
                    TimedOut = $false
                }) `
                -PreCommitExecutable "pre-commit" `
                -Arguments @("run", "--hook-stage", "pre-commit") `
                -GitExecutable "git" `
                -RepositoryRoot $script:repoRoot `
                -DeadlineUtc $deadlineUtc `
                -OverallTimeoutSeconds 30
        }
        finally {
            Pop-Location
        }

        $result.Handled | Should -BeTrue
        $script:capturedRecoveryGit | Should -Be "git"
        $script:capturedRecoveryRoot | Should -Be $script:repoRoot
    }
}
