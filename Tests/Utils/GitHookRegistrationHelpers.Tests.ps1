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

        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        $hookRoot = Join-Path -Path $repoRoot -ChildPath ".githooks"
        [System.IO.Directory]::CreateDirectory($hookRoot) | Out-Null
        $hookPath = Join-Path -Path $hookRoot -ChildPath "pre-commit"
        [System.IO.File]::WriteAllText($hookPath, "#!/usr/bin/env bash`n", [System.Text.UTF8Encoding]::new($false))
        chmod 755 $hookPath

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
        chmod 644 $hookPath

        Mock Get-Item { return [pscustomobject]@{} }

        { Assert-GitHookRegistrationWrapper -RepositoryRoot $repoRoot -HookName "pre-commit" } |
            Should -Throw -ExpectedMessage "*E_HOOK_REGISTRATION_WRAPPER_NOT_EXECUTABLE*"
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
}
