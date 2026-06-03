Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/PreCommitCliHelpers.ps1"
    . $script:helperPath
}

Describe "PreCommitCliHelpers" {
    It "reads an exact pre-commit pin with comments and CRLF line endings" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $requirementsPath = Join-Path -Path $repoRoot -ChildPath "requirements.txt"
        [System.IO.File]::WriteAllText($requirementsPath, "pre-commit==4.6.0 # pinned`r`n", [System.Text.UTF8Encoding]::new($false))

        Get-RequiredPreCommitVersion -RepositoryRoot $repoRoot | Should -Be "4.6.0"
    }

    It "throws a stable diagnostic when requirements.txt is missing" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        { Get-RequiredPreCommitVersion -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_REQUIREMENTS_MISSING*"
    }

    It "throws a stable diagnostic when requirements.txt lacks an exact pre-commit pin" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $requirementsPath = Join-Path -Path $repoRoot -ChildPath "requirements.txt"
        [System.IO.File]::WriteAllText($requirementsPath, "pre-commit>=4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        { Get-RequiredPreCommitVersion -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_REQUIREMENTS_INVALID*"
    }

    It "returns fallback bootstrap guidance when the pre-commit pin cannot be resolved" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        $guidance = Get-PreCommitBootstrapVersionGuidance -RepositoryRoot $repoRoot

        $guidance.Version | Should -Be "<pinned-version-from-requirements.txt>"
        $guidance.IsFallback | Should -BeTrue
        $guidance.RequirementsDiagnostic | Should -Match "E_VALIDATION_PRECOMMIT_REQUIREMENTS_MISSING"
    }

    It "returns exact bootstrap guidance when the pre-commit pin can be resolved" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $requirementsPath = Join-Path -Path $repoRoot -ChildPath "requirements.txt"
        [System.IO.File]::WriteAllText($requirementsPath, "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        $guidance = Get-PreCommitBootstrapVersionGuidance -RepositoryRoot $repoRoot

        $guidance.Version | Should -Be "4.6.0"
        $guidance.IsFallback | Should -BeFalse
        $guidance.RequirementsDiagnostic | Should -Be ""
    }

    It "accepts a matching pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "pre-commit 4.6.0"
                Stderr   = ""
            }
        }

        $result = Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot

        $result.ExpectedVersion | Should -Be "4.6.0"
        $result.ActualVersion | Should -Be "4.6.0"
    }

    It "passes explicit timeout to the pre-commit version probe" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))
        $script:capturedVersionProbeTimeout = 0

        Mock Invoke-PreCommitVersionProbe {
            param($PreCommitExecutable, $RepositoryRoot, $TimeoutSeconds)

            $script:capturedVersionProbeTimeout = [int]$TimeoutSeconds
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "pre-commit 4.6.0"
                Stderr   = ""
            }
        }

        [void](Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot -TimeoutSeconds 17)

        $script:capturedVersionProbeTimeout | Should -Be 17
    }

    It "rejects a mismatching pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "pre-commit 4.5.0"
                Stderr   = ""
            }
        }

        { Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_VERSION_MISMATCH*"
    }

    It "rejects an unparseable pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "unexpected version output"
                Stderr   = ""
            }
        }

        { Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_VERSION_PARSE_FAILED*"
    }

    It "rejects a nonzero pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 2
                Stdout   = ""
                Stderr   = "failed"
            }
        }

        { Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_VERSION_FAILED*"
    }
}
