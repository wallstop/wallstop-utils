# GitHookRegistrationHelpers.ps1
#
# Shared local hook registration preflight for validation/bootstrap/push workflows.

$gitHookCompatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'CompatibilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $gitHookCompatibilityHelpersPath -PathType Leaf)) {
    throw "E_HOOK_REGISTRATION_COMPATIBILITY_HELPER_MISSING: Compatibility helper file not found at '$gitHookCompatibilityHelpersPath'."
}

. $gitHookCompatibilityHelpersPath

function Get-GitHookRegistrationGitExecutableOrThrow {
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_HOOK_REGISTRATION_GIT_NOT_AVAILABLE: git is required for hook registration preflight but was not found on PATH."
    }

    Write-Verbose ("Hook registration git diagnostics: gitPath='{0}'" -f $gitCommand.Source)
    return $gitCommand.Source
}

function Invoke-GitHookRegistrationGitCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $output = @(& $GitExecutable -C $RepositoryRoot @Arguments 2> $stderrPath)
        $exitCode = $LASTEXITCODE
        $stderr = Read-RedirectedProcessText -Path $stderrPath
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    $diagnosticOutput = @($output)
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $diagnosticOutput += @($stderr -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return [pscustomobject]@{
        ExitCode         = $exitCode
        Output           = @($output)
        DiagnosticOutput = @($diagnosticOutput)
    }
}

function Get-GitHookRegistrationDiagnosticOutput {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    $diagnosticProperty = $Result.PSObject.Properties["DiagnosticOutput"]
    if ($null -ne $diagnosticProperty) {
        return @($diagnosticProperty.Value)
    }

    return @($Result.Output)
}

function Resolve-GitHookRegistrationRepositoryRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $false)]
        [string]$RepositoryRoot = ""
    )

    $candidateRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        (Get-Location).Path
    }
    else {
        (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    }

    $rootResult = Invoke-GitHookRegistrationGitCommand -GitExecutable $GitExecutable -RepositoryRoot $candidateRoot -Arguments @("rev-parse", "--show-toplevel")
    if ($rootResult.ExitCode -ne 0 -or $rootResult.Output.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$rootResult.Output[0])) {
        $outputPreview = (@(Get-GitHookRegistrationDiagnosticOutput -Result $rootResult) -join " | ")
        throw "E_HOOK_REGISTRATION_NOT_REPOSITORY: unable to determine repository root for hook registration preflight (exitCode=$($rootResult.ExitCode); workingDirectory='$candidateRoot'; outputPreview=$outputPreview)."
    }

    return (Resolve-Path -LiteralPath ([string]$rootResult.Output[0]).Trim() -ErrorAction Stop).Path
}

function ConvertTo-GitHookRegistrationNormalizedHooksPath {
    param(
        [Parameter(Mandatory = $false)]
        [string]$HooksPath = ""
    )

    return (($HooksPath.Trim()) -replace '\\', '/').TrimEnd('/')
}

function Test-GitHookRegistrationExpectedHooksPath {
    param(
        [Parameter(Mandatory = $false)]
        [string]$HooksPath = ""
    )

    return ((ConvertTo-GitHookRegistrationNormalizedHooksPath -HooksPath $HooksPath) -eq ".githooks")
}

function Assert-GitHookRegistrationWrapper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$HookName
    )

    $hookPath = Join-Path -Path (Join-Path -Path $RepositoryRoot -ChildPath ".githooks") -ChildPath $HookName
    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
        throw "E_HOOK_REGISTRATION_WRAPPER_MISSING: required git hook wrapper '$HookName' was not found at '$hookPath'."
    }

    if (-not (Test-IsWindowsPlatform)) {
        $item = Get-Item -LiteralPath $hookPath -ErrorAction Stop
        $unixModeProperty = $item.PSObject.Properties["UnixMode"]
        $isExecutable = $false
        if ($null -ne $unixModeProperty) {
            $modeText = [string]$unixModeProperty.Value
            $isExecutable = (-not [string]::IsNullOrWhiteSpace($modeText) -and $modeText -match '^.{3}[xstST]|^.{6}[xstST]|^.{9}[xstST]')
        }

        if (-not $isExecutable) {
            $testCommand = @(Get-Command -Name "test" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            $testCommandPath = if ($null -ne $testCommand -and -not [string]::IsNullOrWhiteSpace([string]$testCommand.Path)) {
                [string]$testCommand.Path
            }
            elseif ($null -ne $testCommand -and -not [string]::IsNullOrWhiteSpace([string]$testCommand.Source)) {
                [string]$testCommand.Source
            }
            else {
                ""
            }

            if (-not [string]::IsNullOrWhiteSpace($testCommandPath)) {
                & $testCommandPath -x $hookPath
                $isExecutable = ($LASTEXITCODE -eq 0)
            }
        }

        if (-not $isExecutable) {
            throw "E_HOOK_REGISTRATION_WRAPPER_NOT_EXECUTABLE: required git hook wrapper '$HookName' is not executable at '$hookPath'."
        }
    }
}

function Assert-GitHookRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$RepositoryRoot = "",

        [Parameter(Mandatory = $false)]
        [switch]$Repair
    )

    $gitExecutable = Get-GitHookRegistrationGitExecutableOrThrow
    $resolvedRepositoryRoot = Resolve-GitHookRegistrationRepositoryRoot -GitExecutable $gitExecutable -RepositoryRoot $RepositoryRoot

    foreach ($hookName in @("pre-commit", "pre-push")) {
        Assert-GitHookRegistrationWrapper -RepositoryRoot $resolvedRepositoryRoot -HookName $hookName
    }

    $configResult = Invoke-GitHookRegistrationGitCommand -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Arguments @("config", "--get", "core.hooksPath")
    $configuredHooksPath = if ($configResult.Output.Count -gt 0) { [string]$configResult.Output[0] } else { "" }

    if (-not (Test-GitHookRegistrationExpectedHooksPath -HooksPath $configuredHooksPath)) {
        if (-not $Repair) {
            throw "E_HOOK_REGISTRATION_PATH_MISMATCH: core.hooksPath is '$configuredHooksPath'; expected '.githooks' (repositoryRoot='$resolvedRepositoryRoot')."
        }

        $setResult = Invoke-GitHookRegistrationGitCommand -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Arguments @("config", "--local", "core.hooksPath", ".githooks")
        if ($setResult.ExitCode -ne 0) {
            $outputPreview = (@(Get-GitHookRegistrationDiagnosticOutput -Result $setResult) -join " | ")
            throw "E_HOOK_REGISTRATION_CONFIG_SET_FAILED: failed to set local core.hooksPath to '.githooks' (exitCode=$($setResult.ExitCode); repositoryRoot='$resolvedRepositoryRoot'; outputPreview=$outputPreview)."
        }

        $configResult = Invoke-GitHookRegistrationGitCommand -GitExecutable $gitExecutable -RepositoryRoot $resolvedRepositoryRoot -Arguments @("config", "--get", "core.hooksPath")
        $configuredHooksPath = if ($configResult.Output.Count -gt 0) { [string]$configResult.Output[0] } else { "" }
    }

    if (-not (Test-GitHookRegistrationExpectedHooksPath -HooksPath $configuredHooksPath)) {
        throw "E_HOOK_REGISTRATION_VERIFY_FAILED: core.hooksPath verification failed after repair (actual='$configuredHooksPath'; expected='.githooks'; repositoryRoot='$resolvedRepositoryRoot')."
    }

    return [pscustomobject]@{
        RepositoryRoot = $resolvedRepositoryRoot
        HooksPath      = ".githooks"
        GitExecutable  = $gitExecutable
    }
}
