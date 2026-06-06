# PreCommitCliHelpers.ps1
#
# Shared pre-commit CLI pin validation.

$preCommitCompatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'CompatibilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $preCommitCompatibilityHelpersPath -PathType Leaf)) {
    throw "E_VALIDATION_PRECOMMIT_COMPATIBILITY_HELPER_MISSING: Compatibility helper file not found at '$preCommitCompatibilityHelpersPath'."
}

. $preCommitCompatibilityHelpersPath

function Get-RequiredPreCommitVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $requirementsPath = Join-Path -Path $RepositoryRoot -ChildPath "requirements.txt"
    if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
        throw "E_VALIDATION_PRECOMMIT_REQUIREMENTS_MISSING: requirements.txt is required to pin the pre-commit CLI but was not found at '$requirementsPath'."
    }

    $requirementsContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $requirementsPath -ErrorAction Stop).Path, [System.Text.Encoding]::UTF8)
    $match = [System.Text.RegularExpressions.Regex]::Match($requirementsContent, '(?m)^\s*pre-commit==(?<version>[0-9]+(?:\.[0-9]+){1,3})\s*(?:#.*)?$')
    if (-not $match.Success) {
        throw "E_VALIDATION_PRECOMMIT_REQUIREMENTS_INVALID: requirements.txt must contain an exact 'pre-commit==<version>' pin."
    }

    return $match.Groups["version"].Value
}

function Get-PreCommitBootstrapVersionGuidance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string]$FallbackVersion = "<pinned-version-from-requirements.txt>"
    )

    try {
        $requiredVersion = Get-RequiredPreCommitVersion -RepositoryRoot $RepositoryRoot
        if (-not [string]::IsNullOrWhiteSpace($requiredVersion)) {
            return [pscustomobject]@{
                Version                = $requiredVersion
                IsFallback             = $false
                RequirementsDiagnostic = ""
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Version                = $FallbackVersion
            IsFallback             = $true
            RequirementsDiagnostic = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Version                = $FallbackVersion
        IsFallback             = $true
        RequirementsDiagnostic = "Get-RequiredPreCommitVersion returned an empty version."
    }
}

function Invoke-PreCommitVersionProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $PreCommitExecutable
    $processStartInfo.WorkingDirectory = $RepositoryRoot
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true

    Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList @("--version")

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Failed to kill timed-out pre-commit version probe: $($_.Exception.Message)"
            }

            throw "E_VALIDATION_PRECOMMIT_VERSION_TIMEOUT: pre-commit --version exceeded ${TimeoutSeconds}s (executable='$PreCommitExecutable')."
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.GetAwaiter().GetResult()
            Stderr   = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Assert-PreCommitCliVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    $expectedVersion = Get-RequiredPreCommitVersion -RepositoryRoot $RepositoryRoot
    $versionResult = Invoke-PreCommitVersionProbe -PreCommitExecutable $PreCommitExecutable -RepositoryRoot $RepositoryRoot -TimeoutSeconds $TimeoutSeconds
    $combinedOutput = @([string]$versionResult.Stdout, [string]$versionResult.Stderr) -join [Environment]::NewLine
    if ($versionResult.ExitCode -ne 0) {
        throw "E_VALIDATION_PRECOMMIT_VERSION_FAILED: pre-commit --version failed (exitCode=$($versionResult.ExitCode); executable='$PreCommitExecutable'; output=$combinedOutput)."
    }

    $match = [System.Text.RegularExpressions.Regex]::Match($combinedOutput, '(?m)\bpre-commit\s+(?<version>[0-9]+(?:\.[0-9]+){1,3})\b')
    if (-not $match.Success) {
        throw "E_VALIDATION_PRECOMMIT_VERSION_PARSE_FAILED: unable to parse pre-commit version from output (executable='$PreCommitExecutable'; output=$combinedOutput)."
    }

    $actualVersion = $match.Groups["version"].Value
    if ($actualVersion -ne $expectedVersion) {
        throw "E_VALIDATION_PRECOMMIT_VERSION_MISMATCH: pre-commit CLI version mismatch (expected=$expectedVersion; actual=$actualVersion; executable='$PreCommitExecutable'). Install the pinned CLI with 'pipx install --force pre-commit==$expectedVersion' or a dedicated venv (python3 -m venv ~/.local/venvs/pre-commit; ~/.local/venvs/pre-commit/bin/pip install --requirement requirements.txt; ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit)."
    }

    return [pscustomobject]@{
        ExpectedVersion = $expectedVersion
        ActualVersion   = $actualVersion
        Executable      = $PreCommitExecutable
    }
}
