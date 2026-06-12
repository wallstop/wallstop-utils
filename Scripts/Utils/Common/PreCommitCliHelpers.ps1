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

function Get-PreCommitCommandExecutablePath {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$CommandInfo = $null
    )

    if ($null -eq $CommandInfo) {
        return ""
    }

    if ($null -ne $CommandInfo.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$CommandInfo.Source)) {
        return [string]$CommandInfo.Source
    }

    if ($null -ne $CommandInfo.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$CommandInfo.Path)) {
        return [string]$CommandInfo.Path
    }

    return ""
}

function Get-PreCommitFailureOutputPreview {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Output = "",

        [Parameter(Mandatory = $false)]
        [ValidateRange(120, 2000)]
        [int]$MaxLength = 400
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return "<empty>"
    }

    $collapsed = ($Output -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($collapsed)) {
        return "<empty>"
    }

    if ($collapsed.Length -le $MaxLength) {
        return $collapsed
    }

    return ("{0}..." -f $collapsed.Substring(0, $MaxLength))
}

function Get-PreCommitRemainingTimeoutSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$DeadlineUtc
    )

    $remainingSeconds = [int][math]::Ceiling(($DeadlineUtc - [datetime]::UtcNow).TotalSeconds)
    if ($remainingSeconds -lt 0) {
        return 0
    }

    return $remainingSeconds
}

function Invoke-PreCommitExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1800)]
        [int]$TimeoutSeconds = 120,

        [Parameter(Mandatory = $false)]
        [string]$ContextLabel = "external command"
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $Executable
    $processStartInfo.WorkingDirectory = $RepositoryRoot
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList $Arguments

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    try {
        try {
            [void]$process.Start()
        }
        catch {
            return [pscustomobject]@{
                ExitCode    = 1
                Stdout      = ""
                Stderr      = "E_VALIDATION_PRECOMMIT_COMMAND_START_FAILED: failed to start ${ContextLabel} executable '$Executable'. $($_.Exception.Message)"
                TimedOut    = $false
                StartFailed = $true
            }
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                Write-Verbose "Failed to kill timed-out ${ContextLabel}: $($_.Exception.Message)"
            }

            return [pscustomobject]@{
                ExitCode    = 124
                Stdout      = $stdoutTask.GetAwaiter().GetResult()
                Stderr      = "E_VALIDATION_PRECOMMIT_COMMAND_TIMEOUT: ${ContextLabel} exceeded ${TimeoutSeconds}s (executable='$Executable').`n$($stderrTask.GetAwaiter().GetResult())"
                TimedOut    = $true
                StartFailed = $false
            }
        }

        return [pscustomobject]@{
            ExitCode    = [int]$process.ExitCode
            Stdout      = $stdoutTask.GetAwaiter().GetResult()
            Stderr      = $stderrTask.GetAwaiter().GetResult()
            TimedOut    = $false
            StartFailed = $false
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-PreCommitCandidateExecutablePaths {
    [OutputType([string[]])]
    param()

    $candidatePaths = New-Object System.Collections.Generic.List[string]
    $pathComparer = if (Test-IsWindowsPlatform) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)

    $preCommitCommands = @(Get-Command -Name "pre-commit" -All -ErrorAction SilentlyContinue)
    foreach ($preCommitCommand in $preCommitCommands) {
        $candidatePath = Get-PreCommitCommandExecutablePath -CommandInfo $preCommitCommand
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }

        if ($seenPaths.Add($candidatePath)) {
            $candidatePaths.Add($candidatePath) | Out-Null
        }
    }

    $homePathVariable = Get-Variable -Name "HOME" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $homePathVariable -and -not [string]::IsNullOrWhiteSpace([string]$homePathVariable)) {
        $homePath = [string]$homePathVariable
        $preCommitExecutableName = if (Test-IsWindowsPlatform) {
            "pre-commit.exe"
        }
        else {
            "pre-commit"
        }

        $venvFallbackCandidate = if (Test-IsWindowsPlatform) {
            Join-Path -Path $homePath -ChildPath ".local/venvs/pre-commit/Scripts/pre-commit.exe"
        }
        else {
            Join-Path -Path $homePath -ChildPath ".local/venvs/pre-commit/bin/pre-commit"
        }

        $fallbackCandidates = @(
            (Join-Path -Path $homePath -ChildPath (Join-Path -Path ".local/bin" -ChildPath $preCommitExecutableName)),
            $venvFallbackCandidate
        )

        foreach ($fallbackCandidate in $fallbackCandidates) {
            if ([string]::IsNullOrWhiteSpace([string]$fallbackCandidate)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $fallbackCandidate -PathType Leaf)) {
                continue
            }

            if ($seenPaths.Add($fallbackCandidate)) {
                $candidatePaths.Add($fallbackCandidate) | Out-Null
            }
        }
    }

    return @($candidatePaths.ToArray())
}

function Get-PreCommitVersionProbeClassification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreCommitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    try {
        $versionResult = Invoke-PreCommitVersionProbe -PreCommitExecutable $PreCommitExecutable -RepositoryRoot $RepositoryRoot -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        return [pscustomobject]@{
            Status        = if ($_.Exception.Message -match "\bE_VALIDATION_PRECOMMIT_VERSION_TIMEOUT\b") { "timeout" } else { "probe_failed" }
            ActualVersion = ""
            Diagnostic    = [string]$_.Exception.Message
        }
    }

    $combinedOutput = @([string]$versionResult.Stdout, [string]$versionResult.Stderr) -join [Environment]::NewLine
    if ($versionResult.ExitCode -ne 0) {
        return [pscustomobject]@{
            Status        = "invoke_failed"
            ActualVersion = ""
            Diagnostic    = "E_VALIDATION_PRECOMMIT_VERSION_FAILED: pre-commit --version failed (exitCode=$($versionResult.ExitCode); executable='$PreCommitExecutable'; output=$(Get-PreCommitFailureOutputPreview -Output $combinedOutput))."
        }
    }

    $versionMatch = [System.Text.RegularExpressions.Regex]::Match($combinedOutput, '(?m)\bpre-commit\s+(?<version>[0-9]+(?:\.[0-9]+){1,3})\b')
    if (-not $versionMatch.Success) {
        return [pscustomobject]@{
            Status        = "parse_failed"
            ActualVersion = ""
            Diagnostic    = "E_VALIDATION_PRECOMMIT_VERSION_PARSE_FAILED: unable to parse pre-commit version from output (executable='$PreCommitExecutable'; output=$(Get-PreCommitFailureOutputPreview -Output $combinedOutput))."
        }
    }

    $actualVersion = $versionMatch.Groups["version"].Value
    if ($actualVersion -ne $ExpectedVersion) {
        return [pscustomobject]@{
            Status        = "mismatch"
            ActualVersion = $actualVersion
            Diagnostic    = "E_VALIDATION_PRECOMMIT_VERSION_MISMATCH: pre-commit CLI version mismatch (expected=$ExpectedVersion; actual=$actualVersion; executable='$PreCommitExecutable')."
        }
    }

    return [pscustomobject]@{
        Status        = "ok"
        ActualVersion = $actualVersion
        Diagnostic    = ""
    }
}

function Invoke-PreCommitCliAutoRepair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion,

        [Parameter(Mandatory = $false)]
        [ValidateRange(30, 1800)]
        [int]$TimeoutSeconds = 240
    )

    $repairDeadlineUtc = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $repairDiagnostics = New-Object System.Collections.Generic.List[string]

    $uvCommand = Get-Command -Name "uv" -ErrorAction SilentlyContinue
    $uvCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $uvCommand
    if (-not [string]::IsNullOrWhiteSpace($uvCommandPath)) {
        $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
        if ($remainingSeconds -gt 0) {
            $uvTimeoutSeconds = [Math]::Min($remainingSeconds, 180)
            $uvResult = Invoke-PreCommitExternalCommand -Executable $uvCommandPath -Arguments @("tool", "install", "--force", "pre-commit==$ExpectedVersion") -RepositoryRoot $RepositoryRoot -TimeoutSeconds $uvTimeoutSeconds -ContextLabel "uv tool install pre-commit==$ExpectedVersion"
            if ($uvResult.ExitCode -eq 0) {
                return [pscustomobject]@{
                    Succeeded          = $true
                    Strategy           = "uv-tool-install"
                    RepairedExecutable = ""
                    Diagnostics        = @()
                }
            }

            $repairDiagnostics.Add("uv strategy failed (exitCode=$([int]$uvResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (@([string]$uvResult.Stdout, [string]$uvResult.Stderr -join [Environment]::NewLine)))).") | Out-Null
        }
    }

    $pipxCommand = Get-Command -Name "pipx" -ErrorAction SilentlyContinue
    $pipxCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $pipxCommand
    if (-not [string]::IsNullOrWhiteSpace($pipxCommandPath)) {
        $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
        if ($remainingSeconds -gt 0) {
            $pipxTimeoutSeconds = [Math]::Min($remainingSeconds, 180)
            $pipxResult = Invoke-PreCommitExternalCommand -Executable $pipxCommandPath -Arguments @("install", "--force", "pre-commit==$ExpectedVersion") -RepositoryRoot $RepositoryRoot -TimeoutSeconds $pipxTimeoutSeconds -ContextLabel "pipx install pre-commit==$ExpectedVersion"
            if ($pipxResult.ExitCode -eq 0) {
                return [pscustomobject]@{
                    Succeeded          = $true
                    Strategy           = "pipx-install"
                    RepairedExecutable = ""
                    Diagnostics        = @()
                }
            }

            $repairDiagnostics.Add("pipx strategy failed (exitCode=$([int]$pipxResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (@([string]$pipxResult.Stdout, [string]$pipxResult.Stderr -join [Environment]::NewLine)))).") | Out-Null
        }
    }

    $homePathVariable = Get-Variable -Name "HOME" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $homePathVariable -or [string]::IsNullOrWhiteSpace([string]$homePathVariable)) {
        $repairDiagnostics.Add("venv strategy skipped because HOME is unavailable.") | Out-Null
    }
    else {
        $homePath = [string]$homePathVariable
        $venvPath = Join-Path -Path $homePath -ChildPath ".local/venvs/pre-commit"
        $venvPythonPath = if (Test-IsWindowsPlatform) {
            Join-Path -Path $venvPath -ChildPath "Scripts/python.exe"
        }
        else {
            Join-Path -Path $venvPath -ChildPath "bin/python"
        }
        $venvPreCommitPath = if (Test-IsWindowsPlatform) {
            Join-Path -Path $venvPath -ChildPath "Scripts/pre-commit.exe"
        }
        else {
            Join-Path -Path $venvPath -ChildPath "bin/pre-commit"
        }

        $pythonLauncherPath = ""
        $pythonLauncherArguments = @()
        if (Test-IsWindowsPlatform) {
            $pyCommand = Get-Command -Name "py" -ErrorAction SilentlyContinue
            $pyCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $pyCommand
            if (-not [string]::IsNullOrWhiteSpace($pyCommandPath)) {
                $pythonLauncherPath = $pyCommandPath
                $pythonLauncherArguments = @("-3", "-m", "venv", $venvPath)
            }
        }

        if ([string]::IsNullOrWhiteSpace($pythonLauncherPath)) {
            foreach ($pythonCandidate in @("python3", "python")) {
                $pythonCommand = Get-Command -Name $pythonCandidate -ErrorAction SilentlyContinue
                $pythonCommandPath = Get-PreCommitCommandExecutablePath -CommandInfo $pythonCommand
                if (-not [string]::IsNullOrWhiteSpace($pythonCommandPath)) {
                    $pythonLauncherPath = $pythonCommandPath
                    $pythonLauncherArguments = @("-m", "venv", $venvPath)
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($pythonLauncherPath)) {
            $repairDiagnostics.Add("venv strategy skipped because no python launcher was found (tried: py, python3, python).") | Out-Null
        }
        else {
            if (Test-Path -LiteralPath $venvPath) {
                try {
                    Remove-Item -LiteralPath $venvPath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    $repairDiagnostics.Add("venv strategy could not remove stale venv at '$venvPath'. $($_.Exception.Message)") | Out-Null
                }
            }

            $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
            if ($remainingSeconds -gt 0) {
                $venvCreateTimeoutSeconds = [Math]::Min($remainingSeconds, 180)
                $venvCreateResult = Invoke-PreCommitExternalCommand -Executable $pythonLauncherPath -Arguments $pythonLauncherArguments -RepositoryRoot $RepositoryRoot -TimeoutSeconds $venvCreateTimeoutSeconds -ContextLabel "python venv bootstrap"
                if ($venvCreateResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $venvPythonPath -PathType Leaf)) {
                    $remainingSeconds = Get-PreCommitRemainingTimeoutSeconds -DeadlineUtc $repairDeadlineUtc
                    if ($remainingSeconds -gt 0) {
                        $pipInstallTimeoutSeconds = [Math]::Min($remainingSeconds, 240)
                        $pipInstallResult = Invoke-PreCommitExternalCommand -Executable $venvPythonPath -Arguments @("-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pre-commit==$ExpectedVersion") -RepositoryRoot $RepositoryRoot -TimeoutSeconds $pipInstallTimeoutSeconds -ContextLabel "venv pip install pre-commit==$ExpectedVersion"
                        if ($pipInstallResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $venvPreCommitPath -PathType Leaf)) {
                            return [pscustomobject]@{
                                Succeeded          = $true
                                Strategy           = "python-venv"
                                RepairedExecutable = $venvPreCommitPath
                                Diagnostics        = @()
                            }
                        }

                        $repairDiagnostics.Add("venv pip install failed (exitCode=$([int]$pipInstallResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (@([string]$pipInstallResult.Stdout, [string]$pipInstallResult.Stderr -join [Environment]::NewLine)))).") | Out-Null
                    }
                }
                else {
                    $repairDiagnostics.Add("venv bootstrap failed (exitCode=$([int]$venvCreateResult.ExitCode); output=$(Get-PreCommitFailureOutputPreview -Output (@([string]$venvCreateResult.Stdout, [string]$venvCreateResult.Stderr -join [Environment]::NewLine)))).") | Out-Null
                }
            }
        }
    }

    return [pscustomobject]@{
        Succeeded          = $false
        Strategy           = ""
        RepairedExecutable = ""
        Diagnostics        = @($repairDiagnostics.ToArray())
    }
}

function Resolve-PreCommitCliExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30,

        [Parameter(Mandatory = $false)]
        [switch]$EnableAutoRepair,

        [Parameter(Mandatory = $false)]
        [ValidateRange(30, 1800)]
        [int]$AutoRepairTimeoutSeconds = 240
    )

    $expectedVersion = Get-RequiredPreCommitVersion -RepositoryRoot $RepositoryRoot
    $probeDiagnostics = New-Object System.Collections.Generic.List[string]
    $mismatchDiagnostics = New-Object System.Collections.Generic.List[string]

    $probeCandidates = @(Get-PreCommitCandidateExecutablePaths)
    $resolved = $null

    foreach ($probeCandidate in $probeCandidates) {
        if (-not (Test-Path -LiteralPath $probeCandidate -PathType Leaf)) {
            continue
        }

        $probeResult = Get-PreCommitVersionProbeClassification -PreCommitExecutable $probeCandidate -RepositoryRoot $RepositoryRoot -ExpectedVersion $expectedVersion -TimeoutSeconds $TimeoutSeconds
        if ($probeResult.Status -eq "ok") {
            $resolved = [pscustomobject]@{
                Executable      = $probeCandidate
                ExpectedVersion = $expectedVersion
                ActualVersion   = [string]$probeResult.ActualVersion
                AutoRepaired    = $false
            }
            break
        }

        if ($probeResult.Status -eq "timeout") {
            throw [string]$probeResult.Diagnostic
        }

        if ($probeResult.Status -eq "mismatch") {
            $mismatchDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
        }
        else {
            $probeDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
        }
    }

    if ($null -eq $resolved -and $EnableAutoRepair) {
        Write-Warning "W_VALIDATION_PRECOMMIT_AUTO_REPAIR: no healthy pinned pre-commit executable found; attempting automatic CLI repair."
        $repairResult = Invoke-PreCommitCliAutoRepair -RepositoryRoot $RepositoryRoot -ExpectedVersion $expectedVersion -TimeoutSeconds $AutoRepairTimeoutSeconds
        foreach ($repairDiagnostic in @($repairResult.Diagnostics)) {
            $probeDiagnostics.Add([string]$repairDiagnostic) | Out-Null
        }

        if (-not $repairResult.Succeeded) {
            $diagnosticPreview = Get-PreCommitFailureOutputPreview -Output ($probeDiagnostics.ToArray() -join " ")
            throw (
                "E_VALIDATION_PRECOMMIT_AUTO_REPAIR_FAILED: unable to automatically repair pre-commit CLI to pinned version $expectedVersion. diagnostics=$diagnosticPreview"
            )
        }

        $postRepairCandidates = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace([string]$repairResult.RepairedExecutable)) {
            $postRepairCandidates.Add([string]$repairResult.RepairedExecutable) | Out-Null
        }
        foreach ($candidatePath in @(Get-PreCommitCandidateExecutablePaths)) {
            $postRepairCandidates.Add([string]$candidatePath) | Out-Null
        }

        $pathComparer = if (Test-IsWindowsPlatform) {
            [System.StringComparer]::OrdinalIgnoreCase
        }
        else {
            [System.StringComparer]::Ordinal
        }
        $seenPostRepair = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
        foreach ($postRepairCandidate in @($postRepairCandidates.ToArray())) {
            if ([string]::IsNullOrWhiteSpace([string]$postRepairCandidate)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $postRepairCandidate -PathType Leaf)) {
                continue
            }

            if (-not $seenPostRepair.Add([string]$postRepairCandidate)) {
                continue
            }

            $probeResult = Get-PreCommitVersionProbeClassification -PreCommitExecutable $postRepairCandidate -RepositoryRoot $RepositoryRoot -ExpectedVersion $expectedVersion -TimeoutSeconds $TimeoutSeconds
            if ($probeResult.Status -eq "ok") {
                $resolved = [pscustomobject]@{
                    Executable      = [string]$postRepairCandidate
                    ExpectedVersion = $expectedVersion
                    ActualVersion   = [string]$probeResult.ActualVersion
                    AutoRepaired    = $true
                }
                break
            }

            if ($probeResult.Status -eq "timeout") {
                throw [string]$probeResult.Diagnostic
            }

            if ($probeResult.Status -eq "mismatch") {
                $mismatchDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
            }
            else {
                $probeDiagnostics.Add([string]$probeResult.Diagnostic) | Out-Null
            }
        }
    }

    if ($null -ne $resolved) {
        return $resolved
    }

    if ($mismatchDiagnostics.Count -gt 0 -and $probeDiagnostics.Count -eq 0) {
        $mismatchPreview = Get-PreCommitFailureOutputPreview -Output ($mismatchDiagnostics.ToArray() -join " ")
        throw (
            "E_VALIDATION_PRECOMMIT_VERSION_MISMATCH: no discovered pre-commit executable matches the pinned version $expectedVersion. diagnostics=$mismatchPreview Install the pinned CLI with 'pipx install --force pre-commit==$expectedVersion' or a dedicated venv (python3 -m venv ~/.local/venvs/pre-commit; ~/.local/venvs/pre-commit/bin/pip install --requirement requirements.txt; ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit)."
        )
    }

    if ($probeCandidates.Count -eq 0) {
        throw (
            "E_VALIDATION_PRECOMMIT_NOT_AVAILABLE: pre-commit is not available on PATH and no managed fallback executable was found. Install the pinned CLI with 'pipx install --force pre-commit==$expectedVersion' or a dedicated venv (python3 -m venv ~/.local/venvs/pre-commit; ~/.local/venvs/pre-commit/bin/pip install --requirement requirements.txt; ln -sf ~/.local/venvs/pre-commit/bin/pre-commit ~/.local/bin/pre-commit)."
        )
    }

    $diagnosticPreview = Get-PreCommitFailureOutputPreview -Output ($probeDiagnostics.ToArray() -join " ")
    throw (
        "E_VALIDATION_PRECOMMIT_RESOLUTION_FAILED: unable to execute a healthy pinned pre-commit CLI (expectedVersion=$expectedVersion; candidatesTried=$($probeCandidates.Count); diagnostics=$diagnosticPreview)."
    )
}
