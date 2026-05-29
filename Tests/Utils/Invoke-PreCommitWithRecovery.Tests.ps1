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
}
