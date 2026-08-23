Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    # Dot-source the health-check script. The run guard ($MyInvocation.InvocationName -ne ".") prevents
    # the live checks (which require the scoop CLI) from executing on dot-source, exposing only the
    # classifiers for testing. Dot-sourcing also brings CompatibilityHelpers (Test-IsWindowsPlatform,
    # Resolve-PowerShellExecutablePath) and DiagnosticsHelpers (Get-OutputPreview) into scope.
    . "$PSScriptRoot/../../Scripts/Scoop/Invoke-ScoopHealthCheck.ps1"

    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:healthCheckScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Scoop/Invoke-ScoopHealthCheck.ps1"
    $script:pwshExecutable = Resolve-PowerShellExecutablePath
    $script:scoopHealthHarnessRoots = @()

    function New-Utf8NoBomTextFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Text
        )

        $parentDirectory = [System.IO.Path]::GetDirectoryName($Path)
        if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($parentDirectory)
        }

        [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
    }

    function ConvertTo-SingleQuotedLiteral {
        # Escapes arbitrary text for safe embedding inside a single-quoted PowerShell literal and a
        # single-quoted bash string: only the single quote needs doubling in both grammars.
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Text
        )

        return $Text -replace "'", "''"
    }

    function New-FakeScoopCommandBin {
        # Writes fixture-driven fake `scoop` shims into an isolated bin directory: a bash shim for
        # Unix hosts and a scoop.ps1 shim for Windows hosts (PowerShell resolves PATH .ps1 files the
        # same way real scoop's shim is resolved). Payloads and exit codes are embedded DIRECTLY in
        # the shim source rather than read from fixture files at runtime: the extra file-read layer
        # proved flaky under redirected child-process stdout on Windows CI, and embedding makes the
        # fake fully self-contained and deterministic on every host.
        param(
            [Parameter(Mandatory = $true)]
            [string]$BinDirectory,

            [Parameter(Mandatory = $false)]
            [AllowEmptyString()]
            [string]$StatusOutput = "",

            [Parameter(Mandatory = $false)]
            [int]$StatusExitCode = 0,

            [Parameter(Mandatory = $false)]
            [AllowEmptyString()]
            [string]$ExportOutput = "",

            [Parameter(Mandatory = $false)]
            [int]$ExportExitCode = 0
        )

        [void][System.IO.Directory]::CreateDirectory($BinDirectory)

        $escapedStatus = ConvertTo-SingleQuotedLiteral -Text ($StatusOutput -replace "`r`n", "`n")
        $escapedExport = ConvertTo-SingleQuotedLiteral -Text ($ExportOutput -replace "`r`n", "`n")

        $bashShimText = @"
#!/usr/bin/env bash
set -u
command="`${1:-}"
case "`$command" in
  status)
    printf '%s' '$escapedStatus'
    exit $StatusExitCode
    ;;
  export)
    printf '%s' '$escapedExport'
    exit $ExportExitCode
    ;;
esac
echo "unexpected fake scoop invocation: `$command" >&2
exit 60
"@
        $bashShimPath = Join-Path -Path $BinDirectory -ChildPath "scoop"
        New-Utf8NoBomTextFile -Path $bashShimPath -Text ($bashShimText -replace "`r`n", "`n")

        $ps1ShimText = @"
param()
`$command = `$args[0]
switch (`$command) {
  'status' {
    # Pipeline output, never [Console]::Out: console writes bypass PowerShell's output
    # pipeline, so a caller capturing @(`$script 2>&1) would see nothing.
    Write-Output '$escapedStatus'
    exit $StatusExitCode
  }
  'export' {
    Write-Output '$escapedExport'
    exit $ExportExitCode
  }
  default {
    Write-Error "unexpected fake scoop invocation: `$command"
    exit 60
  }
}
"@
        $ps1ShimPath = Join-Path -Path $BinDirectory -ChildPath "scoop.ps1"
        New-Utf8NoBomTextFile -Path $ps1ShimPath -Text ($ps1ShimText -replace "`r`n", "`n")

        if (-not (Test-IsWindowsPlatform)) {
            $chmodOutcome = @(& chmod "+x" $bashShimPath 2>&1)
            $chmodExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
            $chmodExitCode = if ($null -ne $chmodExitVariable) { [int]$chmodExitVariable } else { 0 }
            if ($chmodExitCode -ne 0) {
                throw "Failed to mark the fake scoop bash shim executable: $($chmodOutcome -join ' ')"
            }
        }
    }

    function New-ScoopHealthHarness {
        # Creates a self-contained fixture environment: fake scoop bin directory, a scoop install
        # root with buckets, and an APPDATA root for Thunderbird profiles. Shim payloads are supplied
        # per test through New-FakeScoopCommandBin.
        param()

        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("scoop-health-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        $harness = [pscustomobject]@{
            Root      = $harnessRoot
            FakeBin   = (Join-Path -Path $harnessRoot -ChildPath "fake-bin")
            ScoopRoot = (Join-Path -Path $harnessRoot -ChildPath "scoop")
            AppData   = (Join-Path -Path $harnessRoot -ChildPath "appdata")
        }

        foreach ($directoryToCreate in @($harness.ScoopRoot, $harness.AppData)) {
            [void][System.IO.Directory]::CreateDirectory($directoryToCreate)
        }

        return $harness
    }

    function Invoke-ScoopHealthCheckInChild {
        # Runs the health-check script in an isolated child pwsh with the harness injected through the
        # environment (PATH fake-bin, SCOOP/SCOOP_GLOBAL roots, APPDATA), returning merged output and
        # the child exit code. Environment mutations are restored by the caller's finally block.
        # Pass -WithoutFakeBin to keep the fake scoop off PATH (deterministic "scoop unavailable").
        param(
            [Parameter(Mandatory = $true)]
            [object]$Harness,

            [Parameter(Mandatory = $false)]
            [switch]$WithoutFakeBin
        )

        if (-not $WithoutFakeBin) {
            $env:PATH = "{0}{1}{2}" -f $Harness.FakeBin, [System.IO.Path]::PathSeparator, $env:PATH
        }

        $env:SCOOP = $Harness.ScoopRoot
        $env:SCOOP_GLOBAL = $Harness.ScoopRoot
        $env:APPDATA = $Harness.AppData

        $childOutput = @(& $script:pwshExecutable -NoLogo -NoProfile -File $script:healthCheckScriptPath 2>&1)
        $childExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
        $childExitCode = if ($null -ne $childExitVariable) { [int]$childExitVariable } else { -1 }

        return [pscustomobject]@{
            Output   = $childOutput
            ExitCode = $childExitCode
            Text     = (($childOutput | ForEach-Object { [string]$_ }) -join "`n")
        }
    }

    function Register-ScoopHealthHarnessForCleanup {
        param(
            [Parameter(Mandatory = $true)]
            [string]$HarnessRoot
        )

        if ($null -eq $script:scoopHealthHarnessRoots) {
            $script:scoopHealthHarnessRoots = @()
        }

        $script:scoopHealthHarnessRoots = @($script:scoopHealthHarnessRoots) + @($HarnessRoot)
    }
}

AfterAll {
    if ($null -ne $script:scoopHealthHarnessRoots) {
        foreach ($harnessRootToDelete in $script:scoopHealthHarnessRoots) {
            Remove-Item -LiteralPath $harnessRootToDelete -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Find-ScoopStatusAnomalies" {
    It "classifies scoop status anomaly rows: <description>" -ForEach @(
        @{
            Description = "missing versions marker"
            Lines       = @("megatools                        ???               innounp")
            Expected    = "megatools|MissingVersions"
        },
        @{
            Description = "manifest removed marker"
            Lines       = @("thunderbird-esr                  Manifest removed")
            Expected    = "thunderbird-esr|ManifestRemoved"
        },
        @{
            Description = "install failed marker"
            Lines       = @("git                              ???               Install failed")
            Expected    = "git|InstallFailed"
        },
        @{
            Description = "wrapped table-row continuations are not misattributed as app '???'"
            Lines       = @(
                "someverylongapplicationname      ???               dependency",
                "???                              more-wrapped-columns"
            )
            Expected    = "someverylongapplicationname|MissingVersions"
        },
        @{
            Description = "routine update rows are ignored (low-noise contract)"
            Lines       = @("7zip        24.09                25.00")
            Expected    = ""
        },
        @{
            Description = "headers, separators, and preamble lines are ignored"
            Lines       = @("", "LastUpdate is in the future, this shouldn't happen", "Name        Installed Version    Latest Version", "----        -----------------    --------------")
            Expected    = ""
        },
        @{
            Description = "multiple anomalies preserve order"
            Lines       = @(
                "megatools                        ???               innounp",
                "innounp     2025                 2025",
                "thunderbird                      Manifest removed",
                "git                              ???               Install failed"
            )
            Expected    = "megatools|MissingVersions,thunderbird|ManifestRemoved,git|InstallFailed"
        }
    ) {
        param($Description, $Lines, $Expected)

        $anomalies = @(Find-ScoopStatusAnomalies -StatusLines $Lines)
        $actualSummary = (@($anomalies | ForEach-Object { "{0}|{1}" -f $_.App, $_.Reason }) -join ",")
        $actualSummary | Should -Be $Expected
    }

    It "returns no anomalies for empty input" {
        $anomalies = @(Find-ScoopStatusAnomalies -StatusLines @())
        $anomalies.Count | Should -Be 0
    }

    It "expands a single multi-line capture element (script-shim output shape)" {
        # A PowerShell script shim captured via @(& shim 2>&1) yields ONE string containing every
        # physical line; parsing must be invariant to that producer shape.
        $singleElementPayload = (@(
            "Name        Installed Version    Latest Version",
            "----        -----------------",
            "megatools                        ???               innounp",
            "7zip        24.09                25.00"
        ) -join "`n")

        $anomalies = @(Find-ScoopStatusAnomalies -StatusLines @($singleElementPayload))
        $actualSummary = (@($anomalies | ForEach-Object { "{0}|{1}" -f $_.App, $_.Reason }) -join ",")
        $actualSummary | Should -Be "megatools|MissingVersions"
    }
}

Describe "Test-ScoopVersionInversionSuspect" {
    It "detects the audit's semver trap: installed '<InstalledVersion>' vs bucket-latest '<BucketLatestVersion>' -> <Expected>" -ForEach @(
        # The exact innounp deadlock from issue #68: transitional year-like manifest name vs real release.
        @{ InstalledVersion = "2025"; BucketLatestVersion = "2.71.0"; Expected = $true },
        @{ InstalledVersion = "2025esr"; BucketLatestVersion = "2.71.0"; Expected = $true },
        @{ InstalledVersion = "1998"; BucketLatestVersion = "20.1.0"; Expected = $true },
        # Not inversions: equal versions, semver-ahead installs, CalVer multi-segment versions,
        # sub-year single segments, garbage, and empty values.
        @{ InstalledVersion = "2025"; BucketLatestVersion = "2025"; Expected = $false },
        @{ InstalledVersion = "2025"; BucketLatestVersion = "3000.1"; Expected = $false },
        @{ InstalledVersion = "24.09"; BucketLatestVersion = "25.00"; Expected = $false },
        @{ InstalledVersion = "140.14"; BucketLatestVersion = "139.9"; Expected = $false },
        @{ InstalledVersion = "46"; BucketLatestVersion = "1.2.3"; Expected = $false },
        @{ InstalledVersion = "abc"; BucketLatestVersion = "1.2.3"; Expected = $false },
        # Segments beyond Int32 degrade to a shorter parse instead of throwing.
        @{ InstalledVersion = "99999999999999"; BucketLatestVersion = "2.0"; Expected = $false },
        @{ InstalledVersion = ""; BucketLatestVersion = "2.71.0"; Expected = $false },
        @{ InstalledVersion = "2025"; BucketLatestVersion = ""; Expected = $false }
    ) {
        param($InstalledVersion, $BucketLatestVersion, $Expected)

        Test-ScoopVersionInversionSuspect -InstalledVersion $InstalledVersion -BucketLatestVersion $BucketLatestVersion | Should -Be $Expected
    }
}

Describe "Get-ScoopJunctionFindingCode" {
    It "maps junction state (<CurrentLinkExists>, <CurrentLinkIsReparsePoint>) to the stable code" -ForEach @(
        @{ CurrentLinkExists = $true; CurrentLinkIsReparsePoint = $true; Expected = "" },
        @{ CurrentLinkExists = $false; CurrentLinkIsReparsePoint = $false; Expected = "E_SCOOP_HEALTH_CURRENT_LINK_MISSING" },
        @{ CurrentLinkExists = $true; CurrentLinkIsReparsePoint = $false; Expected = "E_SCOOP_HEALTH_JUNCTION_REPLACED" }
    ) {
        param($CurrentLinkExists, $CurrentLinkIsReparsePoint, $Expected)

        Get-ScoopJunctionFindingCode -CurrentLinkExists $CurrentLinkExists -CurrentLinkIsReparsePoint $CurrentLinkIsReparsePoint | Should -Be $Expected
    }
}

Describe "Get-ScoopMozillaInstalledChannel" {
    It "maps scoop package '<AppName>' to channel '<Expected>'" -ForEach @(
        @{ AppName = "thunderbird"; Expected = "release" },
        @{ AppName = "thunderbird-esr"; Expected = "esr" },
        @{ AppName = "firefox"; Expected = "release" },
        @{ AppName = "firefox-beta"; Expected = "beta" },
        @{ AppName = "firefox-nightly"; Expected = "nightly" },
        @{ AppName = "FireFox-ESR"; Expected = "esr" }
    ) {
        param($AppName, $Expected)

        Get-ScoopMozillaInstalledChannel -AppName $AppName | Should -Be $Expected
    }
}

Describe "Get-ScoopMozillaChannelDriftReason" {
    # Real compatibility.ini shape: 'LastVersion=<version>_<buildId>/<previousBuildId>'.
    It "compares profile '<ProfileLastVersion>' against installed '<InstalledAppVersion>'/<InstalledChannel>" -ForEach @(
        @{ ProfileLastVersion = "140.14.0esr_20250715141807/20250715141807"; InstalledAppVersion = "140.14.0"; InstalledChannel = "esr"; ExpectChannelDrift = $false; ExpectDowngradeRisk = $false },
        @{ ProfileLastVersion = "154.0_20250801000000/20250801000000"; InstalledAppVersion = "154.0"; InstalledChannel = "release"; ExpectChannelDrift = $false; ExpectDowngradeRisk = $false },
        # Profile older than installed with matching channel: benign, never warned.
        @{ ProfileLastVersion = "139.14.0esr_20250601000000/20250601000000"; InstalledAppVersion = "140.14.0"; InstalledChannel = "esr"; ExpectChannelDrift = $false; ExpectDowngradeRisk = $false },
        # Patch-level regression also trips Mozilla's downgrade guard (not just major jumps).
        @{ ProfileLastVersion = "140.15_20250801000000/20250801000000"; InstalledAppVersion = "140.14.0"; InstalledChannel = "esr"; ExpectChannelDrift = $false; ExpectDowngradeRisk = $true },
        # Channel switch (the audit's ESR -> release self-update).
        @{ ProfileLastVersion = "153.0.3_20250901000000/20250901000000"; InstalledAppVersion = "140.14.0"; InstalledChannel = "esr"; ExpectChannelDrift = $true; ExpectDowngradeRisk = $true },
        @{ ProfileLastVersion = "140.14.0esr_20250715141807/20250715141807"; InstalledAppVersion = "141.0"; InstalledChannel = "release"; ExpectChannelDrift = $true; ExpectDowngradeRisk = $false },
        # Unparseable or empty LastVersion values stay silent (low-noise).
        @{ ProfileLastVersion = "not-a-version/x"; InstalledAppVersion = "1.0"; InstalledChannel = "release"; ExpectChannelDrift = $false; ExpectDowngradeRisk = $false },
        @{ ProfileLastVersion = "_20250801/20250801"; InstalledAppVersion = "1.0"; InstalledChannel = "release"; ExpectChannelDrift = $false; ExpectDowngradeRisk = $false },
        @{ ProfileLastVersion = ""; InstalledAppVersion = "1.0"; InstalledChannel = "release"; ExpectChannelDrift = $false; ExpectDowngradeRisk = $false }
    ) {
        param($ProfileLastVersion, $InstalledAppVersion, $InstalledChannel, $ExpectChannelDrift, $ExpectDowngradeRisk)

        $driftReason = Get-ScoopMozillaChannelDriftReason -ProfileLastVersion $ProfileLastVersion -InstalledAppVersion $InstalledAppVersion -InstalledChannel $InstalledChannel
        if (-not $ExpectChannelDrift -and -not $ExpectDowngradeRisk) {
            $driftReason | Should -BeNullOrEmpty
        }

        if ($ExpectChannelDrift) {
            $driftReason | Should -Match "does not match installed channel"
        }

        if ($ExpectDowngradeRisk) {
            $driftReason | Should -Match "downgrade guard"
        }
    }
}

Describe "Find-ScoopOrphanedHelperProcesses" {
    BeforeAll {
        $script:scoopRootForProcesses = "C:\Users\rider\scoop"
        $script:helperProcessTemplate = @{
            ProcessId       = 100
            ParentProcessId = 10
            Name            = "crashhelper.exe"
            ExecutablePath  = "C:\Users\rider\scoop\apps\thunderbird\current\crashhelper.exe"
        }
    }

    It "flags orphaned Mozilla helpers under the scoop roots and skips everything else" {
        $processRecords = @(
            # Live parent application process backing the next record's parent PID.
            [pscustomobject]@{ ProcessId = 100; ParentProcessId = 1; Name = "thunderbird.exe"; ExecutablePath = "C:\Users\rider\scoop\apps\thunderbird\current\thunderbird.exe" },
            # Orphaned helper: parent PID 999 is gone -> flagged.
            [pscustomobject]@{ ProcessId = 101; ParentProcessId = 999; Name = "crashhelper.exe"; ExecutablePath = "C:\Users\rider\scoop\apps\thunderbird\current\crashhelper.exe" },
            # Live parent -> not flagged.
            [pscustomobject]@{ ProcessId = 102; ParentProcessId = 100; Name = "updater.exe"; ExecutablePath = "C:\Users\rider\scoop\apps\firefox\current\updater.exe" },
            # Non-Mozilla helper -> not flagged even with a dead parent.
            [pscustomobject]@{ ProcessId = 103; ParentProcessId = 999; Name = "notepad.exe"; ExecutablePath = "C:\Users\rider\scoop\apps\tools\current\notepad.exe" },
            # Mozilla helper outside any scoop root -> not flagged.
            [pscustomobject]@{ ProcessId = 104; ParentProcessId = 999; Name = "pingsender.exe"; ExecutablePath = "C:\Program Files\Mozilla Firefox\pingsender.exe" },
            # Zero parent PID -> flagged (no parent exists).
            [pscustomobject]@{ ProcessId = 105; ParentProcessId = 0; Name = "CRASHHELPER.EXE"; ExecutablePath = "c:\users\RIDER\SCOOP\apps\thunderbird-esr\current\crashhelper.exe" }
        )

        $orphans = @(Find-ScoopOrphanedHelperProcesses -ProcessRecords $processRecords -ScoopRoots @($script:scoopRootForProcesses))
        $orphanIds = @($orphans | ForEach-Object { [int]$_.ProcessId })
        $orphanIds | Should -Be @(101, 105)
    }

    It "matches scoop roots case-insensitively with mixed separators" {
        $processRecord = [pscustomobject]@{
            ProcessId       = 201
            ParentProcessId = 0
            Name            = "updater.exe"
            ExecutablePath  = "c:/users/RIDER/Scoop/apps/thunderbird/current/updater.exe"
        }

        $orphans = @(Find-ScoopOrphanedHelperProcesses -ProcessRecords @($processRecord) -ScoopRoots @("C:\Users\rider\scoop"))
        $orphans.Count | Should -Be 1
    }

    It "returns nothing for empty input" {
        $orphans = @(Find-ScoopOrphanedHelperProcesses -ProcessRecords @() -ScoopRoots @($script:scoopRootForProcesses))
        $orphans.Count | Should -Be 0
    }
}

Describe "Resolve-ScoopHealthInstallRoots" {
    It "resolves the user root and honors the global root on Windows while deduplicating identical roots" {
        $harness = New-ScoopHealthHarness
        Register-ScoopHealthHarnessForCleanup -HarnessRoot $harness.Root

        $originalScoop = $env:SCOOP
        $originalScoopGlobal = $env:SCOOP_GLOBAL
        try {
            $env:SCOOP = $harness.ScoopRoot
            $env:SCOOP_GLOBAL = $harness.ScoopRoot
            $deduplicatedRoots = @(Resolve-ScoopHealthInstallRoots)

            if (Test-IsWindowsPlatform) {
                # Global root resolves to the same container, so the duplicate is dropped.
                $deduplicatedRoots.Count | Should -Be 1
            }
            else {
                # The global root is a Windows-only concept.
                $deduplicatedRoots.Count | Should -Be 1
            }

            $deduplicatedRoots[0] | Should -Be ((Resolve-Path -LiteralPath $harness.ScoopRoot -ErrorAction Stop).Path)

            if (Test-IsWindowsPlatform) {
                $globalOnlyRoot = Join-Path -Path $harness.Root -ChildPath "global-scoop"
                [void][System.IO.Directory]::CreateDirectory($globalOnlyRoot)
                $env:SCOOP_GLOBAL = $globalOnlyRoot
                $distinctRoots = @(Resolve-ScoopHealthInstallRoots)
                $distinctRoots.Count | Should -Be 2
                $distinctRoots[1] | Should -Be ((Resolve-Path -LiteralPath $globalOnlyRoot -ErrorAction Stop).Path)
            }
        }
        finally {
            $env:SCOOP = $originalScoop
            $env:SCOOP_GLOBAL = $originalScoopGlobal
        }
    }
}

Describe "Invoke-ScoopHealthCheck end-to-end (child process)" {
    It "reports every seeded failure mode and exits 1" {
        $harness = New-ScoopHealthHarness
        Register-ScoopHealthHarnessForCleanup -HarnessRoot $harness.Root

        # Bucket manifest offers the real 2.71.0 release while the export reports the transitional
        # year-like '2025' install (the innounp deadlock).
        New-Utf8NoBomTextFile -Path (Join-Path -Path $harness.ScoopRoot -ChildPath "buckets/extras/bucket/innounp.json") -Text '{"version": "2.71.0"}'
        $exportPayload = @(
            "{",
            '  "buckets": [],',
            '  "apps": [',
            "    {",
            '      "Source": "extras",',
            '      "Name": "innounp",',
            '      "Version": "2025",',
            '      "Info": ""',
            "    },",
            "    {",
            '      "Source": "main",',
            '      "Name": "thunderbird-esr",',
            '      "Version": "140.14.0",',
            '      "Info": ""',
            "    },",
            "    {",
            '      "Source": "main",',
            '      "Name": "7zip",',
            '      "Version": "24.09",',
            '      "Info": ""',
            "    }",
            "  ]",
            "}"
        ) -join "`n"

        $statusPayload = @(
            "Name        Installed Version    Latest Version    Missing Dependencies",
            "----        -----------------    --------------    --------------------",
            "megatools                        ???               innounp"
        ) -join "`n"

        # Thunderbird profile written by a newer release-channel build than the installed ESR package
        # (real compatibility.ini shape: '<version>_<buildId>/<previousBuildId>').
        New-Utf8NoBomTextFile -Path (Join-Path -Path $harness.AppData -ChildPath "Thunderbird/Profiles/q9is9tba.default-esr/compatibility.ini") -Text "LastVersion=153.0.3_20250901000000/20250901000000`n"

        New-FakeScoopCommandBin -BinDirectory $harness.FakeBin -StatusOutput $statusPayload -ExportOutput $exportPayload

        $originalPath = $env:PATH
        $originalScoop = $env:SCOOP
        $originalScoopGlobal = $env:SCOOP_GLOBAL
        $originalAppData = $env:APPDATA
        try {
            $childResult = Invoke-ScoopHealthCheckInChild -Harness $harness

            $childResult.ExitCode | Should -Be 1
            $childResult.Text | Should -Match "W_SCOOP_HEALTH_STATUS_ANOMALY"
            $childResult.Text | Should -Match "megatools"
            $childResult.Text | Should -Match "E_SCOOP_HEALTH_VERSION_INVERSION_SUSPECTED"
            $childResult.Text | Should -Match "scoop uninstall innounp"
            $childResult.Text | Should -Match "W_SCOOP_HEALTH_MOZILLA_CHANNEL_DRIFT"
            $childResult.Text | Should -Match "downgrade guard"
            $childResult.Text | Should -Match "finding\(s\) require attention"
        }
        finally {
            $env:PATH = $originalPath
            $env:SCOOP = $originalScoop
            $env:SCOOP_GLOBAL = $originalScoopGlobal
            $env:APPDATA = $originalAppData
        }
    }

    It "exits 0 with no findings when the simulated host is healthy" {
        $harness = New-ScoopHealthHarness
        Register-ScoopHealthHarnessForCleanup -HarnessRoot $harness.Root

        $exportPayload = @(
            "{",
            '  "buckets": [],',
            '  "apps": [',
            "    {",
            '      "Source": "main",',
            '      "Name": "7zip",',
            '      "Version": "24.09",',
            '      "Info": ""',
            "    }",
            "  ]",
            "}"
        ) -join "`n"
        New-Utf8NoBomTextFile -Path (Join-Path -Path $harness.ScoopRoot -ChildPath "buckets/main/bucket/7zip.json") -Text '{"version": "25.00"}'

        New-FakeScoopCommandBin -BinDirectory $harness.FakeBin -ExportOutput $exportPayload

        $originalPath = $env:PATH
        $originalScoop = $env:SCOOP
        $originalScoopGlobal = $env:SCOOP_GLOBAL
        $originalAppData = $env:APPDATA
        try {
            $childResult = Invoke-ScoopHealthCheckInChild -Harness $harness

            $childResult.ExitCode | Should -Be 0
            $childResult.Text | Should -Not -Match "E_SCOOP_HEALTH_"
            $childResult.Text | Should -Not -Match "W_SCOOP_HEALTH_"
            $childResult.Text | Should -Match "no issues detected"
        }
        finally {
            $env:PATH = $originalPath
            $env:SCOOP = $originalScoop
            $env:SCOOP_GLOBAL = $originalScoopGlobal
            $env:APPDATA = $originalAppData
        }
    }

    It "skips benignly when scoop is unavailable" {
        $harness = New-ScoopHealthHarness
        Register-ScoopHealthHarnessForCleanup -HarnessRoot $harness.Root

        $originalPath = $env:PATH
        $originalScoop = $env:SCOOP
        $originalScoopGlobal = $env:SCOOP_GLOBAL
        $originalAppData = $env:APPDATA
        try {
            # A PATH whose only entry cannot contain scoop makes the absence deterministic on every host.
            $emptyPathDirectory = Join-Path -Path $harness.Root -ChildPath "empty-path"
            [void][System.IO.Directory]::CreateDirectory($emptyPathDirectory)
            $env:PATH = $emptyPathDirectory

            $childResult = Invoke-ScoopHealthCheckInChild -Harness $harness -WithoutFakeBin

            $childResult.ExitCode | Should -Be 0
            $childResult.Text | Should -Match "W_SCOOP_HEALTH_SCOOP_NOT_AVAILABLE"
            $childResult.Text | Should -Match "skipping scoop health check"
        }
        finally {
            $env:PATH = $originalPath
            $env:SCOOP = $originalScoop
            $env:SCOOP_GLOBAL = $originalScoopGlobal
            $env:APPDATA = $originalAppData
        }
    }

    It "skips Mozilla drift when only Firefox-family apps are installed" {
        # Thunderbird profiles are only comparable against a Thunderbird-family package; this guards
        # the regression where profiles were paired against an unrelated firefox install.
        $harness = New-ScoopHealthHarness
        Register-ScoopHealthHarnessForCleanup -HarnessRoot $harness.Root

        $exportPayload = @(
            "{",
            '  "buckets": [],',
            '  "apps": [',
            "    {",
            '      "Source": "main",',
            '      "Name": "firefox",',
            '      "Version": "154.0",',
            '      "Info": ""',
            "    }",
            "  ]",
            "}"
        ) -join "`n"
        New-Utf8NoBomTextFile -Path (Join-Path -Path $harness.AppData -ChildPath "Thunderbird/Profiles/stale-esr/compatibility.ini") -Text "LastVersion=153.0.3_20250901000000/20250901000000`n"

        New-FakeScoopCommandBin -BinDirectory $harness.FakeBin -ExportOutput $exportPayload

        $originalPath = $env:PATH
        $originalScoop = $env:SCOOP
        $originalScoopGlobal = $env:SCOOP_GLOBAL
        $originalAppData = $env:APPDATA
        try {
            $childResult = Invoke-ScoopHealthCheckInChild -Harness $harness

            $childResult.ExitCode | Should -Be 0
            $childResult.Text | Should -Not -Match "W_SCOOP_HEALTH_MOZILLA_CHANNEL_DRIFT"
        }
        finally {
            $env:PATH = $originalPath
            $env:SCOOP = $originalScoop
            $env:SCOOP_GLOBAL = $originalScoopGlobal
            $env:APPDATA = $originalAppData
        }
    }

    It "detects replaced and missing junctions from real NTFS layout (Windows)" {
        if (-not (Test-IsWindowsPlatform)) {
            Set-ItResult -Skipped -Because "junction integrity requires NTFS reparse points"
            return
        }

        $harness = New-ScoopHealthHarness
        Register-ScoopHealthHarnessForCleanup -HarnessRoot $harness.Root

        # Healthy junction: apps\goodapp\current -> apps\goodapp\1.0
        [void][System.IO.Directory]::CreateDirectory((Join-Path -Path $harness.ScoopRoot -ChildPath "apps/goodapp/1.0"))
        New-Item -ItemType Junction -Path (Join-Path -Path $harness.ScoopRoot -ChildPath "apps/goodapp/current") -Value (Join-Path -Path $harness.ScoopRoot -ChildPath "apps/goodapp/1.0") | Out-Null
        # Replaced junction: a real directory where the reparse point belongs (self-updater corruption).
        [void][System.IO.Directory]::CreateDirectory((Join-Path -Path $harness.ScoopRoot -ChildPath "apps/badapp/current"))
        # Broken half-install: version directory left behind with no current link at all.
        [void][System.IO.Directory]::CreateDirectory((Join-Path -Path $harness.ScoopRoot -ChildPath "apps/halfapp/2025"))

        New-FakeScoopCommandBin -BinDirectory $harness.FakeBin -ExportOutput '{"buckets":[],"apps":[]}'

        $originalPath = $env:PATH
        $originalScoop = $env:SCOOP
        $originalScoopGlobal = $env:SCOOP_GLOBAL
        $originalAppData = $env:APPDATA
        try {
            $childResult = Invoke-ScoopHealthCheckInChild -Harness $harness

            $childResult.ExitCode | Should -Be 1
            $childResult.Text | Should -Match "E_SCOOP_HEALTH_JUNCTION_REPLACED"
            $childResult.Text | Should -Match "app='badapp'"
            $childResult.Text | Should -Match "E_SCOOP_HEALTH_CURRENT_LINK_MISSING"
            $childResult.Text | Should -Match "app='halfapp'"
            $childResult.Text | Should -Not -Match "app='goodapp'"
        }
        finally {
            $env:PATH = $originalPath
            $env:SCOOP = $originalScoop
            $env:SCOOP_GLOBAL = $originalScoopGlobal
            $env:APPDATA = $originalAppData
        }
    }
}

Describe "Backup orchestrator registration" {
    It "registers the ScoopHealthCheck step as Windows-only before ScoopUpdate" {
        $backupScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Backup.ps1") -Raw) -replace "`r", ""

        $backupScript | Should -Match '@\{\s*Name\s*=\s*"ScoopHealthCheck"\s*;\s*RelativeScriptPath\s*=\s*"Scoop/Invoke-ScoopHealthCheck\.ps1"\s*;\s*SupportedPlatforms\s*=\s*@\("Windows"\)\s*\}'
        $backupScript | Should -Match '"ScoopHealthCheck"[\s\S]{0,400}"ScoopUpdate"'
    }
}
