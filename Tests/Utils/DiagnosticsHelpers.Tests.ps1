Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:diagnosticsHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/DiagnosticsHelpers.ps1"
    . $script:diagnosticsHelperPath
}

Describe "Invoke-SafeGitIndexLockRecovery" {
    BeforeEach {
        $script:envSnapshot = @{
            Mode        = $env:WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE
            Stale       = $env:WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS
            AllowActive = $env:WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT
            SlowPath    = $env:WALLSTOP_GIT_INDEX_LOCK_SLOW_PATH_MS
        }
    }

    AfterEach {
        $env:WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE = $script:envSnapshot.Mode
        $env:WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS = $script:envSnapshot.Stale
        $env:WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT = $script:envSnapshot.AllowActive
        $env:WALLSTOP_GIT_INDEX_LOCK_SLOW_PATH_MS = $script:envSnapshot.SlowPath
    }

    It "resolves relative lock paths against repository root and recovers stale locks" {
        $env:WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE = "safe"
        $env:WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS = "5"
        $env:WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT = "0"

        $script:testRepoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        $gitDirectoryPath = Join-Path -Path $script:testRepoRoot -ChildPath ".git"
        [void][System.IO.Directory]::CreateDirectory($gitDirectoryPath)

        $lockPath = Join-Path -Path $gitDirectoryPath -ChildPath "index.lock"
        Set-Content -LiteralPath $lockPath -Value "lock" -NoNewline
        (Get-Item -LiteralPath $lockPath -ErrorAction Stop).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-120)

        Mock git {
            $global:LASTEXITCODE = 0
            $joinedArgs = $args -join " "
            if ($joinedArgs -match "--git-path index.lock") {
                return @(".git/index.lock")
            }

            if ($joinedArgs -match "--absolute-git-dir") {
                return @((Join-Path -Path $script:testRepoRoot -ChildPath ".git"))
            }

            return @()
        }

        Mock Get-ActiveGitProcessScanState {
            return [pscustomobject]@{
                ActiveGitProcessCount = 0
                ProcessScanDegraded   = $false
            }
        }

        $result = Invoke-SafeGitIndexLockRecovery -GitExecutable "git" -RepositoryRoot $script:testRepoRoot -OutputLines @("fatal: Unable to create '.git/index.lock': File exists.") -Context "unit-test"

        $result.Recovered | Should -BeTrue
        $result.LockPath | Should -Be ([System.IO.Path]::GetFullPath($lockPath))
        Test-Path -LiteralPath $lockPath -PathType Leaf | Should -BeFalse
        Assert-MockCalled -CommandName Get-ActiveGitProcessScanState -Times 1 -Exactly
    }

    It "fails closed when process scan is degraded and active-git override is disabled" {
        $env:WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE = "safe"
        $env:WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS = "5"
        $env:WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT = "0"

        $script:testRepoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        $gitDirectoryPath = Join-Path -Path $script:testRepoRoot -ChildPath ".git"
        [void][System.IO.Directory]::CreateDirectory($gitDirectoryPath)

        $lockPath = Join-Path -Path $gitDirectoryPath -ChildPath "index.lock"
        Set-Content -LiteralPath $lockPath -Value "lock" -NoNewline
        (Get-Item -LiteralPath $lockPath -ErrorAction Stop).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-120)

        Mock git {
            $global:LASTEXITCODE = 0
            $joinedArgs = $args -join " "
            if ($joinedArgs -match "--git-path index.lock") {
                return @(".git/index.lock")
            }

            if ($joinedArgs -match "--absolute-git-dir") {
                return @((Join-Path -Path $script:testRepoRoot -ChildPath ".git"))
            }

            return @()
        }

        Mock Get-ActiveGitProcessScanState {
            return [pscustomobject]@{
                ActiveGitProcessCount = -1
                ProcessScanDegraded   = $true
            }
        }

        $result = Invoke-SafeGitIndexLockRecovery -GitExecutable "git" -RepositoryRoot $script:testRepoRoot -OutputLines @("fatal: Unable to create '.git/index.lock': File exists.") -Context "unit-test"

        $result.Recovered | Should -BeFalse
        $result.SkippedReason | Should -Be "process_scan_degraded"
        $result.ProcessScanDegraded | Should -BeTrue
        Test-Path -LiteralPath $lockPath -PathType Leaf | Should -BeTrue
        Assert-MockCalled -CommandName Get-ActiveGitProcessScanState -Times 1 -Exactly
    }

    It "skips recovery when lock file cannot be opened exclusively" {
        $env:WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE = "safe"
        $env:WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS = "5"
        $env:WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT = "0"

        $script:testRepoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        $gitDirectoryPath = Join-Path -Path $script:testRepoRoot -ChildPath ".git"
        [void][System.IO.Directory]::CreateDirectory($gitDirectoryPath)

        $lockPath = Join-Path -Path $gitDirectoryPath -ChildPath "index.lock"
        Set-Content -LiteralPath $lockPath -Value "lock" -NoNewline
        (Get-Item -LiteralPath $lockPath -ErrorAction Stop).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-120)

        Mock git {
            $global:LASTEXITCODE = 0
            $joinedArgs = $args -join " "
            if ($joinedArgs -match "--git-path index.lock") {
                return @(".git/index.lock")
            }

            if ($joinedArgs -match "--absolute-git-dir") {
                return @((Join-Path -Path $script:testRepoRoot -ChildPath ".git"))
            }

            return @()
        }

        Mock Get-ActiveGitProcessScanState {
            return [pscustomobject]@{
                ActiveGitProcessCount = 0
                ProcessScanDegraded   = $false
            }
        }

        $heldStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $result = Invoke-SafeGitIndexLockRecovery -GitExecutable "git" -RepositoryRoot $script:testRepoRoot -OutputLines @("fatal: Unable to create '.git/index.lock': File exists.") -Context "unit-test"

            $result.Recovered | Should -BeFalse
            $result.SkippedReason | Should -Be "lock_in_use"
            Test-Path -LiteralPath $lockPath -PathType Leaf | Should -BeTrue
            Assert-MockCalled -CommandName Get-ActiveGitProcessScanState -Times 1 -Exactly
        }
        finally {
            $heldStream.Dispose()
        }
    }

    It "records elapsed timing metadata on non-recovered paths" {
        $env:WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE = "safe"
        $env:WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS = "3600"
        $env:WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT = "0"

        $script:testRepoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        $gitDirectoryPath = Join-Path -Path $script:testRepoRoot -ChildPath ".git"
        [void][System.IO.Directory]::CreateDirectory($gitDirectoryPath)

        $lockPath = Join-Path -Path $gitDirectoryPath -ChildPath "index.lock"
        Set-Content -LiteralPath $lockPath -Value "lock" -NoNewline

        Mock git {
            $global:LASTEXITCODE = 0
            $joinedArgs = $args -join " "
            if ($joinedArgs -match "--git-path index.lock") {
                return @(".git/index.lock")
            }

            if ($joinedArgs -match "--absolute-git-dir") {
                return @((Join-Path -Path $script:testRepoRoot -ChildPath ".git"))
            }

            return @()
        }

        Mock Get-ActiveGitProcessScanState {
            return [pscustomobject]@{
                ActiveGitProcessCount = 0
                ProcessScanDegraded   = $false
            }
        }

        $result = Invoke-SafeGitIndexLockRecovery -GitExecutable "git" -RepositoryRoot $script:testRepoRoot -OutputLines @("fatal: Unable to create '.git/index.lock': File exists.") -Context "unit-test"

        $result.Recovered | Should -BeFalse
        $result.SkippedReason | Should -Be "lock_too_new"
        $result.ElapsedMilliseconds | Should -BeGreaterOrEqual 100
    }
}
