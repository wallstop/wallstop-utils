Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Scoop host health check (issue #68/#70 follow-up). Detects the failure modes encountered during the
# 2026-08-22 scoop audit that `scoop update` itself cannot surface:
#   1. `scoop status` anomalies: Install failed / Manifest removed / missing versions.
#   2. Installed-version-vs-bucket-latest inversion (the `2025 > 2.71.0` semver trap) where the bucket
#      offers a newer release that scoop refuses to apply -> recommend uninstall+reinstall.
#   3. Junction integrity: every apps\<name>\current must be a reparse point (except apps\scoop);
#      a real directory means a self-updater replaced the junction, and a missing link means a broken
#      half-install.
#   4. Mozilla channel drift: a Thunderbird/Firefox profile whose compatibility.ini LastVersion major or
#      channel disagrees with the installed scoop app (downgrade-guard risk, issue #68 problem 3).
#   5. Orphaned Mozilla helper processes under the scoop roots whose parent PID is gone; they pin
#      executables in version directories and block cleanup.
#
# Runbook: docs/operator-runbooks/scoop-host-audit-recovery.md

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_SCOOP_HEALTH_COMPATIBILITY_HELPER_MISSING: compatibility helper file not found at '$compatibilityHelpersPath'."
}
. $compatibilityHelpersPath

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -LiteralPath $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_SCOOP_HEALTH_DIAGNOSTICS_HELPER_MISSING: diagnostics helper file not found at '$diagnosticsHelpersPath'."
}
. $diagnosticsHelpersPath

$scoopInstallRootHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/ScoopInstallRootHelpers.ps1"
if (-not (Test-Path -LiteralPath $scoopInstallRootHelpersPath -PathType Leaf)) {
    throw "E_SCOOP_HEALTH_ROOT_HELPER_MISSING: scoop install root helper file not found at '$scoopInstallRootHelpersPath'."
}
. $scoopInstallRootHelpersPath

function Get-ScoopHealthJsonPropertyValue {
    # Strict-mode-safe property read for JSON documents parsed on any PowerShell edition: missing
    # members return an empty string instead of throwing under Set-StrictMode -Version Latest.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Document,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PropertyName
    )

    if ($null -eq $Document) {
        return ""
    }

    $property = $Document.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ""
    }

    return [string]$property.Value
}

function Get-ScoopLeadingNumericSegments {
    # Parses the leading numeric dot-separated segments of a version string ('2025' -> @(2025),
    # '2.71.0' -> @(2, 71, 0), '140.14.0esr' -> @(140, 14)). Non-numeric prefixes stop the parse so
    # channel suffixes never fabricate numeric data. Parsing is ASCII-digit based with an invariant
    # bounded cast so corrupt manifests degrade to a shorter (or empty) segment list instead of
    # throwing a culture-sensitive overflow.
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$VersionText
    )

    $segments = New-Object System.Collections.Generic.List[int]
    foreach ($rawSegment in ($VersionText.Trim() -split '\.')) {
        $numericPrefixMatch = [regex]::Match($rawSegment, '^[0-9]+')
        if (-not $numericPrefixMatch.Success) {
            break
        }

        $parsedSegment = 0
        if (-not [int]::TryParse($numericPrefixMatch.Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSegment)) {
            break
        }

        [void]$segments.Add($parsedSegment)
    }

    return $segments.ToArray()
}

function Find-ScoopStatusAnomalies {
    # Classifies `scoop status` table rows into actionable anomaly records. Routine update rows are
    # intentionally ignored: ordinary update availability is scoop's own job to report, and warning on
    # it every run would violate the low-noise diagnostics contract. Only the states scoop cannot fix
    # by itself are surfaced.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$StatusLines = @()
    )

    $anomalies = New-Object System.Collections.Generic.List[object]
    foreach ($statusLine in @($StatusLines)) {
        # Captured command output may arrive as per-line strings (native commands) or as single
        # multi-line elements (PowerShell script shims); expand every element into physical lines
        # so table parsing is invariant to the producer.
        foreach ($physicalLine in ([string]$statusLine -split "`r?`n")) {
            $textLine = $physicalLine
            if ([string]::IsNullOrWhiteSpace($textLine)) {
                continue
            }

            $trimmedLine = $textLine.Trim()
            if ($trimmedLine -match '^(Name\s+Installed|-{3,})') {
                continue
            }

            $appName = ($trimmedLine -split '\s+')[0]
            if ([string]::IsNullOrWhiteSpace($appName)) {
                continue
            }

            # Wrapped Format-Table rows continue on their own line starting mid-column; such fragments
            # cannot be attributed to an app, so they are ignored instead of misreported as app '???'.
            if ($appName -match '\?') {
                continue
            }

            $reason = $null
            if ($textLine -match '(?i)install failed') {
                $reason = "InstallFailed"
            }
            elseif ($textLine -match '(?i)manifest removed') {
                $reason = "ManifestRemoved"
            }
            elseif ($textLine -match '\?\?\?') {
                $reason = "MissingVersions"
            }

            if ($null -ne $reason) {
                [void]$anomalies.Add([pscustomobject]@{
                        App    = $appName
                        Reason = $reason
                    })
            }
        }
    }

    return $anomalies.ToArray()
}

function Test-ScoopVersionInversionSuspect {
    # Detects the audit's semver-trap signature: a bare year-like installed version (single segment
    # >= 1900, for example the transitional '2025' manifest name) while the bucket offers a normal
    # multi-segment release with a smaller leading segment ('2.71.0'). Scoop's numeric comparison
    # treats the year-like version as newest forever, so only uninstall+reinstall recovers.
    # Multi-segment installed versions are out of scope: CalVer apps legitimately exceed classic
    # semver majors, and flagging them would produce daily noise.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstalledVersion,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$BucketLatestVersion
    )

    if ([string]::IsNullOrWhiteSpace($InstalledVersion) -or [string]::IsNullOrWhiteSpace($BucketLatestVersion)) {
        return $false
    }

    $installedSegments = @(Get-ScoopLeadingNumericSegments -VersionText $InstalledVersion)
    $latestSegments = @(Get-ScoopLeadingNumericSegments -VersionText $BucketLatestVersion)
    if ($installedSegments.Count -ne 1 -or $latestSegments.Count -lt 2) {
        return $false
    }

    if ($installedSegments[0] -lt 1900) {
        return $false
    }

    return ($latestSegments[0] -lt $installedSegments[0])
}

function Get-ScoopJunctionFindingCode {
    # Maps one apps\<name>\current observation to its stable finding code ('' means healthy).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$CurrentLinkExists,

        [Parameter(Mandatory = $true)]
        [bool]$CurrentLinkIsReparsePoint
    )

    if (-not $CurrentLinkExists) {
        return "E_SCOOP_HEALTH_CURRENT_LINK_MISSING"
    }

    if (-not $CurrentLinkIsReparsePoint) {
        return "E_SCOOP_HEALTH_JUNCTION_REPLACED"
    }

    return ""
}

function Test-ScoopPathUnderRoot {
    # Case-insensitive prefix check used only for Windows process paths (the health check is a
    # Windows-targeted step), with separator normalization so mixed-slash inputs still compare.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Root
    )

    $normalizedPath = ($Path -replace '/', '\').TrimEnd('\')
    $normalizedRoot = ($Root -replace '/', '\').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($normalizedRoot)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        return $false
    }

    return $normalizedPath.StartsWith($normalizedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-ScoopOrphanedHelperProcesses {
    # Filters Mozilla helper processes (crashhelper/updater/pingsender) running from inside the scoop
    # roots whose parent PID no longer exists. Orphaned helpers pin executables inside version
    # directories and block the purge/reinstall recovery in the audit runbook. Input records mirror
    # Win32_Process shape (ProcessId, ParentProcessId, Name, ExecutablePath) so tests inject fakes.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$ProcessRecords = @(),

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ScoopRoots = @()
    )

    $helperNamePattern = '^(?i)(crashhelper|updater|pingsender)\.exe$'
    $livePidSet = New-Object "System.Collections.Generic.HashSet[int]"
    foreach ($processRecord in @($ProcessRecords)) {
        $processIdProperty = $processRecord.PSObject.Properties["ProcessId"]
        if ($null -eq $processIdProperty -or $null -eq $processIdProperty.Value) {
            continue
        }

        # Invariant bounded parse: Win32 PIDs are UInt32 and hostile/corrupt records must degrade to
        # a skipped record instead of an overflow throw that would abort the whole scan.
        $parsedPid = 0
        if (-not [int]::TryParse([string]$processIdProperty.Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedPid)) {
            continue
        }

        [void]$livePidSet.Add($parsedPid)
    }

    $orphans = New-Object System.Collections.Generic.List[object]
    foreach ($processRecord in @($ProcessRecords)) {
        $processName = Get-ScoopHealthJsonPropertyValue -Document $processRecord -PropertyName "Name"
        if (-not ($processName -match $helperNamePattern)) {
            continue
        }

        $executablePath = Get-ScoopHealthJsonPropertyValue -Document $processRecord -PropertyName "ExecutablePath"
        $hasKnownLocation = $false
        foreach ($scoopRoot in @($ScoopRoots)) {
            if (Test-ScoopPathUnderRoot -Path $executablePath -Root $scoopRoot) {
                $hasKnownLocation = $true
                break
            }
        }

        if (-not $hasKnownLocation) {
            continue
        }

        $parentPidValue = 0
        $parentProperty = $processRecord.PSObject.Properties["ParentProcessId"]
        $parentParsed = $false
        if ($null -ne $parentProperty -and $null -ne $parentProperty.Value) {
            $parentParsed = [int]::TryParse([string]$parentProperty.Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parentPidValue)
        }

        # An unparseable parent is treated as unknown rather than dead so corrupt records never
        # fabricate orphan findings.
        if ($parentParsed -and ($parentPidValue -le 0 -or -not $livePidSet.Contains($parentPidValue))) {
            [void]$orphans.Add($processRecord)
        }
    }

    return $orphans.ToArray()
}

function Get-ScoopMozillaInstalledChannel {
    # Maps a scoop Mozilla package name to its update channel via the well-known suffixes.
    # Unknown suffixes map to 'release', matching how Mozilla treats unmarked builds.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName
    )

    foreach ($knownChannel in @("esr", "beta", "nightly", "aurora")) {
        if ($AppName.EndsWith("-$knownChannel", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $knownChannel
        }
    }

    return "release"
}

function Get-ScoopMozillaChannelDriftReason {
    # Compares one profile's compatibility.ini LastVersion value against the installed scoop Mozilla
    # app. The real LastVersion format is '<version>_<buildId>/<previousBuildId>' (for example
    # '140.14.0esr_20250715141807/20250715141807'), so the version+channel token is recovered by
    # stripping the build-ID parts first. Returns '' when aligned (or unparseable -- unparseable
    # values are logged verbose by the caller instead of warned, keeping the daily signal low-noise).
    # Drift reasons cover the two actionable cases from the audit: channel switch (ESR -> release
    # self-update) and profile-ahead-of-install at ANY parsed version segment (Mozilla's downgrade
    # guard triggers on patch-level regressions too, not just major jumps).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ProfileLastVersion,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstalledAppVersion,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstalledChannel
    )

    if ([string]::IsNullOrWhiteSpace($ProfileLastVersion)) {
        return ""
    }

    $profileToken = ((($ProfileLastVersion -split '/')[0]) -split '_')[0].Trim()
    if ([string]::IsNullOrWhiteSpace($profileToken)) {
        return ""
    }

    $profileChannel = "release"
    if ($profileToken -match '(?i)(esr|beta|aurora|nightly)$') {
        $profileChannel = $Matches[1].ToLowerInvariant()
    }

    $profileMajorSegments = @(Get-ScoopLeadingNumericSegments -VersionText $profileToken)
    $installedMajorSegments = @(Get-ScoopLeadingNumericSegments -VersionText $InstalledAppVersion)
    if ($profileMajorSegments.Count -eq 0 -or $installedMajorSegments.Count -eq 0) {
        return ""
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not [string]::Equals($profileChannel, $InstalledChannel, [System.StringComparison]::OrdinalIgnoreCase)) {
        [void]$reasons.Add(("profile channel '{0}' does not match installed channel '{1}'" -f $profileChannel, $InstalledChannel))
    }

    $comparedSegmentCount = [Math]::Min($profileMajorSegments.Count, $installedMajorSegments.Count)
    $isProfileNewer = $false
    for ($segmentIndex = 0; $segmentIndex -lt $comparedSegmentCount; $segmentIndex++) {
        if ($profileMajorSegments[$segmentIndex] -gt $installedMajorSegments[$segmentIndex]) {
            $isProfileNewer = $true
            break
        }

        if ($profileMajorSegments[$segmentIndex] -lt $installedMajorSegments[$segmentIndex]) {
            break
        }
    }

    # Equal through every compared segment but the profile carries MORE parsed segments (for example
    # profile '140.14.0.1' vs installed '140.14.0'): the profile was written by a newer build.
    if (-not $isProfileNewer -and $profileMajorSegments.Count -gt $installedMajorSegments.Count) {
        $isProfileNewer = $true
    }

    if ($isProfileNewer) {
        [void]$reasons.Add(("profile was last written by version '{0}', newer than installed '{1}' (downgrade guard will block launch)" -f $profileToken, $InstalledAppVersion))
    }

    return ($reasons -join '; ')
}

function Resolve-ScoopHealthInstallRoots {
    # Thin Scoop-health-facing wrapper over the shared install-root resolver, honoring per-user
    # ($env:SCOOP) and admin/global ($env:SCOOP_GLOBAL) installs.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $resolvedRoots = @(Get-ScoopInstallCandidateRoots)
    Write-Verbose (
        "Scoop health root diagnostics: resolvedRoots={0}" -f
        ($resolvedRoots -join ', ')
    )
    return $resolvedRoots
}

function Invoke-ScoopHealthCheck {
    # Runs every sub-check independently (one failing sub-check must not mask the others), emits each
    # finding as a stable-coded warning, and reports exit code 1 when anything needs operator action.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $findings = New-Object System.Collections.Generic.List[object]

    function Add-ScoopHealthFinding {
        param(
            # Deliberately not Mandatory: PowerShell rejects binding the initially-empty findings
            # list to a Mandatory collection parameter.
            [System.Collections.Generic.List[object]]$Findings,

            [Parameter(Mandatory = $true)]
            [ValidateSet("E", "W")]
            [string]$Severity,

            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Code,

            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Message
        )

        # Precompute the full text before emitting so helper failures can never mask the stable code
        # (context.md rule 11).
        $findingText = "{0}: {1}" -f $Code, $Message
        [void]$Findings.Add([pscustomobject]@{
                Severity = $Severity
                Code     = $Code
                Message  = $Message
            })
        Write-Warning $findingText
    }

    $scoopCommand = Get-Command -Name "scoop" -ErrorAction SilentlyContinue
    if ($null -eq $scoopCommand) {
        # Benign absence follows the ThunderbirdBackup precedent: the other scoop backup steps fail
        # loudly when scoop is missing, so doubling the signal here adds noise without information.
        Write-Warning "W_SCOOP_HEALTH_SCOOP_NOT_AVAILABLE: scoop executable not found on PATH; skipping scoop health check."
        return [pscustomobject]@{
            Findings = @()
            ExitCode = 0
        }
    }

    $installRoots = @(Resolve-ScoopHealthInstallRoots)

    # ---- Sub-check A: scoop status anomalies ---------------------------------------------
    $statusExitCode = 0
    $statusFailureDetail = ""
    $statusLines = @()
    try {
        $statusLines = @(& scoop status 2>&1)
        $statusExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
        $statusExitCode = if ($null -ne $statusExitVariable) { [int]$statusExitVariable } else { 0 }
    }
    catch {
        $statusExitCode = -1
        $statusFailureDetail = [string]$_.Exception.Message
    }

    if ($statusExitCode -ne 0) {
        $statusPreview = Get-OutputPreview -OutputLines $statusLines -CollapseWhitespace
        $statusMessage = ("scoop status exited with code {0}. outputPreview={1}" -f $statusExitCode, $statusPreview)
        if (-not [string]::IsNullOrEmpty($statusFailureDetail)) {
            $statusMessage = ("scoop status could not be invoked ({0}). outputPreview={1}" -f $statusFailureDetail, $statusPreview)
        }

        Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code "E_SCOOP_HEALTH_STATUS_FAILED" -Message $statusMessage
    }
    else {
        $statusAnomalies = @(Find-ScoopStatusAnomalies -StatusLines $statusLines)
        foreach ($anomaly in $statusAnomalies) {
            Add-ScoopHealthFinding -Findings $findings -Severity "W" -Code "W_SCOOP_HEALTH_STATUS_ANOMALY" -Message (
                "app='{0}' reason='{1}' requires manual recovery (see docs/operator-runbooks/scoop-host-audit-recovery.md)" -f
                $anomaly.App,
                $anomaly.Reason
            )
        }
    }

    # ---- Sub-check B: scoop export + bucket-manifest inversion ----------------------------
    $exportApps = @()
    $exportAvailable = $false
    $exportExitCode = 0
    $exportRunDetail = ""
    # Pre-initialized so the 5.1 stderr-redirect crash path in the catch below can never reference
    # an undefined variable under Set-StrictMode.
    $exportLines = @()
    try {
        $exportLines = @(& scoop export --no-colour 2>&1)
        $exportExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
        $exportExitCode = if ($null -ne $exportExitVariable) { [int]$exportExitVariable } else { 0 }
    }
    catch {
        $exportExitCode = -1
        $exportRunDetail = [string]$_.Exception.Message
    }

    if ($exportExitCode -ne 0) {
        $exportPreview = Get-OutputPreview -OutputLines $exportLines -CollapseWhitespace
        $exportMessage = ("scoop export exited with code {0}. outputPreview={1}" -f $exportExitCode, $exportPreview)
        if (-not [string]::IsNullOrEmpty($exportRunDetail)) {
            $exportMessage = ("scoop export could not be invoked ({0})." -f $exportRunDetail)
        }

        Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code "E_SCOOP_HEALTH_EXPORT_FAILED" -Message $exportMessage
    }
    else {
        $exportRawJson = ($exportLines -join "`n")
        if ([string]::IsNullOrWhiteSpace($exportRawJson)) {
            Write-Verbose "Scoop health inversion diagnostics: scoop export returned no payload; treating as zero installed apps."
            $exportAvailable = $true
        }
        else {
            try {
                $exportDocument = ConvertFrom-Json -InputObject $exportRawJson -ErrorAction Stop
                $appsProperty = $exportDocument.PSObject.Properties["apps"]
                $parsedApps = New-Object System.Collections.Generic.List[object]
                if ($null -ne $appsProperty) {
                    foreach ($appEntry in @($appsProperty.Value)) {
                        $parsedApps.Add([pscustomobject]@{
                                Name    = Get-ScoopHealthJsonPropertyValue -Document $appEntry -PropertyName "Name"
                                Version = Get-ScoopHealthJsonPropertyValue -Document $appEntry -PropertyName "Version"
                                Source  = Get-ScoopHealthJsonPropertyValue -Document $appEntry -PropertyName "Source"
                            })
                    }
                }

                $exportApps = @($parsedApps.ToArray())
                $exportAvailable = $true
            }
            catch {
                Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code "E_SCOOP_HEALTH_EXPORT_FAILED" -Message (
                    "scoop export payload could not be parsed as JSON. Detail: {0}" -f [string]$_.Exception.Message
                )
            }
        }
    }

    if ($exportAvailable) {
        try {
            $bucketManifestVersions = @{}
            foreach ($installRoot in $installRoots) {
                $bucketsRoot = Join-Path -Path $installRoot -ChildPath "buckets"
                if (-not (Test-Path -LiteralPath $bucketsRoot -PathType Container)) {
                    continue
                }

                $bucketDirectories = @(Get-ChildItem -LiteralPath $bucketsRoot -Directory -ErrorAction SilentlyContinue)
                foreach ($bucketDirectory in $bucketDirectories) {
                    $manifestDirectory = Join-Path -Path $bucketDirectory.FullName -ChildPath "bucket"
                    if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) {
                        continue
                    }

                    $manifestFiles = @(Get-ChildItem -LiteralPath $manifestDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue)
                    foreach ($manifestFile in $manifestFiles) {
                        try {
                            $manifestText = [System.IO.File]::ReadAllText($manifestFile.FullName, [System.Text.Encoding]::UTF8)
                            $manifestDocument = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
                            $manifestVersion = Get-ScoopHealthJsonPropertyValue -Document $manifestDocument -PropertyName "version"
                            if ([string]::IsNullOrWhiteSpace($manifestVersion)) {
                                Write-Verbose (
                                    "Scoop health manifest diagnostics: '{0}' has no version property." -f
                                    $manifestFile.FullName
                                )
                                continue
                            }

                            $lookupKey = "{0}|{1}" -f $bucketDirectory.Name.ToLowerInvariant(), $manifestFile.BaseName.ToLowerInvariant()
                            if (-not $bucketManifestVersions.ContainsKey($lookupKey)) {
                                $bucketManifestVersions[$lookupKey] = $manifestVersion
                            }

                            $fallbackKey = "*|{0}" -f $manifestFile.BaseName.ToLowerInvariant()
                            if (-not $bucketManifestVersions.ContainsKey($fallbackKey)) {
                                $bucketManifestVersions[$fallbackKey] = $manifestVersion
                            }
                        }
                        catch {
                            Write-Verbose (
                                "Scoop health manifest diagnostics: skipping unparseable manifest '{0}'. Detail: {1}" -f
                                $manifestFile.FullName,
                                [string]$_.Exception.Message
                            )
                        }
                    }
                }
            }

            foreach ($installedApp in $exportApps) {
                if ([string]::IsNullOrWhiteSpace($installedApp.Name)) {
                    continue
                }

                $appNameKey = $installedApp.Name.ToLowerInvariant()
                $bucketKey = "{0}|{1}" -f $installedApp.Source.ToLowerInvariant(), $appNameKey
                $bucketLatestVersion = $null
                if ($bucketManifestVersions.ContainsKey($bucketKey)) {
                    $bucketLatestVersion = $bucketManifestVersions[$bucketKey]
                }
                elseif ($bucketManifestVersions.ContainsKey("*|$appNameKey")) {
                    $bucketLatestVersion = $bucketManifestVersions["*|$appNameKey"]
                    Write-Verbose (
                        "Scoop health inversion diagnostics: app '{0}' bucket '{1}' has no local manifest match; using fallback manifest version '{2}'." -f
                        $installedApp.Name,
                        $installedApp.Source,
                        $bucketLatestVersion
                    )
                }

                if ([string]::IsNullOrWhiteSpace($bucketLatestVersion)) {
                    continue
                }

                if (Test-ScoopVersionInversionSuspect -InstalledVersion $installedApp.Version -BucketLatestVersion $bucketLatestVersion) {
                    Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code "E_SCOOP_HEALTH_VERSION_INVERSION_SUSPECTED" -Message (
                        "app='{0}' installed='{1}' bucket-latest='{2}' (bucket='{3}') is deadlocked by version comparison; recover with 'scoop uninstall {0} && scoop install {0}'" -f
                        $installedApp.Name,
                        $installedApp.Version,
                        $bucketLatestVersion,
                        $installedApp.Source
                    )
                }
            }
        }
        catch {
            Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code "E_SCOOP_HEALTH_BUCKET_SCAN_FAILED" -Message (
                "bucket manifest scan failed. Detail: {0}" -f [string]$_.Exception.Message
            )
        }
    }

    # ---- Sub-check C: junction integrity (Windows-only: NTFS reparse semantics) ------------
    if (Test-IsWindowsPlatform) {
        try {
            foreach ($installRoot in $installRoots) {
                $appsRoot = Join-Path -Path $installRoot -ChildPath "apps"
                if (-not (Test-Path -LiteralPath $appsRoot -PathType Container)) {
                    continue
                }

                $appDirectories = @(Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne "scoop" })
                foreach ($appDirectory in $appDirectories) {
                    $currentLinkPath = Join-Path -Path $appDirectory.FullName -ChildPath "current"
                    try {
                        $currentLinkExists = (Test-Path -LiteralPath $currentLinkPath)
                        $currentLinkIsReparsePoint = $false
                        if ($currentLinkExists) {
                            $currentItem = Get-Item -LiteralPath $currentLinkPath -Force -ErrorAction Stop
                            $currentLinkIsReparsePoint = (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                        }
                    }
                    catch {
                        # Per-app resilience: one unreadable app (AV lock, ACL) must not abort the
                        # remaining apps or roots.
                        Add-ScoopHealthFinding -Findings $findings -Severity "W" -Code "W_SCOOP_HEALTH_JUNCTION_PROBE_FAILED" -Message (
                            "app='{0}' path='{1}' could not be inspected. Detail: {2}" -f
                            $appDirectory.Name,
                            $currentLinkPath,
                            [string]$_.Exception.Message
                        )
                        continue
                    }

                    $junctionFindingCode = Get-ScoopJunctionFindingCode -CurrentLinkExists $currentLinkExists -CurrentLinkIsReparsePoint $currentLinkIsReparsePoint
                    if (-not [string]::IsNullOrEmpty($junctionFindingCode)) {
                        Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code $junctionFindingCode -Message (
                            "app='{0}' root='{1}' current='{2}'" -f
                            $appDirectory.Name,
                            $installRoot,
                            $currentLinkPath
                        )
                    }
                }
            }
        }
        catch {
            Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code "E_SCOOP_HEALTH_JUNCTION_SCAN_FAILED" -Message (
                "junction integrity scan failed. Detail: {0}" -f [string]$_.Exception.Message
            )
        }
    }
    else {
        Write-Verbose "Scoop health junction diagnostics: skipped on non-Windows host (reparse points are NTFS-specific)."
    }

    # ---- Sub-check D: Mozilla profile channel drift ----------------------------------------
    try {
        $thunderbirdProfilesRoot = $null
        if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $thunderbirdProfilesRoot = Join-Path -Path $env:APPDATA -ChildPath "Thunderbird/Profiles"
        }

        if ([string]::IsNullOrWhiteSpace($thunderbirdProfilesRoot) -or -not (Test-Path -LiteralPath $thunderbirdProfilesRoot -PathType Container)) {
            Write-Verbose "Scoop health Mozilla diagnostics: Thunderbird profiles root not found; skipping channel drift scan."
        }
        elseif (-not $exportAvailable) {
            Write-Verbose "Scoop health Mozilla diagnostics: scoop export unavailable; skipping channel drift scan."
        }
        else {
            $mozillaApps = @($exportApps | Where-Object { $_.Name -match '^(thunderbird|firefox)' })
            if ($mozillaApps.Count -eq 0) {
                Write-Verbose "Scoop health Mozilla diagnostics: no scoop-installed Mozilla apps; skipping channel drift scan."
            }
            else {
                # This scan reads %APPDATA%\Thunderbird profiles, so a Thunderbird-family package is
                # required for a meaningful comparison; Firefox-only installs are skipped (their
                # profiles live under a different APPDATA tree and are out of scope per issue #70).
                $referenceApp = $mozillaApps |
                    Where-Object { $_.Name -match '^thunderbird' } |
                    Select-Object -First 1
                if ($null -eq $referenceApp) {
                    Write-Verbose "Scoop health Mozilla diagnostics: no scoop-installed Thunderbird-family app; skipping channel drift scan."
                }
                else {
                    $installedChannel = Get-ScoopMozillaInstalledChannel -AppName $referenceApp.Name

                    $profileDirectories = @(Get-ChildItem -LiteralPath $thunderbirdProfilesRoot -Directory -ErrorAction SilentlyContinue)
                    foreach ($profileDirectory in $profileDirectories) {
                        $compatibilityIniPath = Join-Path -Path $profileDirectory.FullName -ChildPath "compatibility.ini"
                        if (-not (Test-Path -LiteralPath $compatibilityIniPath -PathType Leaf)) {
                            continue
                        }

                        $compatibilityText = [System.IO.File]::ReadAllText($compatibilityIniPath, [System.Text.Encoding]::UTF8)
                        $lastVersionMatch = [regex]::Match($compatibilityText, '(?m)^LastVersion=(.+)$')
                        if (-not $lastVersionMatch.Success) {
                            Write-Verbose (
                                "Scoop health Mozilla diagnostics: profile '{0}' has no LastVersion entry." -f
                                $profileDirectory.FullName
                            )
                            continue
                        }

                        $driftReason = Get-ScoopMozillaChannelDriftReason -ProfileLastVersion $lastVersionMatch.Groups[1].Value.Trim() -InstalledAppVersion $referenceApp.Version -InstalledChannel $installedChannel
                        if (-not [string]::IsNullOrEmpty($driftReason)) {
                            Add-ScoopHealthFinding -Findings $findings -Severity "W" -Code "W_SCOOP_HEALTH_MOZILLA_CHANNEL_DRIFT" -Message (
                                "profile='{0}' lastVersion='{1}' installedApp='{2}' installedVersion='{3}': {4}" -f
                                $profileDirectory.Name,
                                $lastVersionMatch.Groups[1].Value.Trim(),
                                $referenceApp.Name,
                                $referenceApp.Version,
                                $driftReason
                            )
                        }
                    }
                }
            }
        }
    }
    catch {
        Add-ScoopHealthFinding -Findings $findings -Severity "W" -Code "W_SCOOP_HEALTH_MOZILLA_SCAN_FAILED" -Message (
            "Mozilla channel drift scan failed. Detail: {0}" -f [string]$_.Exception.Message
        )
    }

    # ---- Sub-check E: orphaned Mozilla helpers (Windows-only: Win32_Process) ----------------
    if (Test-IsWindowsPlatform) {
        try {
            # Resolve the cmdlet indirectly (repo portable idiom, see DiagnosticsHelpers.ps1): raw
            # Get-CimInstance is flagged by the cross-version compatibility gate for non-Windows
            # profiles even though this call site is platform-gated.
            $getCimInstanceCommand = Get-Command -Name "Get-CimInstance" -ErrorAction SilentlyContinue
            if ($null -eq $getCimInstanceCommand) {
                Add-ScoopHealthFinding -Findings $findings -Severity "W" -Code "W_SCOOP_HEALTH_PROCESS_SCAN_UNAVAILABLE" -Message (
                    "Get-CimInstance is unavailable; orphaned Mozilla helper detection degraded on this host."
                )
            }
            else {
                $processRecords = @(& $getCimInstanceCommand -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath -ErrorAction Stop)
                $orphanedHelpers = @(Find-ScoopOrphanedHelperProcesses -ProcessRecords $processRecords -ScoopRoots $installRoots)
                foreach ($orphanedHelper in $orphanedHelpers) {
                    $orphanParentPid = Get-ScoopHealthJsonPropertyValue -Document $orphanedHelper -PropertyName "ParentProcessId"
                    Add-ScoopHealthFinding -Findings $findings -Severity "W" -Code "W_SCOOP_HEALTH_ORPHANED_MOZILLA_HELPER" -Message (
                        "process='{0}' pid='{1}' parentPid='{2}' path='{3}' pins scoop files and blocks cleanup" -f
                        (Get-ScoopHealthJsonPropertyValue -Document $orphanedHelper -PropertyName "Name"),
                        (Get-ScoopHealthJsonPropertyValue -Document $orphanedHelper -PropertyName "ProcessId"),
                        $orphanParentPid,
                        (Get-ScoopHealthJsonPropertyValue -Document $orphanedHelper -PropertyName "ExecutablePath")
                    )
                }
            }
        }
        catch {
            Add-ScoopHealthFinding -Findings $findings -Severity "E" -Code "E_SCOOP_HEALTH_PROCESS_SCAN_FAILED" -Message (
                "Mozilla helper process scan failed. Detail: {0}" -f [string]$_.Exception.Message
            )
        }
    }
    else {
        Write-Verbose "Scoop health process diagnostics: skipped on non-Windows host (Win32_Process is Windows-specific)."
    }

    if ($findings.Count -gt 0) {
        Write-Host ("Scoop health check complete: {0} finding(s) require attention." -f $findings.Count) -ForegroundColor Yellow
    }
    else {
        Write-Host "Scoop health check complete: no issues detected." -ForegroundColor Green
    }

    $healthExitCode = 0
    if ($findings.Count -gt 0) {
        $healthExitCode = 1
    }

    return [pscustomobject]@{
        Findings = $findings.ToArray() # array-unwrap-safe: callers access .Count via @() wrapping
        ExitCode = $healthExitCode
    }
}

# Allow tests to dot-source the classifiers without executing the live checks (which require scoop).
if ($MyInvocation.InvocationName -ne ".") {
    $healthCheckResult = Invoke-ScoopHealthCheck
    exit $healthCheckResult.ExitCode
}
