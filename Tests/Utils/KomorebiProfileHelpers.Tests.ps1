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
