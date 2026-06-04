Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:hookTimeoutHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/HookTimeout.sh"
    $script:bashCommand = Get-Command -Name "bash" -ErrorAction SilentlyContinue
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
  if [[ -n "${WALLSTOP_TEST_DIFF_OUTPUT:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_DIFF_OUTPUT"
  fi
  exit "${WALLSTOP_TEST_DIFF_EXIT:-0}"
fi

if [[ "$1" == "ls-files" ]]; then
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

    & chmod +x $gitScriptPath $preCommitScriptPath $pwshScriptPath

    foreach ($utilityName in @("bash", "rm", "mktemp", "sort", "sleep", "timeout", "awk")) {
        $utilityCommand = Get-Command -Name $utilityName -ErrorAction SilentlyContinue
        if ($null -eq $utilityCommand) {
            continue
        }

        $utilityPath = [string]$utilityCommand.Source
        if ([string]::IsNullOrWhiteSpace($utilityPath)) {
            continue
        }

        $escapedUtilityPath = $utilityPath.Replace("'", "'\''")
        $wrapperPath = Join-Path -Path $binRoot -ChildPath $utilityName
        if (Test-Path -LiteralPath $wrapperPath -PathType Leaf) {
            continue
        }

        Write-Utf8NoBomFile -Path $wrapperPath -Content @"
#!/bin/sh
exec '$escapedUtilityPath' "`$@"
"@
        & chmod +x $wrapperPath
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
    $startInfo.Arguments = '"' + $script:prePushHookPath.Replace('"', '\"') + '"'
    $startInfo.WorkingDirectory = $Harness.RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment["PATH"] = $Harness.BinRoot
    $startInfo.Environment["WALLSTOP_TEST_REPO_ROOT"] = $Harness.RepoRoot
    $startInfo.Environment["WALLSTOP_TEST_COMMAND_LOG"] = $Harness.CommandLogPath
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

        $leakedPaths = @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        $leakedPaths.Count | Should -Be 0 -Because (
            "pre-push hook EXIT trap must remove temp file lists. Leaked paths: {0}" -f ($leakedPaths -join ", ")
        )
    }
    finally {
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "pre-push changed-file hook behavior" {
    BeforeEach {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }
    }

    It "validates files changed against an existing remote ref" {
        $harness = New-PrePushHookHarness
        $stdin = "refs/heads/main local456 refs/heads/main remote123`n"

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin $stdin -Environment @{
            WALLSTOP_TEST_DIFF_OUTPUT = "Scripts/Utils/Run-PreCommitValidation.ps1`nREADME.md`n"
        }

        $result.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $result.Stdout, $result.Stderr)
        $result.Log | Should -Match 'git\tdiff\t--name-only\t--diff-filter=ACMR\tremote123\.\.local456\t--'
        $result.Log | Should -Match 'pwsh[\s\S]*Invoke-PreCommitWithRecovery\.ps1[\s\S]*-HookStage[\s\S]*pre-push[\s\S]*-FileListPath'
        $result.Log | Should -Match 'pwsh-file\tScripts/Utils/Run-PreCommitValidation\.ps1'
        $result.Log | Should -Match 'pwsh-file\tREADME\.md'
        Assert-LoggedFileListPathsWereRemoved -CommandLog $result.Log
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }

    It "uses a resolved upstream merge-base for new branches" {
        $harness = New-PrePushHookHarness
        $stdin = "refs/heads/feature local456 refs/heads/feature 0000000000000000000000000000000000000000`n"

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin $stdin -Environment @{
            WALLSTOP_TEST_UPSTREAM_REF = "origin/main"
            WALLSTOP_TEST_MERGE_BASE   = "base111"
            WALLSTOP_TEST_DIFF_OUTPUT  = "Scripts/Utils/New-Thing.ps1`n"
        }

        $result.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $result.Stdout, $result.Stderr)
        $result.Log | Should -Match 'git\trev-parse\t--abbrev-ref\t--symbolic-full-name\tfeature@\{upstream\}'
        $result.Log | Should -Match 'git\tmerge-base\tlocal456\torigin/main'
        $result.Log | Should -Match 'git\tdiff\t--name-only\t--diff-filter=ACMR\tbase111\.\.local456\t--'
        $result.Log | Should -Match 'pwsh[\s\S]*-FileListPath'
        $result.Log | Should -Match 'pwsh-file\tScripts/Utils/New-Thing\.ps1'
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }

    It "skips validation for delete pushes" {
        $harness = New-PrePushHookHarness
        $stdin = "refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature remote123`n"

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin $stdin

        $result.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $result.Stdout, $result.Stderr)
        $result.Stderr | Should -Match 'skipping delete push'
        $result.Log | Should -Not -Match 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }

    It "skips validation when pre-push receives no stdin ref updates" {
        $harness = New-PrePushHookHarness

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin ""

        $result.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $result.Stdout, $result.Stderr)
        $result.Stderr | Should -Match 'no ref updates received'
        $result.Log | Should -Not -Match 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }

    It "falls back to tracked files for new branches without any baseline" {
        $harness = New-PrePushHookHarness
        $stdin = "refs/heads/root local456 refs/heads/root 0000000000000000000000000000000000000000`n"

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin $stdin -Environment @{
            WALLSTOP_TEST_LS_FILES_OUTPUT = "README.md`nScripts/Utils/Fallback.ps1`n"
        }

        $result.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $result.Stdout, $result.Stderr)
        $result.Stderr | Should -Match 'W_PREPUSH_CHANGED_FILE_BASELINE_MISSING'
        $result.Log | Should -Match 'git\tls-files'
        $result.Log | Should -Match 'pwsh[\s\S]*-FileListPath'
        $result.Log | Should -Match 'pwsh-file\tREADME\.md'
        $result.Log | Should -Match 'pwsh-file\tScripts/Utils/Fallback\.ps1'
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }

    It "uses legacy PowerShell target-file checks when pre-commit is unavailable" {
        $harness = New-PrePushHookHarness
        Remove-Item -LiteralPath (Join-Path -Path $harness.BinRoot -ChildPath "pre-commit") -Force
        $stdin = "refs/heads/main local456 refs/heads/main remote123`n"

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin $stdin -Environment @{
            WALLSTOP_TEST_DIFF_OUTPUT = ".githooks/pre-push`n"
        }

        $result.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $result.Stdout, $result.Stderr)
        $result.Stderr | Should -Match 'pre-commit is not installed; falling back to legacy PowerShell checks'
        $result.Log | Should -Match 'pwsh[\s\S]*Scripts/Utils/Run-PreCommitValidation\.ps1[\s\S]*-IncludePreCommitOwnedChecks[\s\S]*-TargetFileListPath'
        $result.Log | Should -Match 'pwsh-file\t\.githooks/pre-push'
        Assert-LoggedFileListPathsWereRemoved -CommandLog $result.Log
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }
}
