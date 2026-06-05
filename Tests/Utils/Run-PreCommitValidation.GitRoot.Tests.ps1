Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
    $script:preCommitContent = (Get-Content -Path $script:preCommitPath -Raw) -replace "`r", ""

    $tokens = $null
    $parseErrors = $null
    $script:preCommitAst = [System.Management.Automation.Language.Parser]::ParseFile($script:preCommitPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "E_CONFIG_ERROR: Failed to parse Run-PreCommitValidation.ps1 for git-root tests."
    }

    function Get-RequiredFunctionDefinitionAst {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.Ast]$Ast,

            [Parameter(Mandatory = $true)]
            [string]$Name,

            [Parameter(Mandatory = $true)]
            [string]$Context
        )

        $matches = @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
                }, $true))

        if ($matches.Count -ne 1) {
            throw "E_CONFIG_ERROR: Expected exactly one function '$Name' for $Context; found $($matches.Count)."
        }

        return $matches[0]
    }

    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/DiagnosticsHelpers.ps1")

    foreach ($functionName in @("Get-LastNativeExitCodeOrDefault", "Invoke-GitCommandWithSplitOutput", "Join-GitCommandDiagnosticOutput", "Invoke-GitStdoutOrThrow", "Get-StagedFilesWithIndexLockRecoveryOrThrow")) {
        $targetFunction = Get-RequiredFunctionDefinitionAst -Ast $script:preCommitAst -Name $functionName -Context "git-root tests"

        . ([scriptblock]::Create($targetFunction.Extent.Text))
    }
}

AfterAll {
    Remove-Item -Path Function:Get-StagedFilesWithIndexLockRecoveryOrThrow -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Invoke-GitStdoutOrThrow -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Join-GitCommandDiagnosticOutput -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Invoke-GitCommandWithSplitOutput -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-LastNativeExitCodeOrDefault -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-RequiredFunctionDefinitionAst -ErrorAction SilentlyContinue
}

Describe "Run-PreCommitValidation git repository-root anchoring" {
    It "queries staged files through git -C RepositoryRoot from a different working directory" {
        $argumentLogPath = Join-Path -Path $TestDrive -ChildPath "git-args.txt"
        $expectedRepositoryRoot = Join-Path -Path $TestDrive -ChildPath "expected-repo"
        $ambientDirectory = Join-Path -Path $TestDrive -ChildPath "ambient"
        [void](New-Item -Path $expectedRepositoryRoot -ItemType Directory -Force)
        [void](New-Item -Path $ambientDirectory -ItemType Directory -Force)

        function Invoke-RunPreCommitValidationGitRootFakeGit {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)

            [System.IO.File]::WriteAllText($env:WALLSTOP_TEST_GIT_ARGS_PATH, ($GitArgs -join [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            if ($GitArgs.Count -ge 6 -and $GitArgs[0] -eq "-C" -and $GitArgs[1] -eq $env:WALLSTOP_TEST_EXPECTED_REPO -and $GitArgs[2] -eq "diff" -and $GitArgs[3] -eq "--cached") {
                "Scripts/Utils/Run-PreCommitValidation.ps1"
                $global:LASTEXITCODE = 0
                return
            }

            $global:LASTEXITCODE = 9
            Write-Error "unexpected git args: $($GitArgs -join ' ')"
        }

        $previousArgumentLogPath = $env:WALLSTOP_TEST_GIT_ARGS_PATH
        $previousExpectedRepositoryRoot = $env:WALLSTOP_TEST_EXPECTED_REPO
        $env:WALLSTOP_TEST_GIT_ARGS_PATH = $argumentLogPath
        $env:WALLSTOP_TEST_EXPECTED_REPO = $expectedRepositoryRoot

        Push-Location -LiteralPath $ambientDirectory
        try {
            $result = @(Get-StagedFilesWithIndexLockRecoveryOrThrow -GitExecutable "Invoke-RunPreCommitValidationGitRootFakeGit" -RepositoryRoot $expectedRepositoryRoot)
        }
        finally {
            Pop-Location
            $env:WALLSTOP_TEST_GIT_ARGS_PATH = $previousArgumentLogPath
            $env:WALLSTOP_TEST_EXPECTED_REPO = $previousExpectedRepositoryRoot
            Remove-Item -Path Function:Invoke-RunPreCommitValidationGitRootFakeGit -ErrorAction SilentlyContinue
        }

        $result | Should -Be @("Scripts/Utils/Run-PreCommitValidation.ps1")
        $capturedArgs = [System.IO.File]::ReadAllLines($argumentLogPath, [System.Text.Encoding]::UTF8)
        $capturedArgs[0] | Should -Be "-C"
        $capturedArgs[1] | Should -Be $expectedRepositoryRoot
        $capturedArgs[2] | Should -Be "diff"
        $capturedArgs[3] | Should -Be "--cached"
    }

    It "anchors staged-file discovery to the explicit RepositoryRoot parameter" {
        $script:preCommitContent | Should -Match '\$stagedFileArgs\s*=\s*@\("-C",\s*\$RepositoryRoot,\s*"diff",\s*"--cached",\s*"--name-only",\s*"--diff-filter=ACMR"\)'
        $script:preCommitContent | Should -Match 'Invoke-GitCommandWithSplitOutput\s+-GitExecutable\s+\$GitExecutable\s+-Arguments\s+\$stagedFileArgs'
        $script:preCommitContent | Should -Not -Match '&\s+\$GitExecutable\s+diff\s+--cached'
    }

    It "anchors all-mode tracked-file discovery to repoRoot" {
        $script:preCommitContent | Should -Match 'Invoke-GitStdoutOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-Arguments\s+@\("-C",\s*\$repoRoot,\s*"ls-files"\)'
        $script:preCommitContent | Should -Not -Match '&\s+\$gitExecutable\s+ls-files'
    }

    It "anchors formatter drift git diff probes to repoRoot" {
        $script:preCommitContent | Should -Match '\$windowsLanguageDiffArgs\s*=\s*@\("-C",\s*\$repoRoot,\s*"diff",\s*"--name-only",\s*"--"\)'
        $script:preCommitContent | Should -Match '\$shellQualityDiffArgs\s*=\s*@\("-C",\s*\$repoRoot,\s*"diff",\s*"--name-only",\s*"--"\)'
        $script:preCommitContent | Should -Match '\$nativeQualityDiffArgs\s*=\s*@\("-C",\s*\$repoRoot,\s*"diff",\s*"--name-only",\s*"--"\)'
        $script:preCommitContent | Should -Not -Match '&\s+\$gitExecutable\s+diff\s+--name-only'
    }

    It "ignores successful git stderr when reading staged-file stdout" {
        Mock Invoke-GitCommandWithSplitOutput {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = @("Scripts/Utils/Run-PreCommitValidation.ps1")
                Stderr   = "trace: staged-file discovery"
            }
        }

        $result = @(Get-StagedFilesWithIndexLockRecoveryOrThrow -GitExecutable "git" -RepositoryRoot "/tmp/repo")

        $result | Should -Be @("Scripts/Utils/Run-PreCommitValidation.ps1")
        $result | Should -Not -Contain "trace: staged-file discovery"
    }

    It "allows successful staged-file discovery with empty stdout" {
        Mock Invoke-GitCommandWithSplitOutput {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = @()
                Stderr   = ""
            }
        }

        $result = @(Get-StagedFilesWithIndexLockRecoveryOrThrow -GitExecutable "git" -RepositoryRoot "/tmp/repo")

        $result.Count | Should -Be 0
    }

    It "includes split stdout and stderr in staged-file failure diagnostics" {
        Mock Invoke-GitCommandWithSplitOutput {
            return [pscustomobject]@{
                ExitCode = 2
                Stdout   = @("stdout detail")
                Stderr   = "stderr detail"
            }
        }

        {
            Get-StagedFilesWithIndexLockRecoveryOrThrow -GitExecutable "git" -RepositoryRoot "/tmp/repo"
        } | Should -Throw "*stdout detail*stderr detail*"
    }
}
