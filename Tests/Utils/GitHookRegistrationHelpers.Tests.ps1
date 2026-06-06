Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/GitHookRegistrationHelpers.ps1"
    . $script:helperPath
}

Describe "Git hook registration preflight" {
    It "falls back to test -x when UnixMode metadata is unavailable" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "Executable-bit fallback applies only on non-Windows platforms."
            return
        }

        $chmodCommand = @(Get-Command -Name "chmod" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($null -eq $chmodCommand) {
            Set-ItResult -Skipped -Because "chmod is unavailable for executable-bit setup."
            return
        }

        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        $hookRoot = Join-Path -Path $repoRoot -ChildPath ".githooks"
        [System.IO.Directory]::CreateDirectory($hookRoot) | Out-Null
        $hookPath = Join-Path -Path $hookRoot -ChildPath "pre-commit"
        [System.IO.File]::WriteAllText($hookPath, "#!/usr/bin/env bash`n", [System.Text.UTF8Encoding]::new($false))
        & $chmodCommand.Path 755 $hookPath

        Mock Get-Item { return [pscustomobject]@{} }

        { Assert-GitHookRegistrationWrapper -RepositoryRoot $repoRoot -HookName "pre-commit" } |
            Should -Not -Throw
    }

    It "reports a stable diagnostic when UnixMode metadata is unavailable and the wrapper is not executable" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "Executable-bit fallback applies only on non-Windows platforms."
            return
        }

        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        $hookRoot = Join-Path -Path $repoRoot -ChildPath ".githooks"
        [System.IO.Directory]::CreateDirectory($hookRoot) | Out-Null
        $hookPath = Join-Path -Path $hookRoot -ChildPath "pre-commit"
        [System.IO.File]::WriteAllText($hookPath, "#!/usr/bin/env bash`n", [System.Text.UTF8Encoding]::new($false))
        $chmodCommand = @(Get-Command -Name "chmod" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($null -eq $chmodCommand) {
            Set-ItResult -Skipped -Because "chmod is unavailable for executable-bit setup."
            return
        }
        & $chmodCommand.Path 644 $hookPath

        Mock Get-Item { return [pscustomobject]@{} }

        { Assert-GitHookRegistrationWrapper -RepositoryRoot $repoRoot -HookName "pre-commit" } |
            Should -Throw -ExpectedMessage "*E_HOOK_REGISTRATION_WRAPPER_NOT_EXECUTABLE*"
    }

    It "ignores a shadowing PowerShell test function when using test -x fallback" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "Executable-bit fallback applies only on non-Windows platforms."
            return
        }

        $chmodCommand = @(Get-Command -Name "chmod" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        $testCommand = @(Get-Command -Name "test" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($null -eq $chmodCommand -or $null -eq $testCommand) {
            Set-ItResult -Skipped -Because "chmod or POSIX test is unavailable for executable-bit fallback setup."
            return
        }

        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        $hookRoot = Join-Path -Path $repoRoot -ChildPath ".githooks"
        [System.IO.Directory]::CreateDirectory($hookRoot) | Out-Null
        $hookPath = Join-Path -Path $hookRoot -ChildPath "pre-push"
        [System.IO.File]::WriteAllText($hookPath, "#!/usr/bin/env bash`n", [System.Text.UTF8Encoding]::new($false))
        & $chmodCommand.Path 755 $hookPath

        Mock Get-Item { return [pscustomobject]@{} }
        function test { throw "shadowed PowerShell test function should not be invoked" }

        try {
            { Assert-GitHookRegistrationWrapper -RepositoryRoot $repoRoot -HookName "pre-push" } |
                Should -Not -Throw
        }
        finally {
            Remove-Item -Path Function:test -ErrorAction SilentlyContinue
        }
    }

    It "repairs unset core.hooksPath with local .githooks config and verifies it" {
        $script:hookRegistrationCommands = New-Object System.Collections.Generic.List[string]

        Mock Get-GitHookRegistrationGitExecutableOrThrow { return "git" }
        Mock Resolve-GitHookRegistrationRepositoryRoot { return $script:repoRoot }
        Mock Assert-GitHookRegistrationWrapper {}
        Mock Invoke-GitHookRegistrationGitCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:hookRegistrationCommands.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "config --get core.hooksPath" {
                    if (@($script:hookRegistrationCommands.ToArray() | Where-Object { $_ -eq "config --get core.hooksPath" }).Count -eq 1) {
                        return [pscustomobject]@{ ExitCode = 1; Output = @() }
                    }

                    return [pscustomobject]@{ ExitCode = 0; Output = @(".githooks") }
                }
                "config --local core.hooksPath .githooks" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @() }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        $result = Assert-GitHookRegistration -RepositoryRoot $script:repoRoot -Repair

        $result.HooksPath | Should -Be ".githooks"
        @($script:hookRegistrationCommands.ToArray()) | Should -Contain "config --local core.hooksPath .githooks"
    }

    It "fails without repair when core.hooksPath is wrong" {
        Mock Get-GitHookRegistrationGitExecutableOrThrow { return "git" }
        Mock Resolve-GitHookRegistrationRepositoryRoot { return $script:repoRoot }
        Mock Assert-GitHookRegistrationWrapper {}
        Mock Invoke-GitHookRegistrationGitCommand {
            return [pscustomobject]@{ ExitCode = 0; Output = @("other-hooks") }
        }

        { Assert-GitHookRegistration -RepositoryRoot $script:repoRoot } |
            Should -Throw -ExpectedMessage "*E_HOOK_REGISTRATION_PATH_MISMATCH*"
    }

    It "uses stdout-only data when repository root discovery has stderr diagnostics" {
        Mock Invoke-GitHookRegistrationGitCommand {
            return [pscustomobject]@{
                ExitCode         = 0
                Output           = @($script:repoRoot)
                DiagnosticOutput = @("trace: rev-parse --show-toplevel", $script:repoRoot)
            }
        }

        $resolvedRoot = Resolve-GitHookRegistrationRepositoryRoot -GitExecutable "git" -RepositoryRoot $script:repoRoot

        $resolvedRoot | Should -Be $script:repoRoot
    }

    It "includes stderr diagnostics when repository root discovery fails" {
        Mock Invoke-GitHookRegistrationGitCommand {
            return [pscustomobject]@{
                ExitCode         = 128
                Output           = @()
                DiagnosticOutput = @("fatal: not a git repository")
            }
        }

        { Resolve-GitHookRegistrationRepositoryRoot -GitExecutable "git" -RepositoryRoot $TestDrive } |
            Should -Throw -ExpectedMessage "*fatal: not a git repository*"
    }
}
