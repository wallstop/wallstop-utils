Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/CompatibilityHelpers.ps1")

$scoopInstallRootHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/ScoopInstallRootHelpers.ps1"
if (-not (Test-Path -LiteralPath $scoopInstallRootHelpersPath -PathType Leaf)) {
    throw "E_SCOOP_RESTORE_ROOT_HELPER_MISSING: scoop install root helper file not found at '$scoopInstallRootHelpersPath'."
}
. $scoopInstallRootHelpersPath

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$configDirectory = Join-Path -Path $baseDirectory -ChildPath "Config"
$scoopFilePath = Join-Path -Path $configDirectory -ChildPath "scoopfile.json"

if (-not (Test-Path -LiteralPath $scoopFilePath -PathType Leaf)) {
    Write-Error "E_SCOOP_RESTORE_SOURCE_MISSING: Scoop backup manifest not found at '$scoopFilePath'."
    exit 1
}

Push-Location -LiteralPath $configDirectory
try {
    $outputLines = @(& scoop import $scoopFilePath 2>&1)
    $scoopExitCodeVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    $scoopExitCode = if ($null -ne $scoopExitCodeVariable) { [int]$scoopExitCodeVariable } else { 0 }

    if ($scoopExitCode -ne 0) {
        $errorText = if ($outputLines.Count -gt 0) { $outputLines -join [Environment]::NewLine } else { "(no output)" }
        Write-Error ("E_SCOOP_RESTORE_IMPORT_FAILED: scoop import failed with code {0}. Output: {1}" -f $scoopExitCode, $errorText)
        exit 1
    }

    Write-Host "Scoop restore successful: $scoopFilePath" -ForegroundColor Green
}
finally {
    Pop-Location
}

# Mozilla apps bundled by Scoop keep their internal auto-updater enabled; when it runs
# from inside the apps\<name>\current junction it replaces the junction with a real
# directory and corrupts Scoop's bookkeeping (issue #68). Deploy an update-blocking
# distribution policy for every installed Mozilla app after import.
function Get-ScoopRestoreInstallRoots {
    # Thin Scoop-restore-facing wrapper over the shared install-root resolver, honoring per-user
    # ($env:SCOOP) and admin/global ($env:SCOOP_GLOBAL) installs. Global coverage closes the gap
    # noted during PR #69 review: admin-installed Mozilla apps previously never received a policy.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(Get-ScoopInstallCandidateRoots)
}

function Install-MozillaUpdateBlockingPolicyForApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScoopRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName
    )

    # Reset per app: an earlier app's merged document must not leak into
    # this app's comparison baseline or written payload.
    $policyPayload = '{"policies":{"DisableAppUpdate":true,"DisableTelemetry":true}}'
    $distributionDirectory = Join-Path -Path $ScoopRoot -ChildPath (
        "persist/{0}/distribution" -f $AppName
    )
    $policyPath = Join-Path -Path $distributionDirectory -ChildPath "policies.json"
    try {
        if (-not (Test-Path -LiteralPath $distributionDirectory -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($distributionDirectory)
        }

        $existingPayload = ''
        if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
            $existingPayload = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8).Trim()
        }

        if ($existingPayload -eq $policyPayload) {
            Write-Verbose ("Mozilla update-blocking policy already current: {0}" -f $policyPath)
            return
        }

        # Preserve any hand-set enterprise policies; only the update/telemetry
        # switches are owned by this deployment step. Property access goes
        # through PSObject.Properties so Set-StrictMode never throws on a
        # missing member and custom sections are merged, never clobbered.
        if (-not [string]::IsNullOrEmpty($existingPayload)) {
            try {
                $existingPolicyDocument = ConvertFrom-Json -InputObject $existingPayload -ErrorAction Stop

                $policiesProperty = $existingPolicyDocument.PSObject.Properties["policies"]
                if ($null -eq $policiesProperty) {
                    $policiesSection = [pscustomobject]@{}
                    $existingPolicyDocument | Add-Member -MemberType NoteProperty -Name "policies" -Value $policiesSection
                }
                else {
                    $policiesSection = $policiesProperty.Value
                }

                if ($policiesSection -isnot [System.Management.Automation.PSCustomObject]) {
                    throw "The existing 'policies' section is not a JSON object, so it cannot be merged safely."
                }

                foreach ($policySwitchName in @("DisableAppUpdate", "DisableTelemetry")) {
                    $switchProperty = $policiesSection.PSObject.Properties[$policySwitchName]
                    if ($null -ne $switchProperty) {
                        $switchProperty.Value = $true
                    }
                    else {
                        $policiesSection | Add-Member -MemberType NoteProperty -Name $policySwitchName -Value $true
                    }
                }

                $policyPayload = ConvertTo-Json -InputObject $existingPolicyDocument -Depth 10 -Compress
            }
            catch {
                Write-Warning (
                    "W_SCOOP_RESTORE_MOZILLA_POLICY_UNPARSEABLE: Existing '{0}' is not valid JSON and will be replaced. Detail: {1}" -f
                    $policyPath,
                    [string]$_.Exception.Message
                )
            }
        }

        [System.IO.File]::WriteAllText($policyPath, $policyPayload + "`n", [System.Text.UTF8Encoding]::new($false))
        Write-Host ("Deployed Mozilla update-blocking policy: {0}" -f $policyPath) -ForegroundColor Green
    }
    catch {
        Write-Warning (
            "W_SCOOP_RESTORE_MOZILLA_POLICY_FAILED: Failed to deploy '{0}'. Detail: {1}" -f
            $policyPath,
            [string]$_.Exception.Message
        )
    }
}

function Install-MozillaUpdateBlockingPolicies {
    $scoopRoots = @(Get-ScoopRestoreInstallRoots)

    $appsRootFound = $false
    foreach ($scoopRoot in $scoopRoots) {
        $appsRoot = Join-Path -Path $scoopRoot -ChildPath "apps"
        if (-not (Test-Path -LiteralPath $appsRoot -PathType Container)) {
            continue
        }

        $appsRootFound = $true
        $mozillaAppDirectories = @(Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(thunderbird|firefox)' })
        foreach ($appDirectory in $mozillaAppDirectories) {
            Install-MozillaUpdateBlockingPolicyForApp -ScoopRoot $scoopRoot -AppName $appDirectory.Name
        }
    }

    if (-not $appsRootFound) {
        $checkedRootsText = if (@($scoopRoots).Count -gt 0) { @($scoopRoots) -join ', ' } else { '(none resolved)' }
        Write-Warning ("W_SCOOP_RESTORE_MOZILLA_POLICY_SKIPPED: Scoop apps root not found in any install root (checked: {0})." -f $checkedRootsText)
    }
}

Install-MozillaUpdateBlockingPolicies
