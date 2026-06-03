Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:autoRepairScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PreCommitAutoRepair.ps1"
    . $script:autoRepairScriptPath -NoInvokeMain
}

Describe "Invoke-PreCommitAutoRepairMain" {
    It "skips when staged files contain no Windows language targets" {
        $script:gitCallCount = 0
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        Mock Get-GitExecutableOrThrow { return "git" }
        Mock Get-GitRepositoryRootOrThrow { return $repoRoot }
        Mock Invoke-GitCommandOrThrow {
            $script:gitCallCount += 1
            if ($script:gitCallCount -eq 1) {
                return @("README.md")
            }

            throw "unexpected git command invocation at call index $script:gitCallCount"
        }

        { Invoke-PreCommitAutoRepairMain } | Should -Not -Throw
        $script:gitCallCount | Should -Be 1
    }

    It "repairs and stages safe Windows language targets" {
        $script:gitCallIndex = 0
        $script:recordedGitArguments = New-Object System.Collections.Generic.List[string]
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        Mock Get-GitExecutableOrThrow { return "git" }
        Mock Get-GitRepositoryRootOrThrow { return $repoRoot }
        Mock Invoke-WindowsLanguageCheckerForAutoRepair {}
        Mock Invoke-GitCommandOrThrow {
            param($GitExecutable, $RepositoryRoot, $Arguments, $FailureCode, $FailureContext)

            $script:gitCallIndex += 1
            $script:recordedGitArguments.Add(($Arguments -join " ")) | Out-Null

            switch ($script:gitCallIndex) {
                1 { return @("Scripts/AutoHotKey/window-control.ahk") }
                2 { return @() }
                3 { return @("Scripts/AutoHotKey/window-control.ahk") }
                4 { return @() }
                default { throw "unexpected git command invocation at call index $script:gitCallIndex" }
            }
        }

        { Invoke-PreCommitAutoRepairMain } | Should -Not -Throw

        $script:gitCallIndex | Should -Be 4
        $script:recordedGitArguments[0] | Should -Match 'diff --cached --name-only --diff-filter=ACMR'
        $script:recordedGitArguments[1] | Should -Match 'diff --name-only -- Scripts/AutoHotKey/window-control\.ahk'
        $script:recordedGitArguments[2] | Should -Match 'diff --name-only -- Scripts/AutoHotKey/window-control\.ahk'
        $script:recordedGitArguments[3] | Should -Match 'add -- Scripts/AutoHotKey/window-control\.ahk'
        Assert-MockCalled -CommandName Invoke-WindowsLanguageCheckerForAutoRepair -Times 1 -Exactly -ParameterFilter {
            $RepositoryRoot -eq $repoRoot -and $RepairTargets.Count -eq 1 -and $RepairTargets[0] -eq 'Scripts/AutoHotKey/window-control.ahk'
        }
    }

    It "warns and skips auto-repair when all staged Windows targets have unstaged drift" {
        $script:gitCallCount = 0
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        Mock Get-GitExecutableOrThrow { return "git" }
        Mock Get-GitRepositoryRootOrThrow { return $repoRoot }
        Mock Write-Warning {}
        Mock Invoke-GitCommandOrThrow {
            $script:gitCallCount += 1
            switch ($script:gitCallCount) {
                1 { return @("Scripts/AutoHotKey/window-control.ahk") }
                2 { return @("Scripts/AutoHotKey/window-control.ahk") }
                default { throw "unexpected git command invocation at call index $script:gitCallCount" }
            }
        }

        { Invoke-PreCommitAutoRepairMain } | Should -Not -Throw

        $script:gitCallCount | Should -Be 2
        Assert-MockCalled -CommandName Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like "W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SKIPPED_UNSTAGED*"
        }
    }

    It "warns and skips config snapshot auto-repair when mapped source has unstaged drift" {
        $script:gitCallCount = 0
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        $sourceDirectory = Join-Path -Path $repoRoot -ChildPath "Scripts/AutoHotKey"
        [System.IO.Directory]::CreateDirectory($sourceDirectory) | Out-Null
        Set-Content -Path (Join-Path -Path $sourceDirectory -ChildPath "window-control.ahk") -Value "#Requires AutoHotkey v2.0" -NoNewline

        Mock Get-GitExecutableOrThrow { return "git" }
        Mock Get-GitRepositoryRootOrThrow { return $repoRoot }
        Mock Write-Warning {}
        Mock Invoke-WindowsLanguageCheckerForAutoRepair { throw "checker should not run when source is unstaged" }
        Mock Invoke-GitCommandOrThrow {
            $script:gitCallCount += 1
            switch ($script:gitCallCount) {
                1 { return @("Config/.config/window-control.ahk") }
                2 { return @() }
                3 { return @("Scripts/AutoHotKey/window-control.ahk") }
                default { throw "unexpected git command invocation at call index $script:gitCallCount" }
            }
        }

        { Invoke-PreCommitAutoRepairMain } | Should -Not -Throw

        $script:gitCallCount | Should -Be 3
        Assert-MockCalled -CommandName Invoke-WindowsLanguageCheckerForAutoRepair -Times 0 -Exactly
        Assert-MockCalled -CommandName Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like "W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SOURCE_UNSTAGED*"
        }
    }
}

Describe "Invoke-GitCommandOrThrow index lock recovery" {
    It "retries once after successful index lock recovery" {
        $script:gitInvocationCount = 0
        Mock Invoke-SafeGitIndexLockRecovery {
            return [pscustomobject]@{
                Recovered            = $true
                SkippedReason        = ""
                ErrorMessage         = ""
                LockPath             = "/tmp/repo/.git/index.lock"
                LockAgeSeconds       = 30
                ActiveGitProcessCount = 0
                ProcessScanDegraded  = $false
                ElapsedMilliseconds  = 7
                SlowPathThresholdMs  = 250
            }
        }

        Mock Get-LastExitCodeOrDefault {
            if ($script:gitInvocationCount -eq 1) {
                return 1
            }

            return 0
        }

        Mock -CommandName "git" {
            $script:gitInvocationCount += 1
            if ($script:gitInvocationCount -eq 1) {
                return @("fatal: Unable to create '/tmp/repo/.git/index.lock': File exists.")
            }

            return @("Scripts/AutoHotKey/window-control.ahk")
        }

        $output = Invoke-GitCommandOrThrow -GitExecutable "git" -RepositoryRoot "/tmp/repo" -Arguments @("diff", "--cached", "--name-only") -FailureCode "E_TEST" -FailureContext "test git command"
        $output | Should -Be @("Scripts/AutoHotKey/window-control.ahk")
        $script:gitInvocationCount | Should -Be 2
        Assert-MockCalled -CommandName Invoke-SafeGitIndexLockRecovery -Times 1 -Exactly
    }

    It "throws lock persisted code when index lock remains after retry" {
        $script:gitInvocationCount = 0
        Mock Invoke-SafeGitIndexLockRecovery {
            return [pscustomobject]@{
                Recovered            = $true
                SkippedReason        = ""
                ErrorMessage         = ""
                LockPath             = "/tmp/repo/.git/index.lock"
                LockAgeSeconds       = 30
                ActiveGitProcessCount = 0
                ProcessScanDegraded  = $false
                ElapsedMilliseconds  = 6
                SlowPathThresholdMs  = 250
            }
        }

        Mock Get-LastExitCodeOrDefault { return 1 }
        Mock -CommandName "git" {
            $script:gitInvocationCount += 1
            return @("fatal: Unable to create '/tmp/repo/.git/index.lock': File exists.")
        }

        {
            Invoke-GitCommandOrThrow -GitExecutable "git" -RepositoryRoot "/tmp/repo" -Arguments @("add", "--", "Scripts/AutoHotKey/window-control.ahk") -FailureCode "E_TEST" -FailureContext "test git add"
        } | Should -Throw "*E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED*"
        $script:gitInvocationCount | Should -Be 2
    }

    It "throws recovery failed code when lock recovery fails" {
        Mock Invoke-SafeGitIndexLockRecovery {
            return [pscustomobject]@{
                Recovered            = $false
                SkippedReason        = "recovery_failed"
                ErrorMessage         = "simulated remove failure"
                LockPath             = "/tmp/repo/.git/index.lock"
                LockAgeSeconds       = 44
                ActiveGitProcessCount = 0
                ProcessScanDegraded  = $false
                ElapsedMilliseconds  = 9
                SlowPathThresholdMs  = 250
            }
        }

        Mock Get-LastExitCodeOrDefault { return 1 }
        Mock -CommandName "git" {
            return @("fatal: Unable to create '/tmp/repo/.git/index.lock': File exists.")
        }

        {
            Invoke-GitCommandOrThrow -GitExecutable "git" -RepositoryRoot "/tmp/repo" -Arguments @("diff", "--cached", "--name-only") -FailureCode "E_TEST" -FailureContext "test git command"
        } | Should -Throw "*E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED*"
        Assert-MockCalled -CommandName Invoke-SafeGitIndexLockRecovery -Times 1 -Exactly
    }
}
