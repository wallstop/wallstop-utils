[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$WithAdmin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-CurrentPlatformName {
    if (Test-IsWindowsPlatform) {
        return "Windows"
    }

    if (Test-IsMacOSPlatform) {
        return "macOS"
    }

    if (Test-IsLinuxPlatform) {
        return "Linux"
    }

    return "Unknown"
}

function Test-UpdateRunningElevated {
    # Administrator detection is meaningful only on Windows; POSIX hosts report $false and
    # callers treat elevation as unsupported there instead of probing sudo interactively.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-IsWindowsPlatform)) {
        return $false
    }

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-UpdateElevationAction {
    # Pure decision for the -WithAdmin contract so every branch stays unit-testable without
    # spawning a UAC prompt: default runs stay headless/no-prompt; -WithAdmin relaunches the
    # script elevated exactly once on Windows and degrades to a platform warning elsewhere.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$WithAdmin,

        [Parameter(Mandatory = $true)]
        [bool]$IsWindowsPlatform,

        [Parameter(Mandatory = $true)]
        [bool]$IsRunningElevated
    )

    if (-not $WithAdmin) {
        return [pscustomobject]@{ Action = "Proceed"; Reason = "default-headless-run" }
    }

    if (-not $IsWindowsPlatform) {
        return [pscustomobject]@{
            Action   = "WarnUnsupportedPlatform"
            Reason   = "elevation-is-windows-only"
            Code     = "W_UPDATE_ELEVATION_UNSUPPORTED_PLATFORM"
            Detail   = "-WithAdmin requires Windows UAC elevation; continuing headless without it."
        }
    }

    if ($IsRunningElevated) {
        return [pscustomobject]@{ Action = "Proceed"; Reason = "already-running-elevated" }
    }

    return [pscustomobject]@{ Action = "RelaunchElevated"; Reason = "admin-opt-in-relaunch" }
}

function Get-UpdateSelfRelaunchArguments {
    # Token list handed to Set-PortableProcessArguments when re-spawning this script under
    # elevation. Kept pure and argument-shaped so tests can pin the exact relay contract.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    return @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath, "-WithAdmin") # array-unwrap-safe: callers wrap in @(...).
}

function Resolve-UpdateElevationStartFailure {
    # Pure seam for Process.Start failures so decline-vs-environment triage stays testable
    # without spawning UAC prompts. ERROR_CANCELLED (1223) is the operator-declining-UAC
    # shape; everything else is E_UPDATE_ELEVATION_START_FAILED.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$IsWin32Exception,

        # Meaningful only when $IsWin32Exception is $true.
        [Parameter(Mandatory = $true)]
        [int]$NativeErrorCode,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExceptionTypeName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExceptionMessage
    )

    if ($IsWin32Exception -and $NativeErrorCode -eq 1223) {
        return [pscustomobject]@{
            Code   = "E_UPDATE_ELEVATION_DECLINED"
            Detail = ("uacDeclined=true win32Error={0}" -f $NativeErrorCode)
        }
    }

    return [pscustomobject]@{
        Code   = "E_UPDATE_ELEVATION_START_FAILED"
        Detail = ("exceptionType='{0}' win32Error={1} message={2}" -f $ExceptionTypeName, $(if ($IsWin32Exception) { [string]$NativeErrorCode } else { "n/a" }), $ExceptionMessage)
    }
}

function Invoke-UpdateElevatedRelaunch {
    # Re-launches this exact script file with -WithAdmin through the shell elevation verb.
    # ProcessStartInfo + Set-PortableProcessArguments per repo conventions (Start-Process
    # mangles argument shapes); UseShellExecute is mandatory for Verb='runas'. The parent
    # process intentionally does not wait: once the UAC prompt accepts, the elevated child
    # owns the flow, so a successful hand-off reports exit 0 ("relay succeeded"), not
    # "update completed" - the elevated session re-runs every step from scratch. A declined
    # or failed launch fails closed with a stable diagnostic. Set-PortableProcessArguments
    # carries the relay arguments through Verb='runas' on .NET 6+ (ShellExecute reads
    # ArgumentList via BuildArguments) and through the .Arguments fallback on 5.1.
    [CmdletBinding()]
    param()

    $powerShellExecutable = Resolve-PowerShellExecutablePath
    $resolvedScriptPath = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "Update.ps1") -ErrorAction Stop).Path

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellExecutable
    $startInfo.UseShellExecute = $true
    $startInfo.Verb = "runas"
    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList (
        Get-UpdateSelfRelaunchArguments -ScriptPath $resolvedScriptPath
    )

    try {
        [void][System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        # Distinguish the operator-declining UAC from every other launch failure so triage
        # does not blame the user for policy/config/environment breakage.
        $isWin32Exception = $false
        $failureNativeErrorCode = 0
        $failureTypeName = $_.Exception.GetType().FullName
        $exceptionToInspect = $_.Exception
        while ($null -ne $exceptionToInspect) {
            if ($exceptionToInspect -is [System.ComponentModel.Win32Exception]) {
                $isWin32Exception = $true
                $failureNativeErrorCode = [int]$exceptionToInspect.NativeErrorCode
                break
            }

            $exceptionToInspect = $exceptionToInspect.InnerException
        }

        $relaunchFailure = Resolve-UpdateElevationStartFailure `
            -IsWin32Exception $isWin32Exception `
            -NativeErrorCode $failureNativeErrorCode `
            -ExceptionTypeName $failureTypeName `
            -ExceptionMessage $_.Exception.Message

        throw ("{0}: could not start an elevated update session ({1}). Run 'Update.ps1 -WithAdmin' from an already-elevated console to complete consent-gated upgrades." -f $relaunchFailure.Code, $relaunchFailure.Detail)
    }
}

function Get-ApplicableUpdateSteps {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Steps,

        [Parameter(Mandatory = $true)]
        [string]$CurrentPlatformName
    )

    $applicableSteps = New-Object System.Collections.Generic.List[object]
    foreach ($step in $Steps) {
        $supportedPlatforms = @($step.SupportedPlatforms)
        if ($supportedPlatforms.Count -eq 0) {
            throw (
                "E_UPDATE_STEP_METADATA_INVALID({0}): Step '{1}' must define SupportedPlatforms metadata." -f
                $step.Name,
                $step.Name
            )
        }

        if ($supportedPlatforms -contains "All" -or $supportedPlatforms -contains $CurrentPlatformName) {
            [void]$applicableSteps.Add($step)
            continue
        }

        Write-Warning (
            "W_UPDATE_STEP_SKIPPED_PLATFORM: Skipping step '{0}' ({1}) on platform '{2}'. SupportedPlatforms={3}." -f
            $step.Name,
            $step.RelativeScriptPath,
            $CurrentPlatformName,
            ($supportedPlatforms -join ', ')
        )
    }

    return $applicableSteps.ToArray() # array-unwrap-safe: callers wrap in @(...).
}

function Assert-ApplicableUpdateStepsFlat {
    param(
        # Zero applicable steps is a valid shape (for example every step is Windows-only
        # while running headless on POSIX); reject only nested containers below.
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$ApplicableSteps,

        [Parameter(Mandatory = $true)]
        [string]$CurrentPlatformName
    )

    $nestedStepContainers = @($ApplicableSteps | Where-Object { $_ -is [System.Array] })
    Write-Verbose (
        "Update step selection diagnostics: currentPlatform='{0}', applicableSteps={1}, nestedStepContainers={2}" -f
        $CurrentPlatformName,
        $ApplicableSteps.Count,
        $nestedStepContainers.Count
    )

    if ($nestedStepContainers.Count -gt 0) {
        throw (
            "E_UPDATE_STEP_SELECTION_INVALID: Applicable step selection contains nested array value(s) ({0}) on platform '{1}'. Ensure Get-ApplicableUpdateSteps returns a flat step list and callers use @(...)." -f
            $nestedStepContainers.Count,
            $CurrentPlatformName
        )
    }
}

function Get-LastExitCodeOrDefault {
    $lastExitCode = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $lastExitCode) {
        return [int]$lastExitCode
    }

    return 0
}

function Invoke-UpdateStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$StepName
    )

    $powerShellExecutable = Resolve-PowerShellExecutablePath
    & $powerShellExecutable -NoLogo -NoProfile -File $ScriptPath
    $stepSucceeded = $?
    $stepExitCode = Get-LastExitCodeOrDefault
    if (-not $stepSucceeded -or $stepExitCode -ne 0) {
        throw (
            "E_UPDATE_STEP_FAILED: Step '{0}' failed (exitCode={1}; scriptPath='{2}')." -f
            $StepName,
            $stepExitCode,
            $ScriptPath
        )
    }
}

# Allow tests to dot-source this orchestrator's helpers without executing any steps.
if ($MyInvocation.InvocationName -ne ".") {
    $scriptsDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
    $compatibilityHelpersPath = Join-Path -Path $scriptsDirectory -ChildPath "Utils/Common/CompatibilityHelpers.ps1"
    if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
        throw "E_UPDATE_COMPATIBILITY_HELPER_MISSING: compatibility helper file not found at '$compatibilityHelpersPath'."
    }

    . $compatibilityHelpersPath

    $elevationDecision = Resolve-UpdateElevationAction `
        -WithAdmin ([bool]$WithAdmin) `
        -IsWindowsPlatform (Test-IsWindowsPlatform) `
        -IsRunningElevated (Test-UpdateRunningElevated)
    switch ($elevationDecision.Action) {
        "RelaunchElevated" {
            Write-Host "INFO_UPDATE_ELEVATION_RELAY: re-launching this update session with administrator rights (-WithAdmin opt-in)." -ForegroundColor DarkYellow
            Invoke-UpdateElevatedRelaunch
            exit 0
        }

        "WarnUnsupportedPlatform" {
            Write-Warning ("W_UPDATE_ELEVATION_UNSUPPORTED_PLATFORM: {0}" -f $elevationDecision.Detail)
            break
        }

        default {
            Write-Verbose ("Update elevation diagnostics: action='{0}', reason='{1}'." -f $elevationDecision.Action, $elevationDecision.Reason)
            break
        }
    }

    $steps = @(
        @{ Name = "StopKomorebi"; RelativeScriptPath = "Komorebi/StopKomorebi.ps1"; SupportedPlatforms = @("Windows") },
        @{ Name = "ScoopUpdate"; RelativeScriptPath = "Scoop/ScoopUpdate.ps1"; SupportedPlatforms = @("Windows") },
        @{ Name = "WinGetUpdate"; RelativeScriptPath = "WinGet/WinGetUpdate.ps1"; SupportedPlatforms = @("Windows") }
    )

    $currentPlatformName = Get-CurrentPlatformName
    $applicableSteps = @(Get-ApplicableUpdateSteps -Steps $steps -CurrentPlatformName $currentPlatformName)
    Assert-ApplicableUpdateStepsFlat -ApplicableSteps $applicableSteps -CurrentPlatformName $currentPlatformName

    Write-Verbose ("Update platform diagnostics: currentPlatform='{0}', totalSteps={1}, applicableSteps={2}" -f $currentPlatformName, $steps.Count, $applicableSteps.Count)
    Write-Host "INFO_UPDATE_FORMATTER_BOUNDARY: FormatPowershellScripts is no longer run automatically by Update.ps1. Source code formatting is enforced by pre-commit hooks. Run 'pre-commit run --all-files' when manual formatting is needed." -ForegroundColor DarkYellow

    Push-Location -LiteralPath $scriptsDirectory
    try {
        $stepResults = New-Object System.Collections.Generic.List[object]
        foreach ($step in $applicableSteps) {
            $stepPath = Join-Path -Path $scriptsDirectory -ChildPath $step.RelativeScriptPath
            try {
                Invoke-UpdateStep -ScriptPath $stepPath -StepName $step.Name
                [void]$stepResults.Add([pscustomobject]@{
                        Name    = $step.Name
                        Success = $true
                        Error   = ""
                    })
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning ("{0}: {1}" -f $step.Name, $errorMessage)
                [void]$stepResults.Add([pscustomobject]@{
                        Name    = $step.Name
                        Success = $false
                        Error   = $errorMessage
                    })
            }
        }

        $failedSteps = @($stepResults | Where-Object { -not $_.Success })
        $failedCount = $failedSteps.Count
        $totalCount = $stepResults.Count
        $succeededCount = $totalCount - $failedCount

        Write-Host ""
        Write-Host "========== UPDATE SUMMARY ==========" -ForegroundColor Cyan
        Write-Host ("Planned steps: {0}, Applicable on {1}: {2}, Skipped by platform: {3}" -f $steps.Count, $currentPlatformName, $applicableSteps.Count, ($steps.Count - $applicableSteps.Count))
        Write-Host ("Total steps: {0}, Successful: {1}, Failed: {2}" -f $totalCount, $succeededCount, $failedCount)

        if ($failedCount -gt 0) {
            Write-Host "Failed steps:" -ForegroundColor Yellow
            foreach ($failedStep in $failedSteps) {
                Write-Host ("  - {0}: {1}" -f $failedStep.Name, $failedStep.Error) -ForegroundColor Yellow
            }

            throw ("E_UPDATE_PARTIAL_FAILURE: One or more update steps failed ({0}/{1} succeeded)." -f $succeededCount, $totalCount)
        }
    }
    finally {
        Pop-Location
    }
}
else {
    # The dot-source contract intentionally skips orchestration, but a silent no-op used to
    # be "run everything" for out-of-tree callers - make the semantics loud so nobody
    # dot-sources this file expecting steps to execute.
    Write-Warning "W_UPDATE_DOT_SOURCE_NO_OP: Update.ps1 was dot-sourced; orchestration is intentionally skipped (helper/test-harness contract). Execute it with 'pwsh -File Scripts/Update.ps1' to run update steps."
}
