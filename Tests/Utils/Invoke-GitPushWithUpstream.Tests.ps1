Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:pushScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-GitPushWithUpstream.ps1"
    . $script:pushScriptPath -NoInvokeMain
}

Describe "Invoke-GitPushWithUpstream" {
    BeforeEach {
        $script:gitPushCalls = New-Object System.Collections.Generic.List[string]
        Mock Get-GitPushGitExecutableOrThrow { return "git" }
        Mock Assert-GitHookRegistration {}
        Mock Write-GitPushCommandOutput {}
    }

    It "runs plain git push when an upstream exists" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("main") }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123") }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("origin/main") }
                }
                "push" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("pushed") }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot | Should -Be 0

        @($script:gitPushCalls.ToArray()) | Should -Contain "push"
        Assert-MockCalled -CommandName Assert-GitHookRegistration -Times 1 -Exactly
    }

    It "accepts an explicit remote when it matches the existing upstream remote" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("main") }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123") }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("origin/main") }
                }
                "config --get branch.main.remote" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("origin") }
                }
                "push origin HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("pushed") }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot -RemoteWasSpecified:$true | Should -Be 0

        @($script:gitPushCalls.ToArray()) | Should -Contain "config --get branch.main.remote"
        @($script:gitPushCalls.ToArray()) | Should -Contain "push origin HEAD"
        @($script:gitPushCalls.ToArray()) | Should -Not -Contain "push"
    }

    It "rejects an explicit remote that does not match the existing upstream remote" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("main") }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123") }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("fork/main") }
                }
                "config --get branch.main.remote" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("fork") }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        { Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot -RemoteWasSpecified:$true } |
            Should -Throw -ExpectedMessage "*E_GIT_PUSH_REMOTE_MISMATCH*"

        @($script:gitPushCalls.ToArray()) | Should -Not -Contain "push origin HEAD"
    }

    It "pushes with upstream when no upstream exists and the remote branch is absent" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 1; Output = @() }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("feature/test") }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123") }
                }
                "remote get-url origin" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("git@example.com:owner/repo.git") }
                }
                "ls-remote --heads origin feature/test" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @() }
                }
                "push -u origin HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("set upstream") }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot | Should -Be 0

        @($script:gitPushCalls.ToArray()) | Should -Contain "push -u origin HEAD"
    }

    It "fetches and sets upstream when the same-name remote branch is an ancestor of HEAD" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 1; Output = @() }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("feature/test") }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123") }
                }
                "remote get-url origin" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("git@example.com:owner/repo.git") }
                }
                "ls-remote --heads origin feature/test" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123`trefs/heads/feature/test") }
                }
                "fetch --no-tags origin +refs/heads/feature/test:refs/remotes/origin/feature/test" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @() }
                }
                "merge-base --is-ancestor refs/remotes/origin/feature/test HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @() }
                }
                "push -u origin HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("set upstream") }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot | Should -Be 0

        @($script:gitPushCalls.ToArray()) | Should -Contain "fetch --no-tags origin +refs/heads/feature/test:refs/remotes/origin/feature/test"
        @($script:gitPushCalls.ToArray()) | Should -Contain "push -u origin HEAD"
    }

    It "rejects a divergent same-name remote branch" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 1; Output = @() }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("feature/test") }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123") }
                }
                "remote get-url origin" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("git@example.com:owner/repo.git") }
                }
                "ls-remote --heads origin feature/test" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("def456`trefs/heads/feature/test") }
                }
                "fetch --no-tags origin +refs/heads/feature/test:refs/remotes/origin/feature/test" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @() }
                }
                "merge-base --is-ancestor refs/remotes/origin/feature/test HEAD" {
                    return [pscustomobject]@{ ExitCode = 1; Output = @() }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        { Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot } |
            Should -Throw -ExpectedMessage "*E_GIT_PUSH_REMOTE_BRANCH_DIVERGED*"

        @($script:gitPushCalls.ToArray()) | Should -Not -Contain "push -u origin HEAD"
    }

    It "rejects detached HEAD before selecting a remote push target" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 1; Output = @() }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 1; Output = @() }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        { Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot } |
            Should -Throw -ExpectedMessage "*E_GIT_PUSH_DETACHED_HEAD*"
    }

    It "rejects a missing remote before push -u" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @($script:repoRoot) }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{ ExitCode = 1; Output = @() }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("feature/test") }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("abc123") }
                }
                "remote get-url missing" {
                    return [pscustomobject]@{ ExitCode = 2; Output = @("error: No such remote 'missing'") }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        { Invoke-GitPushWithUpstreamMain -SelectedRemote missing -RequestedRepositoryRoot $script:repoRoot } |
            Should -Throw -ExpectedMessage "*E_GIT_PUSH_REMOTE_MISSING*"

        @($script:gitPushCalls.ToArray()) | Should -Not -Contain "push -u missing HEAD"
    }

    It "uses stdout-only data when git discovery commands include stderr diagnostics" {
        Mock Invoke-GitPushCommand {
            param($GitExecutable, $RepositoryRoot, $Arguments)
            $argumentText = $Arguments -join " "
            $script:gitPushCalls.Add($argumentText) | Out-Null

            switch ($argumentText) {
                "rev-parse --show-toplevel" {
                    return [pscustomobject]@{
                        ExitCode         = 0
                        Output           = @($script:repoRoot)
                        DiagnosticOutput = @("trace: rev-parse --show-toplevel", $script:repoRoot)
                    }
                }
                "rev-parse --abbrev-ref --symbolic-full-name @{u}" {
                    return [pscustomobject]@{
                        ExitCode         = 1
                        Output           = @()
                        DiagnosticOutput = @("fatal: no upstream configured")
                    }
                }
                "symbolic-ref --quiet --short HEAD" {
                    return [pscustomobject]@{
                        ExitCode         = 0
                        Output           = @("feature/test")
                        DiagnosticOutput = @("trace: symbolic-ref", "feature/test")
                    }
                }
                "rev-parse --verify HEAD" {
                    return [pscustomobject]@{
                        ExitCode         = 0
                        Output           = @("abc123")
                        DiagnosticOutput = @("trace: verify HEAD", "abc123")
                    }
                }
                "remote get-url origin" {
                    return [pscustomobject]@{
                        ExitCode         = 0
                        Output           = @("git@example.com:owner/repo.git")
                        DiagnosticOutput = @("trace: remote get-url", "git@example.com:owner/repo.git")
                    }
                }
                "ls-remote --heads origin feature/test" {
                    return [pscustomobject]@{
                        ExitCode         = 0
                        Output           = @()
                        DiagnosticOutput = @("trace: ls-remote")
                    }
                }
                "push -u origin HEAD" {
                    return [pscustomobject]@{ ExitCode = 0; Output = @("set upstream"); DiagnosticOutput = @("set upstream") }
                }
                default {
                    throw "unexpected git command: $argumentText"
                }
            }
        }

        Invoke-GitPushWithUpstreamMain -SelectedRemote origin -RequestedRepositoryRoot $script:repoRoot | Should -Be 0

        @($script:gitPushCalls.ToArray()) | Should -Contain "push -u origin HEAD"
    }
}
