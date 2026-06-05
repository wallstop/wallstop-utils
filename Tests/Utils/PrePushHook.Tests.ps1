Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:hookTimeoutHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/HookTimeout.sh"
    $script:bashCommand = Get-Command -Name "bash" -ErrorAction SilentlyContinue
    $script:requiresBashPathConversion = [System.IO.Path]::DirectorySeparatorChar -eq '\'
}

function script:Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function script:ConvertTo-BashPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $script:requiresBashPathConversion) {
        return $Path
    }

    $convertedPath = @(& $script:bashCommand.Source -lc @'
path_value="$1"
if command -v cygpath > /dev/null 2>&1; then
  cygpath -u "$path_value"
  exit $?
fi
if command -v wslpath > /dev/null 2>&1; then
  wslpath -u "$path_value"
  exit $?
fi
exit 127
'@ -- $Path 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $convertedPath.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($convertedPath[0])) {
        return [string]$convertedPath[0]
    }

    throw "E_TEST_BASH_PATH_CONVERSION_FAILED: selected Bash runtime could not convert '$Path' with cygpath or wslpath."
}

function script:Resolve-BashCommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    $resolvedCommand = @(& $script:bashCommand.Source -lc 'command -v "$1"' -- $CommandName 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or $resolvedCommand.Count -eq 0 -or [string]::IsNullOrWhiteSpace($resolvedCommand[0])) {
        return $null
    }

    return [string]$resolvedCommand[0]
}

function script:Set-BashExecutableBit {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    $bashPaths = @($Path | ForEach-Object { ConvertTo-BashPath -Path $_ })
    & $script:bashCommand.Source -lc 'chmod +x "$@"' -- @bashPaths
    if ($LASTEXITCODE -ne 0) {
        throw "E_TEST_BASH_CHMOD_FAILED: selected Bash runtime could not mark harness script(s) executable."
    }
}

function script:Test-BashFileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    & $script:bashCommand.Source -lc 'test -f "$1"' -- $Path
    return ($LASTEXITCODE -eq 0)
}

function script:Remove-BashFiles {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Path = @()
    )

    $pathsToRemove = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pathsToRemove.Count -eq 0) {
        return
    }

    & $script:bashCommand.Source -lc 'rm -f -- "$@"' -- @pathsToRemove
    if ($LASTEXITCODE -ne 0) {
        throw "E_TEST_BASH_RM_FAILED: selected Bash runtime could not remove harness temp file(s)."
    }
}

function script:New-PrePushHookHarness {
    $harnessRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
    $repoRoot = Join-Path -Path $harnessRoot -ChildPath "repo"
    $binRoot = Join-Path -Path $harnessRoot -ChildPath "bin"
    [void][System.IO.Directory]::CreateDirectory($repoRoot)
    [void][System.IO.Directory]::CreateDirectory($binRoot)

    $hookTimeoutTarget = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Common/HookTimeout.sh"
    [void][System.IO.Directory]::CreateDirectory(([System.IO.Path]::GetDirectoryName($hookTimeoutTarget)))
    Copy-Item -LiteralPath $script:hookTimeoutHelperPath -Destination $hookTimeoutTarget -Force

    $commandLogPath = Join-Path -Path $harnessRoot -ChildPath "commands.log"
    $gitScriptPath = Join-Path -Path $binRoot -ChildPath "git"
    $preCommitScriptPath = Join-Path -Path $binRoot -ChildPath "pre-commit"
    $pwshScriptPath = Join-Path -Path $binRoot -ChildPath "pwsh"

    $fakeGit = @'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'git'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$WALLSTOP_TEST_COMMAND_LOG"

if [[ "$#" -ge 2 && "$1" == "rev-parse" && "$2" == "--show-toplevel" ]]; then
  if [[ -n "${WALLSTOP_TEST_REPO_ROOT_STDERR:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_REPO_ROOT_STDERR" >&2
  fi
  if [[ "${WALLSTOP_TEST_REPO_ROOT_EXIT:-0}" != "0" ]]; then
    printf '%s\n' "${WALLSTOP_TEST_REPO_ROOT_OUTPUT:-fatal: not a git repository}"
    exit "$WALLSTOP_TEST_REPO_ROOT_EXIT"
  fi
  printf '%s\n' "$WALLSTOP_TEST_REPO_ROOT"
  exit 0
fi

if [[ "$#" -ge 4 && "$1" == "rev-parse" && "$2" == "--abbrev-ref" && "$3" == "--symbolic-full-name" ]]; then
  if [[ -n "${WALLSTOP_TEST_UPSTREAM_REF:-}" ]]; then
    printf '%s\n' "$WALLSTOP_TEST_UPSTREAM_REF"
    exit 0
  fi
  exit 1
fi

if [[ "$#" -ge 4 && "$1" == "rev-parse" && "$2" == "--verify" && "$3" == "--quiet" ]]; then
  if [[ "$4" == "origin/HEAD^{commit}" ]]; then
    if [[ "${WALLSTOP_TEST_ORIGIN_HEAD_AVAILABLE:-0}" == "1" ]]; then
      exit 0
    fi
    exit 1
  fi

  if [[ "$4" == *"^" && "${WALLSTOP_TEST_HEAD_PARENT_AVAILABLE:-0}" == "1" ]]; then
    exit 0
  fi

  exit 1
fi

if [[ "$1" == "merge-base" ]]; then
  if [[ "$3" == "origin/HEAD" && -n "${WALLSTOP_TEST_ORIGIN_MERGE_BASE:-}" ]]; then
    printf '%s\n' "$WALLSTOP_TEST_ORIGIN_MERGE_BASE"
    exit 0
  fi

  if [[ -n "${WALLSTOP_TEST_MERGE_BASE:-}" ]]; then
    printf '%s\n' "$WALLSTOP_TEST_MERGE_BASE"
    exit 0
  fi

  exit 1
fi

if [[ "$1" == "diff" ]]; then
  if [[ -n "${WALLSTOP_TEST_DIFF_STDERR:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_DIFF_STDERR" >&2
  fi
  if [[ -n "${WALLSTOP_TEST_DIFF_OUTPUT:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_DIFF_OUTPUT"
  fi
  exit "${WALLSTOP_TEST_DIFF_EXIT:-0}"
fi

if [[ "$1" == "ls-files" ]]; then
  if [[ -n "${WALLSTOP_TEST_LS_FILES_STDERR:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_LS_FILES_STDERR" >&2
  fi
  if [[ -n "${WALLSTOP_TEST_LS_FILES_OUTPUT:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_LS_FILES_OUTPUT"
  fi
  exit "${WALLSTOP_TEST_LS_FILES_EXIT:-0}"
fi

exit 0
'@

    $fakePreCommit = @'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'pre-commit'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$WALLSTOP_TEST_COMMAND_LOG"
exit 0
'@

    $fakePwsh = @'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'pwsh'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$WALLSTOP_TEST_COMMAND_LOG"

previous_arg=""
for arg in "$@"; do
  if [[ "$previous_arg" == "-FileListPath" || "$previous_arg" == "-TargetFileListPath" ]]; then
    while IFS= read -r listed_file; do
      if [[ -n "$listed_file" ]]; then
        printf 'pwsh-file\t%s\n' "$listed_file" >> "$WALLSTOP_TEST_COMMAND_LOG"
      fi
    done < "$arg"
  fi
  previous_arg="$arg"
done

exit 0
'@

    Write-Utf8NoBomFile -Path $gitScriptPath -Content $fakeGit
    Write-Utf8NoBomFile -Path $preCommitScriptPath -Content $fakePreCommit
    Write-Utf8NoBomFile -Path $pwshScriptPath -Content $fakePwsh

    Set-BashExecutableBit -Path @($gitScriptPath, $preCommitScriptPath, $pwshScriptPath)

    foreach ($utilityName in @("bash", "rm", "mktemp", "sort", "sleep", "timeout", "gtimeout", "awk")) {
        $wrapperPath = Join-Path -Path $binRoot -ChildPath $utilityName
        if (Test-Path -LiteralPath $wrapperPath -PathType Leaf) {
            continue
        }

        $utilityPath = Resolve-BashCommandPath -CommandName $utilityName
        if ([string]::IsNullOrWhiteSpace($utilityPath)) {
            continue
        }

        $escapedUtilityPath = $utilityPath.Replace("'", "'\''")
        Write-Utf8NoBomFile -Path $wrapperPath -Content @"
#!/bin/sh
exec '$escapedUtilityPath' "`$@"
"@
        Set-BashExecutableBit -Path @($wrapperPath)
    }

    return [pscustomobject]@{
        Root           = $harnessRoot
        RepoRoot       = $repoRoot
        BinRoot        = $binRoot
        CommandLogPath = $commandLogPath
    }
}

function script:Invoke-PrePushHookHarness {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Harness,

        [Parameter(Mandatory = $false)]
        [string]$Stdin = "",

        [Parameter(Mandatory = $false)]
        [hashtable]$Environment = @{}
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:bashCommand.Source
    $bashHookPath = ConvertTo-BashPath -Path $script:prePushHookPath
    $startInfo.Arguments = '"' + $bashHookPath.Replace('"', '\"') + '"'
    $startInfo.WorkingDirectory = $Harness.RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment["PATH"] = ConvertTo-BashPath -Path $Harness.BinRoot
    $startInfo.Environment["WALLSTOP_TEST_REPO_ROOT"] = ConvertTo-BashPath -Path $Harness.RepoRoot
    $startInfo.Environment["WALLSTOP_TEST_COMMAND_LOG"] = ConvertTo-BashPath -Path $Harness.CommandLogPath
    $startInfo.Environment["WALLSTOP_PREPUSH_TIMEOUT_SECONDS"] = "45"

    foreach ($key in $Environment.Keys) {
        $startInfo.Environment[[string]$key] = [string]$Environment[$key]
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "E_CONFIG_ERROR: failed to start pre-push hook harness."
    }

    try {
        $process.StandardInput.Write($Stdin)
        $process.StandardInput.Close()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw "E_TEST_TIMEOUT: pre-push hook harness did not exit within 10 seconds."
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.GetAwaiter().GetResult()
            Stderr   = $stderrTask.GetAwaiter().GetResult()
            Log      = if (Test-Path -LiteralPath $Harness.CommandLogPath -PathType Leaf) {
                [System.IO.File]::ReadAllText($Harness.CommandLogPath, [System.Text.Encoding]::UTF8)
            }
            else {
                ""
            }
        }
    }
    finally {
        $process.Dispose()
    }
}

function script:Assert-NoDeepPrePushCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLog
    )

    $CommandLog | Should -Not -Match 'Invoke-FullValidation\.ps1'
    $CommandLog | Should -Not -Match '(?m)(^|\s)-All(\s|$)'
    $CommandLog | Should -Not -Match '--all-files'
}

function script:Assert-PrePushHarnessSucceeded {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    $Result.ExitCode | Should -Be 0 -Because (
        "stdout={0}; stderr={1}; commandLog={2}" -f $Result.Stdout, $Result.Stderr, $Result.Log
    )
}

function script:Assert-LoggedFileListPathsWereRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLog
    )

    $paths = @(
        [regex]::Matches($CommandLog, '(?:-FileListPath|-TargetFileListPath)\t(?<Path>[^\t\r\n]+)') |
            ForEach-Object { $_.Groups["Path"].Value }
    )

    try {
        $paths.Count | Should -BeGreaterThan 0 -Because "pre-push hook should pass changed files through a temp file list."

        $leakedPaths = @($paths | Where-Object { Test-BashFileExists -Path $_ })
        $leakedPaths.Count | Should -Be 0 -Because (
            "pre-push hook EXIT trap must remove temp file lists. Leaked paths: {0}" -f ($leakedPaths -join ", ")
        )
    }
    finally {
        Remove-BashFiles -Path $paths
    }
}

Describe "pre-push changed-file hook behavior" {
    BeforeEach {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }
    }

    It "<Name>" -ForEach @(
        @{
            Name                  = "validates files changed against an existing remote ref"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_DIFF_OUTPUT = "Scripts/Utils/Run-PreCommitValidation.ps1`nREADME.md`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = ""
            ExpectedLogPatterns   = @(
                'git\tdiff\t--name-only\t--diff-filter=ACMR\tremote123\.\.local456\t--',
                'pwsh[\s\S]*Invoke-PreCommitWithRecovery\.ps1[\s\S]*-HookStage[\s\S]*pre-push[\s\S]*-FileListPath',
                'pwsh-file\tScripts/Utils/Run-PreCommitValidation\.ps1',
                'pwsh-file\tREADME\.md'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "ignores successful diff stderr output"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_DIFF_OUTPUT = "Scripts/Utils/Run-PreCommitValidation.ps1`nREADME.md`n"
                WALLSTOP_TEST_DIFF_STDERR = "trace: diff probe`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = ""
            ExpectedLogPatterns   = @(
                'git\tdiff\t--name-only\t--diff-filter=ACMR\tremote123\.\.local456\t--',
                'pwsh-file\tScripts/Utils/Run-PreCommitValidation\.ps1',
                'pwsh-file\tREADME\.md'
            )
            UnexpectedLogPattern  = 'trace: diff probe|pwsh-file\ttrace:'
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "uses a resolved upstream merge-base for new branches"
            Stdin                 = "refs/heads/feature local456 refs/heads/feature 0000000000000000000000000000000000000000`n"
            Environment           = @{
                WALLSTOP_TEST_UPSTREAM_REF = "origin/main"
                WALLSTOP_TEST_MERGE_BASE   = "base111"
                WALLSTOP_TEST_DIFF_OUTPUT  = "Scripts/Utils/New-Thing.ps1`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = ""
            ExpectedLogPatterns   = @(
                'git\trev-parse\t--abbrev-ref\t--symbolic-full-name\tfeature@\{upstream\}',
                'git\tmerge-base\tlocal456\torigin/main',
                'git\tdiff\t--name-only\t--diff-filter=ACMR\tbase111\.\.local456\t--',
                'pwsh[\s\S]*-FileListPath',
                'pwsh-file\tScripts/Utils/New-Thing\.ps1'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "skips validation for delete pushes"
            Stdin                 = "refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature remote123`n"
            Environment           = @{}
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'skipping delete push'
            ExpectedLogPatterns   = @()
            UnexpectedLogPattern  = 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
        @{
            Name                  = "skips validation when pre-push receives no stdin ref updates"
            Stdin                 = ""
            Environment           = @{}
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'no ref updates received'
            ExpectedLogPatterns   = @()
            UnexpectedLogPattern  = 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
        @{
            Name                  = "ignores successful repository-root stderr output"
            Stdin                 = ""
            Environment           = @{
                WALLSTOP_TEST_REPO_ROOT_STDERR = "trace: repo-root probe`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'no ref updates received'
            ExpectedLogPatterns   = @('git\trev-parse\t--show-toplevel')
            UnexpectedLogPattern  = 'trace: repo-root probe|E_PREPUSH_REPO_ROOT_UNAVAILABLE|Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
        @{
            Name                  = "falls back to tracked files for new branches without any baseline"
            Stdin                 = "refs/heads/root local456 refs/heads/root 0000000000000000000000000000000000000000`n"
            Environment           = @{
                WALLSTOP_TEST_LS_FILES_OUTPUT = "README.md`nScripts/Utils/Fallback.ps1`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'W_PREPUSH_CHANGED_FILE_BASELINE_MISSING'
            ExpectedLogPatterns   = @(
                'git\tls-files',
                'pwsh[\s\S]*-FileListPath',
                'pwsh-file\tREADME\.md',
                'pwsh-file\tScripts/Utils/Fallback\.ps1'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "ignores successful tracked-file fallback stderr output"
            Stdin                 = "refs/heads/root local456 refs/heads/root 0000000000000000000000000000000000000000`n"
            Environment           = @{
                WALLSTOP_TEST_LS_FILES_OUTPUT = "README.md`nScripts/Utils/Fallback.ps1`n"
                WALLSTOP_TEST_LS_FILES_STDERR = "trace: ls-files probe`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'W_PREPUSH_CHANGED_FILE_BASELINE_MISSING'
            ExpectedLogPatterns   = @(
                'git\tls-files',
                'pwsh-file\tREADME\.md',
                'pwsh-file\tScripts/Utils/Fallback\.ps1'
            )
            UnexpectedLogPattern  = 'trace: ls-files probe|pwsh-file\ttrace:'
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "uses legacy PowerShell target-file checks when pre-commit is unavailable"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_DIFF_OUTPUT = ".githooks/pre-push`n"
            }
            RemovePreCommit       = $true
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'pre-commit is not installed; falling back to legacy PowerShell checks'
            ExpectedLogPatterns   = @(
                'pwsh[\s\S]*Scripts/Utils/Run-PreCommitValidation\.ps1[\s\S]*-IncludePreCommitOwnedChecks[\s\S]*-TargetFileListPath',
                'pwsh-file\t\.githooks/pre-push'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "emits stable diagnostics when repository root cannot be resolved"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_REPO_ROOT_EXIT   = "128"
                WALLSTOP_TEST_REPO_ROOT_OUTPUT = "fatal: not a git repository"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 128
            ExpectedStderrPattern = 'E_PREPUSH_REPO_ROOT_UNAVAILABLE: failed to resolve repository root \(exitCode=128; workingDirectory=.*; gitCommand=.*git\)\. Git output: fatal: not a git repository'
            ExpectedLogPatterns   = @('git\trev-parse\t--show-toplevel')
            UnexpectedLogPattern  = 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
    ) {
        $harness = New-PrePushHookHarness
        if ($RemovePreCommit) {
            Remove-Item -LiteralPath (Join-Path -Path $harness.BinRoot -ChildPath "pre-commit") -Force
        }

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin $Stdin -Environment $Environment

        if ($ExpectedExitCode -eq 0) {
            Assert-PrePushHarnessSucceeded -Result $result
        }
        else {
            $result.ExitCode | Should -Be $ExpectedExitCode -Because (
                "stdout={0}; stderr={1}; commandLog={2}" -f $result.Stdout, $result.Stderr, $result.Log
            )
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedStderrPattern)) {
            $result.Stderr | Should -Match $ExpectedStderrPattern
        }

        foreach ($expectedLogPattern in @($ExpectedLogPatterns)) {
            $result.Log | Should -Match $expectedLogPattern
        }

        if (-not [string]::IsNullOrWhiteSpace($UnexpectedLogPattern)) {
            $result.Log | Should -Not -Match $UnexpectedLogPattern
        }

        if ($AssertFileListCleanup) {
            Assert-LoggedFileListPathsWereRemoved -CommandLog $result.Log
        }

        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }
}
