Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:preCommitRecoveryScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1"
    . $script:preCommitRecoveryScriptPath -NoInvokeMain
}

Describe "Invoke-PreCommitWithRecovery environment failure classification" {
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

    It "runs clean then install-hooks during environment repair" {
        $script:capturedPreCommitCommands = New-Object System.Collections.Generic.List[string]
        Mock Invoke-PreCommitCapturedCommand {
            param($PreCommitExecutable, $Arguments, $CommandTimeoutSeconds)
            $script:capturedPreCommitCommands.Add(($Arguments -join " ")) | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
                TimedOut = $false
            }
        }
        Mock Write-PreCommitCapturedOutput {}

        Invoke-PreCommitEnvironmentRepair -PreCommitExecutable "pre-commit" -CommandTimeoutSeconds 30 | Should -BeTrue
        @($script:capturedPreCommitCommands.ToArray()) | Should -Be @("clean", "install-hooks")
    }

    It "retries the original command once after successful repair" {
        $script:capturedRunCommands = New-Object System.Collections.Generic.List[string]
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitEnvironmentRepair { return $true }
        Mock Invoke-PreCommitCapturedCommand {
            param($PreCommitExecutable, $Arguments, $CommandTimeoutSeconds)
            $script:capturedRunCommands.Add(($Arguments -join " ")) | Out-Null
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
            param($PreCommitExecutable, $Arguments, $CommandTimeoutSeconds)

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
}
