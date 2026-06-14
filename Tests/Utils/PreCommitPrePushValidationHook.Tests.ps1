Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1")

    function Invoke-GitStdoutForHookTest {
        param(
            [Parameter(Mandatory = $true)]
            [string]$GitPath,

            [Parameter(Mandatory = $true)]
            [string[]]$Arguments
        )

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $GitPath
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList $Arguments

        $process = [System.Diagnostics.Process]::new()
        try {
            $process.StartInfo = $startInfo
            $process.Start() | Out-Null
            if (-not $process.WaitForExit(30000)) {
                Stop-ProcessTreePortably -Process $process
                throw "git command exceeded 30s. args=$($Arguments -join ' ')"
            }

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            if ($process.ExitCode -ne 0) {
                throw "git command failed (exitCode=$($process.ExitCode); args=$($Arguments -join ' '); stderr=$stderr)"
            }

            return @(
                $stdout -split '\r?\n' |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }
        finally {
            $process.Dispose()
        }
    }

    function Test-IsWindowsNativeBashForHookTest {
        param([string]$BashPath)

        if ([System.IO.Path]::DirectorySeparatorChar -ne '\') {
            return $true
        }

        $unameOutput = @(& $BashPath --noprofile --norc -c 'uname -s' 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or $unameOutput.Count -eq 0) {
            return $false
        }

        return ([string]$unameOutput[0] -match '^(MINGW|MSYS|CYGWIN)')
    }
}

Describe "powershell pre-push pre-commit validation hook" {
    It "passes pre-commit-owned checks so pre-push keeps changed-file parity" {
        $wrapperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PrePushPreCommitValidation.ps1"
        $wrapperContent = Get-Content -Path $wrapperPath -Raw

        $wrapperContent | Should -Match 'IncludePreCommitOwnedChecks\s*=\s*\$true'
    }

    It "runs real PowerShell governance validation for hook governance files" {
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
        $tempIndexPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-precommit-governance-{0}.index" -f [guid]::NewGuid().ToString("N"))

        try {
            $env:GIT_INDEX_FILE = $tempIndexPath
            $readTreeOutput = @(& $gitCommand.Source -C $script:repoRoot read-tree HEAD 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index read-tree should succeed before pre-commit governance test. Output: {0}" -f
                ($readTreeOutput -join "`n")
            )

            $preCommitConfigPath = Join-Path -Path $script:repoRoot -ChildPath ".pre-commit-config.yaml"
            $governanceBlobContent = ([System.IO.File]::ReadAllText($preCommitConfigPath, [System.Text.Encoding]::UTF8)) + "`n# temp-index governance trigger`n"
            $blobOutput = @($governanceBlobContent | & $gitCommand.Source -C $script:repoRoot hash-object -w --stdin 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index blob creation should succeed before pre-commit governance test. Output: {0}" -f
                ($blobOutput -join "`n")
            )
            $blobSha = [string]($blobOutput | Select-Object -First 1)
            $updateIndexOutput = @(& $gitCommand.Source -C $script:repoRoot update-index --add --cacheinfo 100644 $blobSha .pre-commit-config.yaml 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index staging should make .pre-commit-config.yaml visible to validation. Output: {0}" -f
                ($updateIndexOutput -join "`n")
            )

            Push-Location -LiteralPath $script:repoRoot
            try {
                $hookOutput = @(
                    & $preCommitCommand.Source run --hook-stage pre-commit powershell-precommit-validation --files .pre-commit-config.yaml --color never --verbose 2>&1
                )
            }
            finally {
                Pop-Location
            }

            $hookExitCode = $LASTEXITCODE
            $hookOutputText = $hookOutput -join "`n"
            $hookExitCode | Should -Be 0 -Because (
                "powershell-precommit-validation should run for governance files. Output: {0}" -f
                $hookOutputText
            )
            $hookOutputText | Should -Not -Match '\(no files to check\).*Skipped'
            $hookOutputText | Should -Match 'Running hook governance validation' -Because "governance files must not only pass pre-commit's file prefilter; they must run real validator work."
            $hookOutputText | Should -Not -Match 'No staged files requiring utility validation'
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

    It "runs direct governance validation without depending on pre-commit hook selection" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"

        $global:LASTEXITCODE = 0
        $output = @(& $validatorPath -TargetFiles .gitattributes -Verbose *>&1)
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        $exitCode | Should -Be 0 -Because (
            "direct governance validation should pass for .gitattributes. Output: {0}" -f
            $outputText
        )
        $outputText | Should -Match 'Running hook governance validation'
        $outputText | Should -Not -Match 'No staged files requiring utility validation'
    }

    It "rejects malformed quality manifests through direct governance validation" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        . $validatorPath -NoInvokeMain

        {
            Assert-GovernanceQualityManifest -GovernanceManifest ([pscustomobject]@{ tools = [pscustomobject]@{} }) -GovernanceManifestPath "Scripts/Utils/Quality/shell-quality-tools.json" -GovernanceExpectedToolAssets @{
                "shellcheck" = @("linux-x64")
            }
        } | Should -Throw -ExpectedMessage '*E_PRECOMMIT_GOVERNANCE_PROPERTY_MISSING*'
    }

    It "rejects unsafe ShellCheck and incomplete StyLua governance configs" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        . $validatorPath -NoInvokeMain

        { Assert-ShellCheckGovernanceConfig -ShellCheckConfigContent "external-sources=true`nsource-path=SCRIPTDIR`nseverity=style`ndisable=all`n" } |
            Should -Throw -ExpectedMessage '*E_PRECOMMIT_GOVERNANCE_SHELLCHECKRC_DISABLE_ALL*'
        { Assert-StyLuaGovernanceConfig -StyLuaConfigContent "column_width = 100`nline_endings = `"Unix`"`n" } |
            Should -Throw -ExpectedMessage '*E_PRECOMMIT_GOVERNANCE_STYLUA_INVALID*'
    }

    It "runs pre-push owned shell checks through the wrapper" {
        $wrapperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PrePushPreCommitValidation.ps1"

        $global:LASTEXITCODE = 0
        $output = @(& $wrapperPath .githooks/pre-commit *>&1)
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        $exitCode | Should -Be 0 -Because (
            "pre-push wrapper should route shell hook targets through pre-commit-owned checks. Output: {0}" -f
            $outputText
        )
        $outputText | Should -Match 'Running shell lint/format-check validation'
    }

    It "keeps pre-commit no-staged fast path before missing-pre-commit fallback" {
        $bashCommand = Get-Command -Name "bash" -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }
        if (-not (Test-IsWindowsNativeBashForHookTest -BashPath $bashCommand.Source)) {
            Set-ItResult -Skipped -Because "bash is not Windows-native; WSL bash cannot reliably execute the Windows worktree hook in this test."
            return
        }

        $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable."
            return
        }

        $preCommitCommand = Get-Command -Name "pre-commit" -ErrorAction SilentlyContinue
        if ($null -eq $preCommitCommand) {
            Set-ItResult -Skipped -Because "pre-commit is already unavailable, so PATH fallback simulation is not needed."
            return
        }

        $previousGitIndexFileSet = Test-Path -Path "Env:GIT_INDEX_FILE"
        $previousGitIndexFile = $env:GIT_INDEX_FILE
        $previousPath = $env:PATH
        $tempIndexPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-precommit-no-staged-{0}.index" -f [guid]::NewGuid().ToString("N"))

        try {
            $env:GIT_INDEX_FILE = $tempIndexPath
            $readTreeOutput = @(& $gitCommand.Source -C $script:repoRoot read-tree HEAD 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index read-tree should succeed before pre-commit no-staged test. Output: {0}" -f
                ($readTreeOutput -join "`n")
            )

            $preCommitDirectory = Split-Path -Path $preCommitCommand.Source -Parent
            $pathEntries = @(
                ($env:PATH -split [System.IO.Path]::PathSeparator) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Where-Object { -not [string]::Equals($_, $preCommitDirectory, [System.StringComparison]::OrdinalIgnoreCase) }
            )
            $env:PATH = $pathEntries -join [System.IO.Path]::PathSeparator
            $preCommitProbe = @(& $bashCommand.Source --noprofile --norc -c 'command -v pre-commit' 2>$null)
            if ($LASTEXITCODE -eq 0 -and $preCommitProbe.Count -gt 0) {
                Set-ItResult -Skipped -Because "pre-commit remains discoverable after removing its directory from PATH."
                return
            }

            Push-Location -LiteralPath $script:repoRoot
            try {
                $output = @(& $bashCommand.Source --noprofile --norc .githooks/pre-commit 2>&1)
            }
            finally {
                Pop-Location
            }
            $outputText = $output -join "`n"

            $LASTEXITCODE | Should -Be 0 -Because $outputText
            $outputText | Should -Not -Match 'pre-commit is not installed; falling back to legacy PowerShell checks'
        }
        finally {
            $env:PATH = $previousPath
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

    It "validates staged shell blobs even when the worktree target is absent" {
        $bashCommand = Get-Command -Name "bash" -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }
        if (-not (Test-IsWindowsNativeBashForHookTest -BashPath $bashCommand.Source)) {
            Set-ItResult -Skipped -Because "bash is not Windows-native; WSL bash cannot reliably execute the Windows worktree hook in this test."
            return
        }

        $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable."
            return
        }

        $previousGitIndexFileSet = Test-Path -Path "Env:GIT_INDEX_FILE"
        $previousGitIndexFile = $env:GIT_INDEX_FILE
        $tempIndexPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-precommit-staged-blob-{0}.index" -f [guid]::NewGuid().ToString("N"))
        $missingShellPath = "Scripts/precommit-staged-missing-{0}.sh" -f [guid]::NewGuid().ToString("N")

        try {
            $env:GIT_INDEX_FILE = $tempIndexPath
            $readTreeOutput = @(& $gitCommand.Source -C $script:repoRoot read-tree HEAD 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index read-tree should succeed before pre-commit staged-blob test. Output: {0}" -f
                ($readTreeOutput -join "`n")
            )

            (Test-Path -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath $missingShellPath) -PathType Leaf) |
                Should -BeFalse -Because "the regression requires a staged supported file that is absent from the worktree."

            $invalidShellContent = "#!/usr/bin/env bash`nif true; then`n  printf '%s\n' staged-only`n"
            $blobOutput = @($invalidShellContent | & $gitCommand.Source -C $script:repoRoot hash-object -w --stdin 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index blob creation should succeed before pre-commit staged-blob test. Output: {0}" -f
                ($blobOutput -join "`n")
            )
            $blobSha = [string]($blobOutput | Select-Object -First 1)

            $updateIndexOutput = @(& $gitCommand.Source -C $script:repoRoot update-index --add --cacheinfo 100755 $blobSha $missingShellPath 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index staging should make the missing shell script visible to the hook. Output: {0}" -f
                ($updateIndexOutput -join "`n")
            )

            Push-Location -LiteralPath $script:repoRoot
            try {
                $output = @(& $bashCommand.Source --noprofile --norc .githooks/pre-commit 2>&1)
            }
            finally {
                Pop-Location
            }

            $outputText = $output -join "`n"
            $LASTEXITCODE | Should -Be 1 -Because $outputText
            $outputText | Should -Match 'E_PRECOMMIT_FAST_SHELL_PARSE_FAILED'
            $outputText | Should -Match ([regex]::Escape("file=$missingShellPath"))
            $outputText | Should -Not -Match 'pre-commit is not installed; falling back to legacy PowerShell checks|Run-PreCommitValidation'
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

    It "emits no-op runtime budget warning for slow pre-commit no-staged setup" {
        if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
            Set-ItResult -Skipped -Because "PATH-prepended executable wrapper semantics differ on native Windows."
            return
        }

        $bashCommand = Get-Command -Name "bash" -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable."
            return
        }

        $previousGitIndexFileSet = Test-Path -Path "Env:GIT_INDEX_FILE"
        $previousGitIndexFile = $env:GIT_INDEX_FILE
        $previousPath = $env:PATH
        $tempIndexPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-precommit-slow-no-staged-{0}.index" -f [guid]::NewGuid().ToString("N"))
        $tempBinPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-precommit-git-wrapper-{0}" -f [guid]::NewGuid().ToString("N"))

        try {
            [void](New-Item -ItemType Directory -Path $tempBinPath -Force)
            $gitWrapperPath = Join-Path -Path $tempBinPath -ChildPath "git"
            $gitWrapper = @"
#!/usr/bin/env bash
set -euo pipefail
if [[ "`$#" -ge 2 && "`$1" == "rev-parse" && "`$2" == "--show-toplevel" ]]; then
  sleep 2
fi
exec "$($gitCommand.Source)" "`$@"
"@
            [System.IO.File]::WriteAllText($gitWrapperPath, $gitWrapper.Replace("`r", "") + "`n", [System.Text.UTF8Encoding]::new($false))
            $chmodCommand = @(Get-Command -Name "chmod" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($null -eq $chmodCommand) {
                Set-ItResult -Skipped -Because "chmod is unavailable for test git wrapper."
                return
            }
            & $chmodCommand.Path +x $gitWrapperPath

            $env:GIT_INDEX_FILE = $tempIndexPath
            $readTreeOutput = @(& $gitCommand.Source -C $script:repoRoot read-tree HEAD 2>&1)
            $LASTEXITCODE | Should -Be 0 -Because (
                "temp-index read-tree should succeed before pre-commit slow no-staged test. Output: {0}" -f
                ($readTreeOutput -join "`n")
            )

            $env:PATH = $tempBinPath + [System.IO.Path]::PathSeparator + $env:PATH
            Push-Location -LiteralPath $script:repoRoot
            try {
                $output = @(& $bashCommand.Source --noprofile --norc .githooks/pre-commit 2>&1)
            }
            finally {
                Pop-Location
            }
            $outputText = $output -join "`n"

            $LASTEXITCODE | Should -Be 0 -Because $outputText
            $outputText | Should -Match 'W_HOOK_RUNTIME_BUDGET: pre-commit no staged files took'
            $outputText | Should -Not -Match 'pre-commit is not installed; falling back to legacy PowerShell checks|Run-PreCommitValidation'
        }
        finally {
            $env:PATH = $previousPath
            if ($previousGitIndexFileSet) {
                $env:GIT_INDEX_FILE = $previousGitIndexFile
            }
            else {
                Remove-Item -Path "Env:GIT_INDEX_FILE" -ErrorAction SilentlyContinue
            }

            Remove-Item -LiteralPath $tempIndexPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$tempIndexPath.lock" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempBinPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

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

            $modifiedFiles = @(Invoke-GitStdoutForHookTest -GitPath $gitCommand.Source -Arguments @("-C", $script:repoRoot, "diff", "--name-only"))
            $untrackedFiles = @(Invoke-GitStdoutForHookTest -GitPath $gitCommand.Source -Arguments @("-C", $script:repoRoot, "ls-files", "--others", "--exclude-standard"))

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
