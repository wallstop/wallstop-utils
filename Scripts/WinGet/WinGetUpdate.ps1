Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# WinGet aggregate exit codes (microsoft/winget-cli doc/windows/package-manager/winget/returnCodes.md):
#   0x8A15002B (-1978335189) APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
#   0x8A15002C (-1978335188) APPINSTALLER_CLI_ERROR_UPDATE_ALL_HAS_FAILURE
$script:WinGetUpdateNotApplicableExitCode = -1978335189
$script:WinGetUpgradeAllHasFailureExitCode = -1978335188

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -LiteralPath $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Diagnostics helper file not found at '$diagnosticsHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $diagnosticsHelpersPath

function Get-WinGetUpgradePackageOutcomes {
    # Walks `winget upgrade --all` progress output sequentially and accounts for EVERY
    # "(N/M) Found <Name> [<Id>]" block: each must reach a terminal marker - either
    # "Installer failed with exit code: <code>" (attributable) or "Successfully installed".
    # Blocks left without a terminal marker surface as Unresolved so an unparsed failure
    # phrasing can never ride along behind consent-blocked deferrals as a false green.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$OutputLines = @()
    )

    $outcomes = New-Object System.Collections.Generic.List[object]
    $openPackageIds = New-Object System.Collections.Generic.Queue[string]
    foreach ($outputLine in @($OutputLines)) {
        # Captured external output can arrive as one multi-line element (script-shim shape)
        # or per-line elements (native-command shape); expand physical lines either way,
        # including lone-CR progress-redraw frames.
        foreach ($physicalLine in @(([string]$outputLine) -split "\r\n|\r|\n")) {
            if ($physicalLine -match '^\s*\(\d+/\d+\)\s+Found\s+.*\[(?<id>[^\]]+)\]') {
                [void]$openPackageIds.Enqueue($Matches['id'])
                continue
            }

            $isFailureLine = $physicalLine -match '^\s*Installer failed with exit code:\s*(?<code>[^\s:,]+)'
            $isSuccessLine = $physicalLine -match '^\s*Successfully installed'
            if (-not $isFailureLine -and -not $isSuccessLine) {
                continue
            }

            if ($openPackageIds.Count -eq 0) {
                continue
            }

            $packageId = $openPackageIds.Dequeue()
            [void]$outcomes.Add([pscustomobject]@{
                    PackageId         = $packageId
                    Status            = $(if ($isFailureLine) { "Failed" } else { "Upgraded" })
                    InstallerExitCode = $(if ($isFailureLine) { $Matches['code'] } else { "" })
                })
        }
    }

    # Any Found block that never reached a terminal marker is an unaccounted package.
    while ($openPackageIds.Count -gt 0) {
        [void]$outcomes.Add([pscustomobject]@{
                PackageId         = $openPackageIds.Dequeue()
                Status            = "Unresolved"
                InstallerExitCode = ""
            })
    }

    return $outcomes.ToArray() # array-unwrap-safe: callers wrap in @(...).
}

function Test-WinGetInstallerExitCodeIsConsentBlocked {
    # Installer exit codes that mean the package needs interactive elevation or consent,
    # which a silent unattended run can never satisfy: 1602 (ERROR_INSTALL_USEREXIT) and
    # 1223 (ERROR_CANCELLED) are the UAC-declined/suppressed shapes, and 0x80073d28 is the
    # winget-reported "administrator privileges are required" failure.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstallerExitCode
    )

    $normalizedCode = $InstallerExitCode.Trim()
    if ($normalizedCode -match '^0[xX][0-9a-fA-F]+$') {
        return ($normalizedCode.ToLowerInvariant() -eq '0x80073d28')
    }

    return (@('1602', '1223') -contains $normalizedCode)
}

function Resolve-WinGetUpdateOutcome {
    # Pure classification of a completed `winget upgrade --all --silent --disable-interactivity`
    # invocation so every branch is unit-testable without synthesizing winget's int32 exit
    # codes (which POSIX child processes truncate to 8 bits).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$WingetExitCode,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$OutputLines = @()
    )

    if ($WingetExitCode -eq 0) {
        return [pscustomobject]@{ ExitZero = $true; ExitCode = 0; WarningDiagnostic = ""; ErrorDiagnostic = ""; NoApplicable = $false }
    }

    # WinGet reports "no applicable upgrade found" as a non-zero HRESULT even
    # though the requested no-op update completed successfully.
    if ($WingetExitCode -eq $script:WinGetUpdateNotApplicableExitCode) {
        return [pscustomobject]@{
            ExitZero          = $true
            ExitCode          = 0
            WarningDiagnostic = ""
            ErrorDiagnostic   = ""
            NoApplicable      = $true
        }
    }

    if ($WingetExitCode -ne $script:WinGetUpgradeAllHasFailureExitCode) {
        $failurePreview = Get-OutputPreview -OutputLines $OutputLines -MaxLines 10 -MaxCharacters 640 -HeadTailWhenTruncated
        return [pscustomobject]@{
            ExitZero          = $false
            ExitCode          = $WingetExitCode
            WarningDiagnostic = ""
            ErrorDiagnostic   = (
                "E_WINGET_UPDATE_FAILED: 'winget upgrade --all' exited with code {0}. outputPreview={1}" -f
                $WingetExitCode,
                $failurePreview
            )
            NoApplicable      = $false
        }
    }

    # --all completed with at least one package failure while other packages may have
    # upgraded fine; classify the accounted package outcomes before deciding the outcome.
    $packageOutcomes = @(Get-WinGetUpgradePackageOutcomes -OutputLines $OutputLines)
    $consentBlockedEntries = New-Object System.Collections.Generic.List[string]
    $genuineFailureEntries = New-Object System.Collections.Generic.List[string]
    $unresolvedEntries = New-Object System.Collections.Generic.List[string]
    foreach ($packageOutcome in $packageOutcomes) {
        $entry = "{0} (installer exit {1})" -f $packageOutcome.PackageId, $packageOutcome.InstallerExitCode
        switch ($packageOutcome.Status) {
            "Failed" {
                if (Test-WinGetInstallerExitCodeIsConsentBlocked -InstallerExitCode $packageOutcome.InstallerExitCode) {
                    [void]$consentBlockedEntries.Add($entry)
                }
                else {
                    [void]$genuineFailureEntries.Add($entry)
                }
            }
            "Unresolved" {
                [void]$unresolvedEntries.Add($packageOutcome.PackageId)
            }
        }
    }

    $warningDiagnostic = ""
    if ($consentBlockedEntries.Count -gt 0) {
        $warningDiagnostic = (
            "W_WINGET_UPGRADE_DEFERRED_INTERACTIVE: {0} package(s) require interactive elevation or consent and were not upgraded by the silent run: {1}. Run 'winget upgrade' in an interactive session to complete them." -f
            $consentBlockedEntries.Count,
            ($consentBlockedEntries -join '; ')
        )
    }

    if ($genuineFailureEntries.Count -gt 0) {
        return [pscustomobject]@{
            ExitZero          = $false
            ExitCode          = $WingetExitCode
            WarningDiagnostic = $warningDiagnostic
            ErrorDiagnostic   = (
                "E_WINGET_UPDATE_PACKAGE_INSTALL_FAILED: {0} package(s) failed to upgrade: {1}." -f
                $genuineFailureEntries.Count,
                ($genuineFailureEntries -join '; ')
            )
            NoApplicable      = $false
        }
    }

    if ($packageOutcomes.Count -eq 0 -or $unresolvedEntries.Count -gt 0) {
        # Aggregate failure with unaccounted packages (Found blocks that never reached a
        # terminal marker, or no parseable per-package output at all): fail closed instead of
        # letting an unparsed failure ride along behind consent-blocked deferrals.
        $unaccountedDetail = $(if ($unresolvedEntries.Count -gt 0) { ($unresolvedEntries -join '; ') } else { "none-attributed" })
        $failurePreview = Get-OutputPreview -OutputLines $OutputLines -MaxLines 10 -MaxCharacters 640 -HeadTailWhenTruncated
        return [pscustomobject]@{
            ExitZero          = $false
            ExitCode          = $WingetExitCode
            WarningDiagnostic = $warningDiagnostic
            ErrorDiagnostic   = (
                "E_WINGET_UPDATE_UNATTRIBUTED_FAILURE: 'winget upgrade --all' reported failures (exitCode={0}) but not every package outcome could be accounted from its output. unaccounted={1}. outputPreview={2}" -f
                $WingetExitCode,
                $unaccountedDetail,
                $failurePreview
            )
            NoApplicable      = $false
        }
    }

    return [pscustomobject]@{ ExitZero = $true; ExitCode = 0; WarningDiagnostic = $warningDiagnostic; ErrorDiagnostic = ""; NoApplicable = $false }
}

function Invoke-WinGetUpgradeStep {
    # Application covers the real winget (an app-execution alias); ExternalScript keeps the
    # PATH-shim test harness (winget.ps1 on Windows) resolvable. Multiple candidates can match
    # a single PATH directory (for example the bash and .ps1 test shims); invoke the first.
    $wingetCommandCandidates = @(Get-Command -Name "winget" -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)
    $wingetCommand = if ($wingetCommandCandidates.Count -gt 0) { $wingetCommandCandidates[0] } else { $null }
    if ($null -eq $wingetCommand) {
        [Console]::Error.WriteLine("E_WINGET_UPDATE_NOT_AVAILABLE: winget CLI was not found on PATH. Install the Windows Package Manager (App Installer) and retry.")
        exit 1
    }

    Write-Verbose ("WinGet update diagnostics: winget='{0}'." -f $wingetCommand.Source)

    # --disable-interactivity keeps unattended runs bounded: consent/elevation prompts fail
    # fast instead of stalling the backup step waiting on an operator that never arrives.
    # Redirected native stderr becomes a terminating NativeCommandError under EAP=Stop on
    # Windows PowerShell 5.1, so scope the capture to EAP=Continue.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $upgradeOutput = @(& $wingetCommand.Source upgrade --all --silent --disable-interactivity 2>&1 | ForEach-Object { [string]$_ })
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($upgradeLine in $upgradeOutput) {
        Write-Host $upgradeLine
    }

    $outcome = Resolve-WinGetUpdateOutcome -WingetExitCode $LASTEXITCODE -OutputLines $upgradeOutput

    if ($outcome.NoApplicable) {
        Write-Host "WinGet: no applicable upgrades found; treating the no-op as successful."
    }

    if (-not [string]::IsNullOrWhiteSpace($outcome.WarningDiagnostic)) {
        Write-Warning $outcome.WarningDiagnostic
    }

    if (-not [string]::IsNullOrWhiteSpace($outcome.ErrorDiagnostic)) {
        [Console]::Error.WriteLine($outcome.ErrorDiagnostic)
    }

    exit $outcome.ExitCode
}

# Allow tests to dot-source the classifiers without executing the live upgrade.
if ($MyInvocation.InvocationName -ne ".") {
    Invoke-WinGetUpgradeStep
}
