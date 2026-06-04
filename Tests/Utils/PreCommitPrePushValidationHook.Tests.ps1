Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
}

Describe "powershell pre-push pre-commit validation hook" {
    It "passes multiple pre-commit filenames as explicit target files" {
        $preCommitCommand = Get-Command -Name "pre-commit" -ErrorAction SilentlyContinue
        if ($null -eq $preCommitCommand) {
            Set-ItResult -Skipped -Because "pre-commit CLI is not available on PATH."
            return
        }

        $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) {
            Set-ItResult -Skipped -Because "git is not available on PATH."
            return
        }

        $previousGitIndexFileSet = Test-Path -Path "Env:GIT_INDEX_FILE"
        $previousGitIndexFile = $env:GIT_INDEX_FILE
        $tempIndexPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-prepush-precommit-{0}.index" -f [guid]::NewGuid().ToString("N"))

        try {
            $env:GIT_INDEX_FILE = $tempIndexPath

            $readTreeOutput = @(& $gitCommand.Source -C $script:repoRoot read-tree HEAD 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index read-tree should succeed before pre-commit integration test. Output: {0}" -f
                ($readTreeOutput -join "`n")
            )

            $modifiedFiles = @(& $gitCommand.Source -C $script:repoRoot diff --name-only 2>$null)
            $LASTEXITCODE | Should -Be 0 -Because "temp-index modified-file discovery should succeed."

            $untrackedFiles = @(& $gitCommand.Source -C $script:repoRoot ls-files --others --exclude-standard 2>$null)
            $LASTEXITCODE | Should -Be 0 -Because "temp-index untracked-file discovery should succeed."

            $filesToStage = @(
                $modifiedFiles + $untrackedFiles |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )

            if ($filesToStage.Count -gt 0) {
                $addOutput = @(& $gitCommand.Source -C $script:repoRoot add -- @filesToStage 2>&1)
                $LASTEXITCODE | Should -Be 0 -Because (
                    "temp-index staging should make the modified pre-commit config visible to pre-commit. Output: {0}" -f
                    ($addOutput -join "`n")
                )
            }

            Push-Location -LiteralPath $script:repoRoot
            try {
                $hookOutput = @(
                    & $preCommitCommand.Source run --hook-stage pre-push powershell-prepush-validation --files README.md Scripts/Utils/Run-PreCommitValidation.ps1 2>&1
                )
            }
            finally {
                Pop-Location
            }
            $hookExitCode = $LASTEXITCODE
            $hookOutputText = $hookOutput -join "`n"

            $hookExitCode | Should -Be 0 -Because (
                "powershell-prepush-validation should bind both filenames to TargetFiles. Output: {0}" -f
                $hookOutputText
            )
            $hookOutputText | Should -Not -Match 'Cannot convert value "Scripts/Utils/Run-PreCommitValidation\.ps1" to type "System\.Int32"'
            $hookOutputText | Should -Not -Match 'PesterTimeoutSeconds'
        }
        finally {
            if ($previousGitIndexFileSet) {
                $env:GIT_INDEX_FILE = $previousGitIndexFile
            }
            else {
                Remove-Item -Path "Env:GIT_INDEX_FILE" -ErrorAction SilentlyContinue
            }

            Remove-Item -LiteralPath $tempIndexPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$tempIndexPath.lock" -Force -ErrorAction SilentlyContinue
        }
    }
}
