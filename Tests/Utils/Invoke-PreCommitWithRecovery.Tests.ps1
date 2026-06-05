Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:preCommitRecoveryScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1"
    . $script:preCommitRecoveryScriptPath -NoInvokeMain

    function New-TestAutofixGitRepository {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RootPath,

            [Parameter(Mandatory = $true)]
            [string]$GitExecutable
        )

        [void][System.IO.Directory]::CreateDirectory($RootPath)
        $initOutput = @(& $GitExecutable -C $RootPath init 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ("git init should succeed. Output: {0}" -f ($initOutput -join "`n"))

        $configNameOutput = @(& $GitExecutable -C $RootPath config user.name "Wallstop Test" 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ("git config user.name should succeed. Output: {0}" -f ($configNameOutput -join "`n"))

        $configEmailOutput = @(& $GitExecutable -C $RootPath config user.email "wallstop-test@example.invalid" 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ("git config user.email should succeed. Output: {0}" -f ($configEmailOutput -join "`n"))
    }

    function Set-TestAutofixFileContent {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepositoryRoot,

            [Parameter(Mandatory = $true)]
            [string]$RelativePath,

            [Parameter(Mandatory = $true)]
            [string]$Content
        )

        $targetPath = Join-Path -Path $RepositoryRoot -ChildPath $RelativePath
        $parentPath = [System.IO.Path]::GetDirectoryName($targetPath)
        if (-not [string]::IsNullOrWhiteSpace($parentPath)) {
            [void][System.IO.Directory]::CreateDirectory($parentPath)
        }

        [System.IO.File]::WriteAllText($targetPath, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function Invoke-TestGitOrThrow {
        param(
            [Parameter(Mandatory = $true)]
            [string]$GitExecutable,

            [Parameter(Mandatory = $true)]
            [string]$RepositoryRoot,

            [Parameter(Mandatory = $true)]
            [string[]]$Arguments,

            [Parameter(Mandatory = $false)]
            [string]$Context = "git command"
        )

        $output = @(& $GitExecutable -C $RepositoryRoot @Arguments 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ("{0} should succeed. Output: {1}" -f $Context, ($output -join "`n"))
        return @($output)
    }

    function Initialize-TestAutofixCommittedFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$GitExecutable,

            [Parameter(Mandatory = $true)]
            [string]$RepositoryRoot,

            [Parameter(Mandatory = $true)]
            [string]$RelativePath
        )

        Set-TestAutofixFileContent -RepositoryRoot $RepositoryRoot -RelativePath $RelativePath -Content "Write-Host 'initial'`n"
        [void](Invoke-TestGitOrThrow -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("add", "--", $RelativePath) -Context "initial git add")
        [void](Invoke-TestGitOrThrow -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("commit", "-m", "initial") -Context "initial git commit")
    }
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
        Test-PreCommitAutofixFailure -Result $result | Should -BeTrue
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

    It "uses shared index-lock recovery for autofix git commands" {
        $script:rawGitInvocationCount = 0
        Mock Invoke-PreCommitRecoveryRawGitCommand {
            $script:rawGitInvocationCount++
            if ($script:rawGitInvocationCount -eq 1) {
                return [pscustomobject]@{
                    ExitCode = 1
                    Stdout   = ""
                    Stderr   = "fatal: Unable to create '/tmp/repo/.git/index.lock': File exists."
                    TimedOut = $false
                }
            }

            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "Scripts/Utils/example.ps1`n"
                Stderr   = ""
                TimedOut = $false
            }
        }
        Mock Invoke-SafeGitIndexLockRecovery {
            return [pscustomobject]@{
                Recovered            = $true
                SkippedReason        = ""
                ErrorMessage         = ""
                LockPath             = "/tmp/repo/.git/index.lock"
                LockAgeSeconds       = 30
                ActiveGitProcessCount = 0
                ProcessScanDegraded  = $false
                ElapsedMilliseconds  = 4
                SlowPathThresholdMs  = 250
            }
        }

        $result = Invoke-PreCommitRecoveryGitCommand -GitExecutable "git" -RepositoryRoot "/tmp/repo" -Arguments @("diff", "--name-only") -CommandContext "pre-commit autofix test"

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be "Scripts/Utils/example.ps1`n"
        $script:rawGitInvocationCount | Should -Be 2
        Assert-MockCalled -CommandName Invoke-SafeGitIndexLockRecovery -Times 1 -Exactly
    }

    It "auto-restages formatter-updated clean staged files and retries once" {
        $script:capturedRunCommands = New-Object System.Collections.Generic.List[string]
        $script:capturedGitCommands = New-Object System.Collections.Generic.List[string]
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Get-PreCommitAutofixSnapshot {
            return [pscustomobject]@{
                Enabled             = $true
                StagedFiles         = @("Scripts/Utils/example.ps1")
                UnstagedStagedFiles = @()
            }
        }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitRecoveryGitCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments, $TimeoutSeconds, $CommandContext)
            $script:capturedGitCommands.Add(($Arguments -join " ")) | Out-Null
            if ($Arguments[0] -eq "diff") {
                return [pscustomobject]@{
                    ExitCode = 0
                    Stdout   = "Scripts/Utils/example.ps1`n"
                    Stderr   = ""
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
        Mock Invoke-PreCommitCapturedCommand {
            param($PreCommitExecutable, $Arguments, $RepositoryRoot, $DeadlineUtc, $OverallTimeoutSeconds, $CommandContext)
            $script:capturedRunCommands.Add($CommandContext) | Out-Null
            if ($script:capturedRunCommands.Count -eq 1) {
                return [pscustomobject]@{
                    ExitCode = 1
                    Stdout   = "files were modified by this hook"
                    Stderr   = ""
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

        @($script:capturedRunCommands.ToArray()) | Should -Be @("initial pre-commit run", "autofix restage retry")
        @($script:capturedGitCommands.ToArray()) | Should -Contain "add -- Scripts/Utils/example.ps1"
    }

    It "does not auto-restage formatter output over pre-existing unstaged edits" {
        $script:capturedGitCommands = New-Object System.Collections.Generic.List[string]
        Mock Get-PreCommitExecutableOrThrow { return "pre-commit" }
        Mock Get-PreCommitAutofixSnapshot {
            return [pscustomobject]@{
                Enabled             = $true
                StagedFiles         = @("Scripts/Utils/example.ps1")
                UnstagedStagedFiles = @("Scripts/Utils/example.ps1")
            }
        }
        Mock Write-PreCommitCapturedOutput {}
        Mock Invoke-PreCommitRecoveryGitCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments, $TimeoutSeconds, $CommandContext)
            $script:capturedGitCommands.Add(($Arguments -join " ")) | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "Scripts/Utils/example.ps1`n"
                Stderr   = ""
                TimedOut = $false
            }
        }
        Mock Invoke-PreCommitCapturedCommand {
            return [pscustomobject]@{
                ExitCode = 1
                Stdout   = "files were modified by this hook"
                Stderr   = ""
                TimedOut = $false
            }
        }

        Invoke-PreCommitWithRecoveryMain -Stage pre-commit -UseAllFiles:$false -OnlyInstallHooks:$false -MaximumRepairAttempts 1 -CommandTimeoutSeconds 30 |
            Should -Be 1

        @($script:capturedGitCommands.ToArray()) | Should -Not -Contain "add -- Scripts/Utils/example.ps1"
    }

    It "restages real formatter output only when the staged file had no pre-existing unstaged drift" {
        $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) {
            Set-ItResult -Skipped -Because "git is not available on PATH."
            return
        }

        $repositoryRoot = Join-Path -Path $TestDrive -ChildPath "autofix-clean"
        $relativePath = "Scripts/Utils/example.ps1"
        New-TestAutofixGitRepository -RootPath $repositoryRoot -GitExecutable $gitCommand.Source
        Initialize-TestAutofixCommittedFile -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -RelativePath $relativePath

        Set-TestAutofixFileContent -RepositoryRoot $repositoryRoot -RelativePath $relativePath -Content "Write-Host 'staged'`n"
        [void](Invoke-TestGitOrThrow -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -Arguments @("add", "--", $relativePath) -Context "stage changed file")
        $snapshot = Get-PreCommitAutofixSnapshot -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -DeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -OverallTimeoutSeconds 30
        Set-TestAutofixFileContent -RepositoryRoot $repositoryRoot -RelativePath $relativePath -Content "Write-Host 'formatted'`n"

        Mock Invoke-PreCommitCapturedCommand {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
                TimedOut = $false
            }
        }
        Mock Write-PreCommitCapturedOutput {}

        $result = Invoke-PreCommitAutofixRecovery -Result ([pscustomobject]@{
                ExitCode = 1
                Stdout   = "files were modified by this hook"
                Stderr   = ""
                TimedOut = $false
            }) -PreCommitExecutable "pre-commit" -Arguments @("run") -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -DeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -OverallTimeoutSeconds 30 -Snapshot $snapshot

        $result.Handled | Should -BeTrue
        $result.ExitCode | Should -Be 0
        @(Invoke-TestGitOrThrow -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -Arguments @("diff", "--name-only", "--", $relativePath) -Context "post-restage unstaged diff").Count | Should -Be 0
        $cachedContent = Invoke-TestGitOrThrow -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -Arguments @("show", ":$relativePath") -Context "post-restage cached content"
        ($cachedContent -join "`n") | Should -Match "formatted"
    }

    It "refuses real autofix restage when any staged target had pre-existing unstaged drift" {
        $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) {
            Set-ItResult -Skipped -Because "git is not available on PATH."
            return
        }

        $repositoryRoot = Join-Path -Path $TestDrive -ChildPath "autofix-dirty"
        $cleanRelativePath = "Scripts/Utils/clean.ps1"
        $dirtyRelativePath = "Scripts/Utils/dirty.ps1"
        New-TestAutofixGitRepository -RootPath $repositoryRoot -GitExecutable $gitCommand.Source
        Initialize-TestAutofixCommittedFile -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -RelativePath $cleanRelativePath
        Initialize-TestAutofixCommittedFile -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -RelativePath $dirtyRelativePath

        Set-TestAutofixFileContent -RepositoryRoot $repositoryRoot -RelativePath $cleanRelativePath -Content "Write-Host 'clean staged'`n"
        Set-TestAutofixFileContent -RepositoryRoot $repositoryRoot -RelativePath $dirtyRelativePath -Content "Write-Host 'dirty staged'`n"
        [void](Invoke-TestGitOrThrow -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -Arguments @("add", "--", $cleanRelativePath, $dirtyRelativePath) -Context "stage changed files")
        Set-TestAutofixFileContent -RepositoryRoot $repositoryRoot -RelativePath $dirtyRelativePath -Content "Write-Host 'dirty unstaged before hook'`n"
        $snapshot = Get-PreCommitAutofixSnapshot -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -DeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -OverallTimeoutSeconds 30
        Set-TestAutofixFileContent -RepositoryRoot $repositoryRoot -RelativePath $cleanRelativePath -Content "Write-Host 'clean formatted'`n"

        Mock Invoke-PreCommitCapturedCommand { throw "retry should not run when pre-existing unstaged drift blocks auto-restage" }

        $result = Invoke-PreCommitAutofixRecovery -Result ([pscustomobject]@{
                ExitCode = 1
                Stdout   = "files were modified by this hook"
                Stderr   = ""
                TimedOut = $false
            }) -PreCommitExecutable "pre-commit" -Arguments @("run") -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -DeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -OverallTimeoutSeconds 30 -Snapshot $snapshot

        $result.Handled | Should -BeTrue
        $result.ExitCode | Should -Be 1
        $cleanCachedContent = Invoke-TestGitOrThrow -GitExecutable $gitCommand.Source -RepositoryRoot $repositoryRoot -Arguments @("show", ":$cleanRelativePath") -Context "blocked clean cached content"
        ($cleanCachedContent -join "`n") | Should -Match "clean staged"
        ($cleanCachedContent -join "`n") | Should -Not -Match "clean formatted"
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
