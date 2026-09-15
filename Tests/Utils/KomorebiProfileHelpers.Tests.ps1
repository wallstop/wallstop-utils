Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Komorebi/KomorebiProfileHelpers.ps1"

    . $script:helperPath

    function New-KomorebiTestSnapshot {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Directory,

            [Parameter(Mandatory = $true)]
            [string]$Marker
        )

        [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

        $files = @{
            "komorebi.json" = @"
{
  "`$schema": "https://example.invalid/komorebi.schema.json",
  "marker": "$Marker-komorebi",
  "app_specific_configuration_path": "`$Env:USERPROFILE/applications.json"
}
"@
            "komorebi.bar.json" = @"
{
  "`$schema": "https://example.invalid/komorebi.bar.schema.json",
  "marker": "$Marker-bar"
}
"@
            "applications.json" = @"
{
  "`$schema": "https://example.invalid/applications.schema.json",
  "marker": "$Marker-applications"
}
"@
        }

        foreach ($entry in $files.GetEnumerator()) {
            $path = Join-Path -Path $Directory -ChildPath $entry.Key
            [System.IO.File]::WriteAllText($path, $entry.Value, $utf8NoBom)
        }
    }

    function New-KomorebiLegacyYamlSnapshot {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Directory,

            [Parameter(Mandatory = $true)]
            [string]$Marker
        )

        [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

        [System.IO.File]::WriteAllText(
            (Join-Path -Path $Directory -ChildPath "komorebi.json"),
            @"
{
  "`$schema": "https://example.invalid/komorebi.schema.json",
  "marker": "$Marker-komorebi",
  "app_specific_configuration_path": "`$Env:USERPROFILE/applications.yaml"
}
"@,
            $utf8NoBom
        )

        [System.IO.File]::WriteAllText(
            (Join-Path -Path $Directory -ChildPath "komorebi.bar.json"),
            @"
{
  "`$schema": "https://example.invalid/komorebi.bar.schema.json",
  "marker": "$Marker-bar"
}
"@,
            $utf8NoBom
        )

        [System.IO.File]::WriteAllText(
            (Join-Path -Path $Directory -ChildPath "applications.yaml"),
            @"
- name: Legacy Force App
  identifier:
    kind: Title
    id: $Marker-force
    matching_strategy: Equals
  options:
  - force
  float_identifiers:
  - kind: Exe
    id: $Marker-float.exe
    matching_strategy: Equals
- name: Legacy Tray App
  identifier:
    kind: Exe
    id: $Marker-tray.exe
    matching_strategy: Equals
  options:
  - tray_and_multi_window
  - layered
- name: Legacy Compound Float App
  identifier:
    kind: Exe
    id: $Marker-compound.exe
    matching_strategy: Equals
  float_identifiers:
  - - kind: Title
      id: $Marker-popup
      matching_strategy: Equals
    - kind: Exe
      id: $Marker-compound.exe
      matching_strategy: Equals
"@,
            $utf8NoBom
        )
    }

    function Get-KomorebiTestSnapshotMarker {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Directory,

            [Parameter(Mandatory = $false)]
            [string]$FileName = "komorebi.json"
        )

        $path = Join-Path -Path $Directory -ChildPath $FileName
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return [string]$json.marker
    }
}

Describe "Komorebi profile helper behaviors" {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("komorebi-profile-tests-" + [System.Guid]::NewGuid().ToString("N"))
        $script:testRepoRoot = Join-Path -Path $script:testRoot -ChildPath "repo"
        $script:testUserProfileRoot = Join-Path -Path $script:testRoot -ChildPath "user"
        $script:testKomorebiRoot = Join-Path -Path (Join-Path -Path $script:testRepoRoot -ChildPath "Config") -ChildPath "Komorebi"

        [System.IO.Directory]::CreateDirectory($script:testRepoRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($script:testUserProfileRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($script:testKomorebiRoot) | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot -PathType Container) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It "selects an explicit profile before env and machine fallback" {
        $selection = Resolve-KomorebiProfileSelection -ProfileName "desk" -EnvironmentProfileName "env" -MachineName "machine"

        $selection.Name | Should -Be "desk"
        $selection.Source | Should -Be "parameter"
        $selection.IsExplicit | Should -BeTrue
    }

    It "normalizes machine names into path-safe implicit profile names" {
        $selection = Resolve-KomorebiProfileSelection -ProfileName "" -EnvironmentProfileName "" -MachineName "Work Laptop 01!"

        $selection.Name | Should -Be "work-laptop-01"
        $selection.Source | Should -Be "machine"
        $selection.IsExplicit | Should -BeFalse
    }

    It "selects an environment profile before machine fallback" {
        $selection = Resolve-KomorebiProfileSelection -ProfileName "" -EnvironmentProfileName "env-profile" -MachineName "machine"

        $selection.Name | Should -Be "env-profile"
        $selection.Source | Should -Be "environment"
        $selection.IsExplicit | Should -BeTrue
    }

    It "rejects path traversal and separator characters in explicit profile names" {
        { Resolve-KomorebiProfileSelection -ProfileName "../other" -EnvironmentProfileName "" -MachineName "machine" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_PROFILE_NAME_INVALID*"
    }

    It "rejects uppercase, reserved, wildcard, absolute, and trailing-dot profile names" {
        foreach ($profileName in @("Desk", "con", "con.txt", "aux.profile", "lpt1.config", "bad*name", "/absolute", "trailing.")) {
            { Resolve-KomorebiProfileSelection -ProfileName $profileName -EnvironmentProfileName "" -MachineName "machine" } |
                Should -Throw -ExpectedMessage "*E_KOMOREBI_PROFILE_NAME_INVALID*"
        }
    }

    It "backs up live files into the selected profile without overwriting legacy root snapshots" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "live"
        New-KomorebiTestSnapshot -Directory $script:testKomorebiRoot -Marker "legacy"

        $result = Invoke-KomorebiProfileBackup -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk"

        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        $result.ProfileName | Should -Be "desk"
        $result.ProfileDirectory | Should -Be $profileDirectory
        Get-KomorebiTestSnapshotMarker -Directory $profileDirectory | Should -Be "live-komorebi"
        Get-KomorebiTestSnapshotMarker -Directory $script:testKomorebiRoot | Should -Be "legacy-komorebi"
    }

    It "backs up only the selected profile without mutating sibling profiles" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "live"
        $siblingDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "sibling"
        New-KomorebiTestSnapshot -Directory $siblingDirectory -Marker "sibling"

        $null = Invoke-KomorebiProfileBackup -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk"

        Get-KomorebiTestSnapshotMarker -Directory $siblingDirectory | Should -Be "sibling-komorebi"
        Get-KomorebiTestSnapshotMarker -Directory $siblingDirectory -FileName "applications.json" | Should -Be "sibling-applications"
    }

    It "rolls back selected profile files when backup replacement fails midway" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "live"
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        New-KomorebiTestSnapshot -Directory $profileDirectory -Marker "previous"

        $script:profileApplicationsPath = Join-Path -Path $profileDirectory -ChildPath "applications.json"
        Mock -CommandName Copy-Item -MockWith {
            param(
                [string]$LiteralPath,
                [string]$Destination,
                [switch]$Force,
                $ErrorAction
            )

            if ($Destination -eq $script:profileApplicationsPath -and $LiteralPath -notmatch 'backup') {
                throw "simulated backup applications failure"
            }

            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
        }

        { Invoke-KomorebiProfileBackup -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_BACKUP_COPY_FAILED*"

        Get-KomorebiTestSnapshotMarker -Directory $profileDirectory | Should -Be "previous-komorebi"
        Get-KomorebiTestSnapshotMarker -Directory $profileDirectory -FileName "applications.json" | Should -Be "previous-applications"
    }

    It "removes a newly-created profile directory when backup replacement fails" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "live"
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        $script:newProfileApplicationsPath = Join-Path -Path $profileDirectory -ChildPath "applications.json"

        Mock -CommandName Copy-Item -MockWith {
            param(
                [string]$LiteralPath,
                [string]$Destination,
                [switch]$Force,
                $ErrorAction
            )

            if ($Destination -eq $script:newProfileApplicationsPath -and $LiteralPath -notmatch 'backup') {
                throw "simulated new-profile backup applications failure"
            }

            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
        }

        { Invoke-KomorebiProfileBackup -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_BACKUP_COPY_FAILED*"

        $remainingItems = if (Test-Path -LiteralPath $profileDirectory -PathType Container) {
            @((Get-ChildItem -LiteralPath $profileDirectory -Force) | ForEach-Object { $_.Name }) -join ","
        }
        else {
            "(removed)"
        }
        Test-Path -LiteralPath $profileDirectory -PathType Container | Should -BeFalse -Because "failed new-profile backup rollback must remove profile directory; remainingItems=$remainingItems"
    }

    It "backs up live files without creating legacy root snapshots" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "live"

        $null = Invoke-KomorebiProfileBackup -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk"

        foreach ($fileName in Get-KomorebiRequiredConfigFileNames) {
            Test-Path -LiteralPath (Join-Path -Path $script:testKomorebiRoot -ChildPath $fileName) -PathType Leaf |
                Should -BeFalse -Because "profile backup must not create legacy root snapshots."
        }
    }

    It "restores an explicit profile without falling back to default" {
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        $defaultDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "default"
        New-KomorebiTestSnapshot -Directory $profileDirectory -Marker "desk"
        New-KomorebiTestSnapshot -Directory $defaultDirectory -Marker "default"

        $result = Invoke-KomorebiProfileRestore -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk"

        $result.ProfileName | Should -Be "desk"
        $result.ProfileSource | Should -Be "parameter"
        Get-KomorebiTestSnapshotMarker -Directory $script:testUserProfileRoot | Should -Be "desk-komorebi"
    }

    It "rolls back live files when restore replacement fails midway" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "original"
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        New-KomorebiTestSnapshot -Directory $profileDirectory -Marker "desk"

        $script:liveApplicationsPath = Join-Path -Path $script:testUserProfileRoot -ChildPath "applications.json"
        Mock -CommandName Copy-Item -MockWith {
            param(
                [string]$LiteralPath,
                [string]$Destination,
                [switch]$Force,
                $ErrorAction
            )

            if ($Destination -eq $script:liveApplicationsPath -and $LiteralPath -notmatch 'backup') {
                throw "simulated applications restore failure"
            }

            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
        }

        { Invoke-KomorebiProfileRestore -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_RESTORE_COPY_FAILED*"

        Get-KomorebiTestSnapshotMarker -Directory $script:testUserProfileRoot | Should -Be "original-komorebi"
        Get-KomorebiTestSnapshotMarker -Directory $script:testUserProfileRoot -FileName "applications.json" | Should -Be "original-applications"
    }

    It "does not overwrite live files when restore source JSON is invalid" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "original"
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        New-KomorebiTestSnapshot -Directory $profileDirectory -Marker "desk"
        [System.IO.File]::WriteAllText(
            (Join-Path -Path $profileDirectory -ChildPath "komorebi.json"),
            "{ invalid json",
            [System.Text.UTF8Encoding]::new($false)
        )

        { Invoke-KomorebiProfileRestore -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_RESTORE_JSON_INVALID*"

        Get-KomorebiTestSnapshotMarker -Directory $script:testUserProfileRoot | Should -Be "original-komorebi"
        Get-KomorebiTestSnapshotMarker -Directory $script:testUserProfileRoot -FileName "applications.json" | Should -Be "original-applications"
    }

    It "fails implicit restore when the selected machine profile is missing" {
        $defaultDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "default"
        New-KomorebiTestSnapshot -Directory $defaultDirectory -Marker "default"
        New-KomorebiTestSnapshot -Directory $script:testKomorebiRoot -Marker "legacy"

        { Invoke-KomorebiProfileRestore -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -MachineName "new-machine" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_RESTORE_PROFILE_MISSING*"

        Test-Path -LiteralPath (Join-Path -Path $script:testUserProfileRoot -ChildPath "komorebi.json") -PathType Leaf |
            Should -BeFalse -Because "restore must not silently apply default or legacy root snapshots for unknown machines."
    }

    It "fails explicit restore when the requested profile is missing" {
        $defaultDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "default"
        New-KomorebiTestSnapshot -Directory $defaultDirectory -Marker "default"

        { Invoke-KomorebiProfileRestore -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "missing" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_RESTORE_PROFILE_MISSING*"
    }

    It "fails restore when the selected profile is incomplete" {
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "broken"
        [System.IO.Directory]::CreateDirectory($profileDirectory) | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path -Path $profileDirectory -ChildPath "komorebi.json"),
            "{}",
            [System.Text.UTF8Encoding]::new($false)
        )

        { Invoke-KomorebiProfileRestore -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "broken" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_RESTORE_PROFILE_INCOMPLETE*"
    }

    It "rejects invalid JSON before backing up into a profile" {
        New-KomorebiTestSnapshot -Directory $script:testUserProfileRoot -Marker "live"
        [System.IO.File]::WriteAllText(
            (Join-Path -Path $script:testUserProfileRoot -ChildPath "komorebi.json"),
            "{ invalid json",
            [System.Text.UTF8Encoding]::new($false)
        )

        { Invoke-KomorebiProfileBackup -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -ProfileName "desk" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_BACKUP_JSON_INVALID*"
    }

    It "initializes a restorable machine profile from a legacy root snapshot" {
        New-KomorebiLegacyYamlSnapshot -Directory $script:testKomorebiRoot -Marker "legacy"

        $result = Initialize-KomorebiProfileFromLegacyRoot -RepositoryRoot $script:testRepoRoot -MachineName "Workstation 42"

        $result.ProfileName | Should -Be "workstation-42"
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "workstation-42"
        Get-KomorebiTestSnapshotMarker -Directory $profileDirectory | Should -Be "legacy-komorebi"
        $profileConfig = Get-Content -LiteralPath (Join-Path -Path $profileDirectory -ChildPath "komorebi.json") -Raw | ConvertFrom-Json
        $profileConfig.app_specific_configuration_path | Should -Be '$Env:USERPROFILE/applications.json'
        $profileApplications = Get-Content -LiteralPath (Join-Path -Path $profileDirectory -ChildPath "applications.json") -Raw | ConvertFrom-Json
        $profileApplications."Legacy Force App".manage[0].id | Should -Be "legacy-force"
        $profileApplications."Legacy Force App".ignore[0].id | Should -Be "legacy-float.exe"
        $profileApplications."Legacy Tray App".tray_and_multi_window[0].id | Should -Be "legacy-tray.exe"
        $profileApplications."Legacy Tray App".layered[0].id | Should -Be "legacy-tray.exe"
        $profileApplications."Legacy Compound Float App".ignore[0][0].id | Should -Be "legacy-popup"

        $restoreResult = Invoke-KomorebiProfileRestore -RepositoryRoot $script:testRepoRoot -UserProfileRoot $script:testUserProfileRoot -MachineName "Workstation 42"
        $restoreResult.ProfileName | Should -Be "workstation-42"
        Get-KomorebiTestSnapshotMarker -Directory $script:testUserProfileRoot | Should -Be "legacy-komorebi"
    }

    It "rolls back initialized profile files when legacy migration replacement fails midway" {
        New-KomorebiLegacyYamlSnapshot -Directory $script:testKomorebiRoot -Marker "legacy"
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        New-KomorebiTestSnapshot -Directory $profileDirectory -Marker "previous"

        $script:migrationApplicationsPath = Join-Path -Path $profileDirectory -ChildPath "applications.json"
        Mock -CommandName Copy-Item -MockWith {
            param(
                [string]$LiteralPath,
                [string]$Destination,
                [switch]$Force,
                $ErrorAction
            )

            if ($Destination -eq $script:migrationApplicationsPath -and $LiteralPath -notmatch 'backup') {
                throw "simulated migration applications failure"
            }

            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
        }

        { Initialize-KomorebiProfileFromLegacyRoot -RepositoryRoot $script:testRepoRoot -ProfileName "desk" -Force } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_MIGRATION_COPY_FAILED*"

        Get-KomorebiTestSnapshotMarker -Directory $profileDirectory | Should -Be "previous-komorebi"
        Get-KomorebiTestSnapshotMarker -Directory $profileDirectory -FileName "applications.json" | Should -Be "previous-applications"
    }

    It "removes a newly-created profile directory when legacy migration replacement fails" {
        New-KomorebiLegacyYamlSnapshot -Directory $script:testKomorebiRoot -Marker "legacy"
        $profileDirectory = Join-Path -Path (Join-Path -Path $script:testKomorebiRoot -ChildPath "profiles") -ChildPath "desk"
        $script:newMigrationApplicationsPath = Join-Path -Path $profileDirectory -ChildPath "applications.json"

        Mock -CommandName Copy-Item -MockWith {
            param(
                [string]$LiteralPath,
                [string]$Destination,
                [switch]$Force,
                $ErrorAction
            )

            if ($Destination -eq $script:newMigrationApplicationsPath -and $LiteralPath -notmatch 'backup') {
                throw "simulated new-profile migration applications failure"
            }

            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
        }

        { Initialize-KomorebiProfileFromLegacyRoot -RepositoryRoot $script:testRepoRoot -ProfileName "desk" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_MIGRATION_COPY_FAILED*"

        Test-Path -LiteralPath $profileDirectory -PathType Container | Should -BeFalse
    }
}

Describe "Komorebi monitor configuration validation" {
    BeforeEach {
        # Physical order, left to right: DISPLAY2 (portrait, x=-1080), DISPLAY1 (x=0), DISPLAY3 (x=3840).
        # Komorebi enumerates them DISPLAY1, DISPLAY2, DISPLAY3.
        $script:testMonitors = @(
            [pscustomobject]@{
                name             = "DISPLAY1"
                device           = "DEL429B"
                device_id        = "DEL429B-5&9221308&0&UID8449"
                serial_number_id = "G7STF34"
                size             = [pscustomobject]@{ left = 0; top = 0; right = 3840; bottom = 2160 }
            },
            [pscustomobject]@{
                name             = "DISPLAY2"
                device           = "DEL41F3"
                device_id        = "DEL41F3-5&9221308&0&UID8453"
                serial_number_id = "9K42DP3"
                size             = [pscustomobject]@{ left = -1080; top = 106; right = 1080; bottom = 1920 }
            },
            [pscustomobject]@{
                name             = "DISPLAY3"
                device           = "DEL429A"
                device_id        = "DEL429A-5&9221308&0&UID8451"
                serial_number_id = "CSLQNF4"
                size             = [pscustomobject]@{ left = 3840; top = 0; right = 3840; bottom = 2160 }
            }
        )

        $script:testConfigJson = @'
{
  "display_index_preferences": {
    "0": "G7STF34",
    "1": "9K42DP3",
    "2": "CSLQNF4"
  },
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Left", "layout": "Rows" } ] },
    { "workspaces": [ { "name": "Right", "layout": "Grid" } ] }
  ]
}
'@
    }

    It "pairs each display with the monitors[] entry its serial number points at" {
        $config = $script:testConfigJson | ConvertFrom-Json

        $assignments = @(Get-KomorebiMonitorConfigAssignment -Config $config -Monitors $script:testMonitors)

        $assignments.Count | Should -Be 3
        @($assignments | Where-Object { $_.SerialNumberId -eq "G7STF34" })[0].ConfigIndex | Should -Be 0
        @($assignments | Where-Object { $_.SerialNumberId -eq "9K42DP3" })[0].ConfigIndex | Should -Be 1
        @($assignments | Where-Object { $_.SerialNumberId -eq "CSLQNF4" })[0].ConfigIndex | Should -Be 2
        @($assignments | Where-Object { $_.MatchedBy -ne "preference" }).Count | Should -Be 0
    }

    It "gives the spicy RDP display Grid without consuming physical display slots" {
        $path = Join-Path -Path $PSScriptRoot -ChildPath "../../Config/Komorebi/profiles/spicy/komorebi.json"
        $config = Read-KomorebiStaticConfig -Path $path
        $remoteMonitor = [pscustomobject]@{
            name             = "DISPLAY1"
            device_id        = "Default_Monitor-1&c528b8a&1&UID256"
            serial_number_id = $null
            size             = [pscustomobject]@{ left = 0 }
        }

        $assignments = @(Assert-KomorebiMonitorConfiguration -Config $config -Monitors @($remoteMonitor) -ConfigPath $path)

        $assignments.Count | Should -Be 1
        $assignments[0].MatchedBy | Should -Be "sequential"
        $assignments[0].Workspaces[0].layout | Should -Be "Grid"
        $assignments[0].Workspaces[0].name | Should -Be "Grid"

        $physical = @(Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath $path)
        @($physical | ForEach-Object { $_.ConfigIndex }) | Should -Be @(0, 1, 2)
        @($physical | ForEach-Object { $_.Workspaces[0].layout }) | Should -Be @("Grid", "Rows", "Grid")
        @($physical | Where-Object { $_.MatchedBy -ne "preference" }).Count | Should -Be 0
    }

    It "matches display_index_preferences on device_id as well as serial_number_id" {
        $config = @'
{
  "display_index_preferences": {
    "0": "DEL429B-5&9221308&0&UID8449",
    "1": "DEL41F3-5&9221308&0&UID8453",
    "2": "DEL429A-5&9221308&0&UID8451"
  },
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Left", "layout": "Rows" } ] },
    { "workspaces": [ { "name": "Right", "layout": "Grid" } ] }
  ]
}
'@ | ConvertFrom-Json

        $assignments = @(Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "device-id.json")

        @($assignments | Where-Object { $_.MatchedBy -ne "preference" }).Count | Should -Be 0
    }

    It "falls back to sequential pairing when no display_index_preferences are declared" {
        $config = @'
{
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Left", "layout": "Rows" } ] },
    { "workspaces": [ { "name": "Right", "layout": "Grid" } ] }
  ]
}
'@ | ConvertFrom-Json

        $assignments = @(Get-KomorebiMonitorConfigAssignment -Config $config -Monitors $script:testMonitors)

        @($assignments | ForEach-Object { $_.ConfigIndex }) | Should -Be @(0, 1, 2)
        @($assignments | Where-Object { $_.MatchedBy -ne "sequential" }).Count | Should -Be 0
    }

    It "rejects display ids that match no connected display and starve every monitor of config" {
        # Regression: display_index_preferences held GDI names ("DISPLAY1"), which match neither
        # serial_number_id nor device_id. Those entries still reserve monitors[] indexes 0-2, so the
        # sequential fallback finds nothing and every workspace silently reverts to BSP.
        $config = @'
{
  "display_index_preferences": {
    "0": "DISPLAY1",
    "1": "DISPLAY2",
    "2": "DISPLAY3"
  },
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Right", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Left", "layout": "Rows" } ] }
  ]
}
'@ | ConvertFrom-Json

        $assignments = @(Get-KomorebiMonitorConfigAssignment -Config $config -Monitors $script:testMonitors)
        @($assignments | Where-Object { $null -eq $_.ConfigIndex }).Count | Should -Be 3

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "broken.json" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_MONITOR_CONFIG_UNASSIGNED*"
    }

    It "names the offending display ids so the diagnostic is actionable" {
        $config = $script:testConfigJson.Replace("G7STF34", "DISPLAY1") | ConvertFrom-Json

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "partial.json" } |
            Should -Throw -ExpectedMessage "*DISPLAY1*"
    }

    It "rejects positional workspace names that do not follow physical left-to-right order" {
        # Regression: monitors[] listed Middle, Right, Left while the displays enumerate
        # middle, left, right, so "Right" landed on the left-hand portrait panel.
        $config = @'
{
  "display_index_preferences": {
    "0": "G7STF34",
    "1": "9K42DP3",
    "2": "CSLQNF4"
  },
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Right", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Left", "layout": "Rows" } ] }
  ]
}
'@ | ConvertFrom-Json

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "swapped.json" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_MONITOR_LAYOUT_POSITION_MISMATCH*"
    }

    It "ignores non-positional workspace names when checking display order" {
        $config = @'
{
  "monitors": [
    { "workspaces": [ { "name": "Code", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Chat", "layout": "Rows" } ] },
    { "workspaces": [ { "name": "Web", "layout": "Grid" } ] }
  ]
}
'@ | ConvertFrom-Json

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "named.json" } |
            Should -Not -Throw
    }

    It "rejects display_index_preferences indexes outside the monitors array" {
        $config = @'
{
  "display_index_preferences": { "0": "G7STF34", "5": "9K42DP3" },
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Left", "layout": "Rows" } ] }
  ]
}
'@ | ConvertFrom-Json

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "range.json" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_DISPLAY_PREFERENCE_INDEX_INVALID*"
    }

    It "rejects non-numeric display_index_preferences keys" {
        $config = @'
{
  "display_index_preferences": { "left": "9K42DP3" },
  "monitors": [ { "workspaces": [ { "name": "Left", "layout": "Rows" } ] } ]
}
'@ | ConvertFrom-Json

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "keys.json" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_DISPLAY_PREFERENCE_INDEX_INVALID*"
    }

    It "rejects a display id mapped to more than one monitors[] index" {
        $config = @'
{
  "display_index_preferences": { "0": "G7STF34", "1": "G7STF34", "2": "CSLQNF4" },
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Left", "layout": "Rows" } ] },
    { "workspaces": [ { "name": "Right", "layout": "Grid" } ] }
  ]
}
'@ | ConvertFrom-Json

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "dupe.json" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_DISPLAY_PREFERENCE_DUPLICATE*"
    }

    It "tolerates a preferred display that is not currently connected" {
        $config = @'
{
  "display_index_preferences": { "0": "G7STF34", "1": "LAPTOP-PANEL" },
  "monitors": [
    { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] },
    { "workspaces": [ { "name": "Docked", "layout": "Rows" } ] }
  ]
}
'@ | ConvertFrom-Json

        $singleMonitor = @($script:testMonitors[0])

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $singleMonitor -ConfigPath "docked.json" } |
            Should -Not -Throw
    }

    It "accepts a config that omits the monitors array entirely" {
        $config = '{ "border": false }' | ConvertFrom-Json

        { Assert-KomorebiMonitorConfiguration -Config $config -Monitors $script:testMonitors -ConfigPath "bare.json" } |
            Should -Not -Throw
    }

    It "reads and rejects malformed static configuration files" {
        $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("komorebi-static-" + [System.Guid]::NewGuid().ToString("N") + ".json")
        try {
            [System.IO.File]::WriteAllText($path, "{ not json", [System.Text.UTF8Encoding]::new($false))

            { Read-KomorebiStaticConfig -Path $path } | Should -Throw -ExpectedMessage "*E_KOMOREBI_STATIC_CONFIG_INVALID*"
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports a missing static configuration file with a stable diagnostic" {
        $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("komorebi-absent-" + [System.Guid]::NewGuid().ToString("N") + ".json")

        { Read-KomorebiStaticConfig -Path $path } | Should -Throw -ExpectedMessage "*E_KOMOREBI_STATIC_CONFIG_MISSING*"
    }
}

Describe "Komorebi applied configuration verification" {
    BeforeEach {
        $script:appliedMonitors = @(
            [pscustomobject]@{
                name             = "DISPLAY1"
                device_id        = "DEL429B-5&9221308&0&UID8449"
                serial_number_id = "G7STF34"
                size             = [pscustomobject]@{ left = 0; top = 0; right = 3840; bottom = 2160 }
            }
        )

        $script:appliedConfig = @'
{
  "display_index_preferences": { "0": "G7STF34" },
  "monitors": [ { "workspaces": [ { "name": "Middle", "layout": "Grid" } ] } ]
}
'@ | ConvertFrom-Json
    }

    It "passes when Komorebi applied the configured workspace name and layout" {
        $assignments = @(Get-KomorebiMonitorConfigAssignment -Config $script:appliedConfig -Monitors $script:appliedMonitors)
        $state = @'
{
  "monitors": {
    "elements": [
      {
        "name": "DISPLAY1",
        "device_id": "DEL429B-5&9221308&0&UID8449",
        "workspaces": { "elements": [ { "name": "Middle", "layout": { "Default": "Grid" } } ] }
      }
    ]
  }
}
'@ | ConvertFrom-Json

        { Assert-KomorebiAppliedConfiguration -Assignments $assignments -State $state -ConfigPath "live.json" } |
            Should -Not -Throw
    }

    It "fails when Komorebi left a workspace on the default layout" {
        # This is what the live state looked like while the config was silently ignored.
        $assignments = @(Get-KomorebiMonitorConfigAssignment -Config $script:appliedConfig -Monitors $script:appliedMonitors)
        $state = @'
{
  "monitors": {
    "elements": [
      {
        "name": "DISPLAY1",
        "device_id": "DEL429B-5&9221308&0&UID8449",
        "workspaces": { "elements": [ { "name": null, "layout": { "Default": "BSP" } } ] }
      }
    ]
  }
}
'@ | ConvertFrom-Json

        { Assert-KomorebiAppliedConfiguration -Assignments $assignments -State $state -ConfigPath "live.json" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_MONITOR_CONFIG_NOT_APPLIED*"
    }

    It "fails when a configured display is absent from the live state" {
        $assignments = @(Get-KomorebiMonitorConfigAssignment -Config $script:appliedConfig -Monitors $script:appliedMonitors)
        $state = '{ "monitors": { "elements": [] } }' | ConvertFrom-Json

        { Assert-KomorebiAppliedConfiguration -Assignments $assignments -State $state -ConfigPath "live.json" } |
            Should -Throw -ExpectedMessage "*E_KOMOREBI_MONITOR_CONFIG_NOT_APPLIED*"
    }

    It "does not compare layout when the workspace uses a custom layout" {
        $config = @'
{
  "display_index_preferences": { "0": "G7STF34" },
  "monitors": [ { "workspaces": [ { "name": "Middle", "layout": "Grid", "custom_layout": "C:/layouts/middle.json" } ] } ]
}
'@ | ConvertFrom-Json
        $assignments = @(Get-KomorebiMonitorConfigAssignment -Config $config -Monitors $script:appliedMonitors)
        $state = @'
{
  "monitors": {
    "elements": [
      {
        "name": "DISPLAY1",
        "device_id": "DEL429B-5&9221308&0&UID8449",
        "workspaces": { "elements": [ { "name": "Middle", "layout": { "Custom": [] } } ] }
      }
    ]
  }
}
'@ | ConvertFrom-Json

        { Assert-KomorebiAppliedConfiguration -Assignments $assignments -State $state -ConfigPath "live.json" } |
            Should -Not -Throw
    }
}

Describe "Komorebi repository profile layout invariants" {
    It "keeps every checked-in profile config internally consistent" {
        $repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
        $profilesRoot = Join-Path -Path (Join-Path -Path (Join-Path -Path $repoRoot -ChildPath "Config") -ChildPath "Komorebi") -ChildPath "profiles"
        $configPaths = @(Get-ChildItem -LiteralPath $profilesRoot -Filter "komorebi.json" -Recurse -File | ForEach-Object { $_.FullName })

        $configPaths.Count | Should -BeGreaterThan 0

        foreach ($configPath in $configPaths) {
            $config = Read-KomorebiStaticConfig -Path $configPath
            $monitorConfigs = @(Get-KomorebiObjectProperty -InputObject $config -Name "monitors")
            $preferenceMap = Get-KomorebiDisplayIndexPreferenceMap -Config $config

            $preferenceMap.InvalidKeys.Count | Should -Be 0 -Because "$configPath must use numeric display_index_preferences keys"

            foreach ($entry in $preferenceMap.Entries) {
                $entry.ConfigIndex | Should -BeLessThan $monitorConfigs.Count -Because "$configPath maps a display to a monitors[] index that does not exist"
                # GDI display names are the classic wrong value here: they match neither
                # serial_number_id nor device_id, so Komorebi silently drops the whole config.
                $entry.Id | Should -Not -Match '^(?i)\\\\?\.?\\?DISPLAY\d+$' -Because "$configPath must key display_index_preferences on serial_number_id or device_id, not a GDI display name"
            }

            $preferenceIds = @($preferenceMap.Entries | ForEach-Object { $_.Id })
            @($preferenceIds | Sort-Object -Unique).Count | Should -Be $preferenceIds.Count -Because "$configPath must not map one display to two monitors[] indexes"
        }
    }
}
