[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$WatchCi,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 7200)]
    [int]$CiWatchTimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$FailureCode,

        [Parameter(Mandatory = $true)]
        [string]$Remediation
    )

    Write-Host "[validation] $Label"
    & $ScriptBlock
    $nativeExit = $LASTEXITCODE
    if ($nativeExit -ne 0) {
        throw "${FailureCode}: '$Label' failed (exitCode=$nativeExit). $Remediation"
    }
}

function Get-StatusSnapshot {
    $statusLines = @(& git status --porcelain=v1 --untracked-files=all)
    $statusExit = $LASTEXITCODE
    if ($statusExit -ne 0) {
        throw "E_VALIDATION_GIT_STATUS_FAILED: unable to read git status snapshot (exitCode=$statusExit)."
    }

    return @($statusLines | Sort-Object)
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../../..")).Path
Push-Location -Path $repoRoot

try {
    $statusBeforeValidation = Get-StatusSnapshot

    if (-not (Get-Command -Name "pre-commit" -ErrorAction SilentlyContinue)) {
        throw "E_VALIDATION_PREREQ_MISSING: pre-commit is required for full validation. Install with 'pipx install pre-commit' or use the repo-supported venv bootstrap (python3 -m venv ~/.local/venvs/pre-commit; ~/.local/venvs/pre-commit/bin/pip install pre-commit; mkdir -p ~/.local/bin; ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit; export PATH=$HOME/.local/bin:$PATH and persist that export in ~/.bashrc or ~/.zshrc), then run 'pre-commit install --hook-type pre-commit --hook-type pre-push'."
    }

    Invoke-NativeCommand -Label "pre-commit stage (all files)" -FailureCode "E_VALIDATION_PRECOMMIT_FAILED" -Remediation "Fix hook findings, then rerun this command." -ScriptBlock {
        pre-commit run --hook-stage pre-commit --all-files --show-diff-on-failure --color always
    }

    Invoke-NativeCommand -Label "pre-push stage (all files)" -FailureCode "E_VALIDATION_PREPUSH_FAILED" -Remediation "Fix failing tests/lint/policy checks, then rerun this command." -ScriptBlock {
        pre-commit run --hook-stage pre-push --all-files --show-diff-on-failure --color always
    }

    $skillsIndexScript = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1"
    $llmHarnessScript = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Test-LlmHarness.ps1"

    if (-not (Test-Path -Path $skillsIndexScript -PathType Leaf)) {
        throw "E_VALIDATION_SCRIPT_MISSING: skills index checker not found at '$skillsIndexScript'."
    }
    if (-not (Test-Path -Path $llmHarnessScript -PathType Leaf)) {
        throw "E_VALIDATION_SCRIPT_MISSING: LLM harness validator not found at '$llmHarnessScript'."
    }

    Write-Host "[validation] skills index freshness check"
    & $skillsIndexScript -Check

    Write-Host "[validation] LLM harness validation"
    & $llmHarnessScript -RootPath $repoRoot

    Write-Host "[validation] workspace drift assertion"
    $statusAfterValidation = Get-StatusSnapshot
    $statusDiff = Compare-Object -ReferenceObject $statusBeforeValidation -DifferenceObject $statusAfterValidation
    if ($null -ne $statusDiff) {
        $statusPreview = ($statusDiff | Select-Object -First 20 | ForEach-Object { "  $($_.SideIndicator) $($_.InputObject)" }) -join [Environment]::NewLine
        throw "E_VALIDATION_TREE_DRIFT: validation commands changed repository state. Re-run after applying generated fixes.`n$statusPreview"
    }

    if ($WatchCi) {
        if (-not (Get-Command -Name "gh" -ErrorAction SilentlyContinue)) {
            throw "E_VALIDATION_GH_MISSING: -WatchCi requires GitHub CLI ('gh')."
        }

        Write-Host "[validation] resolving current PR for CI watch"
        $prNumber = (& gh pr view --json number --jq ".number" 2>$null)
        $ghExit = $LASTEXITCODE
        if ($ghExit -ne 0 -or [string]::IsNullOrWhiteSpace($prNumber)) {
            throw "E_VALIDATION_PR_MISSING: -WatchCi requires an open PR for the current branch. Open a PR first, then rerun with -WatchCi."
        }

        Write-Host "[validation] watching PR checks for up to $CiWatchTimeoutSeconds seconds"
        Invoke-NativeCommand -Label "GitHub PR checks watch" -FailureCode "E_VALIDATION_CI_FAILED" -Remediation "Fix failing CI checks in this session, then rerun with -WatchCi." -ScriptBlock {
            gh pr checks $prNumber --watch --interval 10
        }
    }

    Write-Host "Full validation passed."
}
finally {
    Pop-Location
}
