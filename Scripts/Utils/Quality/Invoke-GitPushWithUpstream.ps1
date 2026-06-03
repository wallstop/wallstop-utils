[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Remote = "origin",

    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = "",

    [Parameter(Mandatory = $false)]
    [switch]$NoInvokeMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -LiteralPath $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_GIT_PUSH_DIAGNOSTICS_HELPER_MISSING: diagnostics helper file not found at '$diagnosticsHelpersPath'."
}
. $diagnosticsHelpersPath

$gitHookRegistrationHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/GitHookRegistrationHelpers.ps1"
if (-not (Test-Path -LiteralPath $gitHookRegistrationHelpersPath -PathType Leaf)) {
    throw "E_GIT_PUSH_HOOK_REGISTRATION_HELPER_MISSING: hook registration helper file not found at '$gitHookRegistrationHelpersPath'."
}
. $gitHookRegistrationHelpersPath

function Get-GitPushGitExecutableOrThrow {
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_GIT_PUSH_GIT_NOT_AVAILABLE: git is required for push automation but was not found on PATH."
    }

    Write-Verbose ("Git push diagnostics: gitPath='{0}'" -f $gitCommand.Source)
    return $gitCommand.Source
}

function Invoke-GitPushCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& $GitExecutable -C $RepositoryRoot @Arguments 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

function Write-GitPushCommandOutput {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    foreach ($line in @($Result.Output)) {
        Write-Host $line
    }
}

function Assert-GitPushCommandSucceeded {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result,

        [Parameter(Mandatory = $true)]
        [string]$FailureCode,

        [Parameter(Mandatory = $true)]
        [string]$FailureContext,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    if ($Result.ExitCode -eq 0) {
        return
    }

    $outputPreview = Get-OutputPreview -OutputLines @($Result.Output)
    throw "${FailureCode}: $FailureContext failed (exitCode=$($Result.ExitCode); repositoryRoot='$RepositoryRoot'; outputPreview=$outputPreview)."
}

function Resolve-GitPushRepositoryRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $false)]
        [string]$RequestedRepositoryRoot = ""
    )

    $candidateRoot = if ([string]::IsNullOrWhiteSpace($RequestedRepositoryRoot)) {
        (Get-Location).Path
    }
    else {
        (Resolve-Path -LiteralPath $RequestedRepositoryRoot -ErrorAction Stop).Path
    }

    $rootResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $candidateRoot -Arguments @("rev-parse", "--show-toplevel")
    Assert-GitPushCommandSucceeded -Result $rootResult -FailureCode "E_GIT_PUSH_NOT_REPOSITORY" -FailureContext "repository root discovery" -RepositoryRoot $candidateRoot
    if ($rootResult.Output.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$rootResult.Output[0])) {
        throw "E_GIT_PUSH_NOT_REPOSITORY: repository root discovery returned no path (repositoryRoot='$candidateRoot')."
    }

    return (Resolve-Path -LiteralPath ([string]$rootResult.Output[0]).Trim() -ErrorAction Stop).Path
}

function Get-GitPushCurrentBranchOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $branchResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD")
    if ($branchResult.ExitCode -ne 0 -or $branchResult.Output.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$branchResult.Output[0])) {
        throw "E_GIT_PUSH_DETACHED_HEAD: refusing to push from detached HEAD (repositoryRoot='$RepositoryRoot')."
    }

    $headResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "--verify", "HEAD")
    if ($headResult.ExitCode -ne 0) {
        throw "E_GIT_PUSH_UNBORN_BRANCH: refusing to push unborn branch '$([string]$branchResult.Output[0])' before an initial commit exists (repositoryRoot='$RepositoryRoot')."
    }

    return ([string]$branchResult.Output[0]).Trim()
}

function Test-GitPushUpstreamExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $upstreamResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    return ($upstreamResult.ExitCode -eq 0 -and $upstreamResult.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$upstreamResult.Output[0]))
}

function Get-GitPushUpstreamRemoteOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $remoteResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("config", "--get", "branch.$BranchName.remote")
    if ($remoteResult.ExitCode -ne 0 -or $remoteResult.Output.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$remoteResult.Output[0])) {
        $outputPreview = Get-OutputPreview -OutputLines @($remoteResult.Output)
        throw "E_GIT_PUSH_UPSTREAM_REMOTE_UNRESOLVED: unable to resolve upstream remote for branch '$BranchName' (repositoryRoot='$RepositoryRoot'; outputPreview=$outputPreview)."
    }

    return ([string]$remoteResult.Output[0]).Trim()
}

function Assert-GitPushRemoteExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Remote
    )

    $remoteResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("remote", "get-url", $Remote)
    if ($remoteResult.ExitCode -ne 0) {
        $outputPreview = Get-OutputPreview -OutputLines @($remoteResult.Output)
        throw "E_GIT_PUSH_REMOTE_MISSING: remote '$Remote' was not found (repositoryRoot='$RepositoryRoot'; outputPreview=$outputPreview)."
    }
}

function Test-GitPushRemoteBranchExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Remote,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $remoteBranchResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("ls-remote", "--heads", $Remote, $BranchName)
    Assert-GitPushCommandSucceeded -Result $remoteBranchResult -FailureCode "E_GIT_PUSH_REMOTE_QUERY_FAILED" -FailureContext "remote branch query" -RepositoryRoot $RepositoryRoot
    return ($remoteBranchResult.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace(([string]$remoteBranchResult.Output[0]).Trim()))
}

function Assert-GitPushRemoteBranchAncestor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Remote,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $remoteTrackingRef = "refs/remotes/$Remote/$BranchName"
    $fetchRefSpec = "+refs/heads/${BranchName}:$remoteTrackingRef"
    $fetchResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("fetch", "--no-tags", $Remote, $fetchRefSpec)
    Assert-GitPushCommandSucceeded -Result $fetchResult -FailureCode "E_GIT_PUSH_FETCH_FAILED" -FailureContext "remote branch fetch" -RepositoryRoot $RepositoryRoot

    $ancestorResult = Invoke-GitPushCommand -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Arguments @("merge-base", "--is-ancestor", $remoteTrackingRef, "HEAD")
    if ($ancestorResult.ExitCode -eq 0) {
        return
    }

    if ($ancestorResult.ExitCode -eq 1) {
        throw "E_GIT_PUSH_REMOTE_BRANCH_DIVERGED: remote branch '$Remote/$BranchName' is not an ancestor of HEAD; refusing to set upstream or push (repositoryRoot='$RepositoryRoot')."
    }

    $outputPreview = Get-OutputPreview -OutputLines @($ancestorResult.Output)
    throw "E_GIT_PUSH_ANCESTRY_FAILED: unable to compare remote branch '$Remote/$BranchName' with HEAD (exitCode=$($ancestorResult.ExitCode); repositoryRoot='$RepositoryRoot'; outputPreview=$outputPreview)."
}

function Invoke-GitPushWithUpstreamMain {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SelectedRemote,

        [Parameter(Mandatory = $false)]
        [string]$RequestedRepositoryRoot = "",

        [Parameter(Mandatory = $false)]
        [bool]$RemoteWasSpecified = $false
    )

    $gitExecutable = Get-GitPushGitExecutableOrThrow
    $resolvedRepositoryRoot = Resolve-GitPushRepositoryRoot -GitExecutable $gitExecutable -RequestedRepositoryRoot $RequestedRepositoryRoot
    [void](Assert-GitHookRegistration -RepositoryRoot $resolvedRepositoryRoot -Repair)
    $branchName = Get-GitPushCurrentBranchOrThrow -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot

    if (Test-GitPushUpstreamExists -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot) {
        if ($RemoteWasSpecified) {
            $upstreamRemote = Get-GitPushUpstreamRemoteOrThrow -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -BranchName $branchName
            if ($upstreamRemote -ne $SelectedRemote) {
                throw "E_GIT_PUSH_REMOTE_MISMATCH: branch '$branchName' already tracks remote '$upstreamRemote', but -Remote '$SelectedRemote' was requested (repositoryRoot='$resolvedRepositoryRoot')."
            }

            $explicitPushResult = Invoke-GitPushCommand -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Arguments @("push", $SelectedRemote, "HEAD")
            Write-GitPushCommandOutput -Result $explicitPushResult
            if ($explicitPushResult.ExitCode -ne 0) {
                [Console]::Error.WriteLine("E_GIT_PUSH_FAILED: git push $SelectedRemote HEAD failed for existing upstream (exitCode=$($explicitPushResult.ExitCode); repositoryRoot='$resolvedRepositoryRoot').")
            }

            return [int]$explicitPushResult.ExitCode
        }

        $pushResult = Invoke-GitPushCommand -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Arguments @("push")
        Write-GitPushCommandOutput -Result $pushResult
        if ($pushResult.ExitCode -ne 0) {
            [Console]::Error.WriteLine("E_GIT_PUSH_FAILED: git push failed for existing upstream (exitCode=$($pushResult.ExitCode); repositoryRoot='$resolvedRepositoryRoot').")
        }
        return [int]$pushResult.ExitCode
    }

    Assert-GitPushRemoteExists -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Remote $SelectedRemote

    if (Test-GitPushRemoteBranchExists -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Remote $SelectedRemote -BranchName $branchName) {
        Assert-GitPushRemoteBranchAncestor -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Remote $SelectedRemote -BranchName $branchName
    }

    $pushWithUpstreamResult = Invoke-GitPushCommand -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Arguments @("push", "-u", $SelectedRemote, "HEAD")
    Write-GitPushCommandOutput -Result $pushWithUpstreamResult
    if ($pushWithUpstreamResult.ExitCode -ne 0) {
        [Console]::Error.WriteLine("E_GIT_PUSH_FAILED: git push -u $SelectedRemote HEAD failed (exitCode=$($pushWithUpstreamResult.ExitCode); repositoryRoot='$resolvedRepositoryRoot').")
    }

    return [int]$pushWithUpstreamResult.ExitCode
}

if (-not $NoInvokeMain) {
    $exitCode = Invoke-GitPushWithUpstreamMain -SelectedRemote $Remote -RequestedRepositoryRoot $RepositoryRoot -RemoteWasSpecified:$PSBoundParameters.ContainsKey("Remote")
    exit $exitCode
}
