Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '../Utils/Common/CompatibilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $compatibilityHelpersPath

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
Push-Location -LiteralPath $baseDirectory

try {
    $settingsDir = Join-Path -Path $baseDirectory -ChildPath 'Config'
    $settingsDir = Join-Path -Path $settingsDir -ChildPath 'Powershell'
    if (-not (Test-Path -LiteralPath $settingsDir -PathType Container)) {
        Write-Error "E_POWERSHELL_RESTORE_SOURCE_MISSING: PowerShell settings backup folder not found at '$settingsDir'."
        exit 1
    }

    $profileLeafName = 'Microsoft.PowerShell_profile.ps1'
    $candidateBackups = @(
        Get-ChildItem -LiteralPath $settingsDir -Filter "*$profileLeafName" -File -ErrorAction SilentlyContinue |
            Sort-Object Name -CaseSensitive
    )
    if ($candidateBackups.Count -eq 0) {
        Write-Error "E_POWERSHELL_RESTORE_SOURCE_MISSING: PowerShell settings backup not found in '$settingsDir'."
        exit 1
    }

    $prefixedBackups = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidateBackups) {
        if ($candidate.Name -match '^(?<profileName>[^_]+)_(?<leafName>.+)$' -and $Matches['leafName'] -ieq $profileLeafName) {
            if (-not $prefixedBackups.ContainsKey($Matches['profileName'])) {
                $prefixedBackups[$Matches['profileName']] = $candidate.FullName
            }
        }
    }

    $canonicalBackup = @($candidateBackups | Where-Object { $_.Name -ieq $profileLeafName } | Select-Object -First 1)
    $fallbackBackupPath = $candidateBackups[0].FullName
    if (-not (Test-Path -LiteralPath $fallbackBackupPath -PathType Leaf)) {
        Write-Error "E_POWERSHELL_RESTORE_FALLBACK_SOURCE_INVALID: Computed fallback source does not exist at '$fallbackBackupPath'."
        exit 1
    }

    Write-Verbose (
        "PowerShell restore source diagnostics: settingsDir='{0}'; candidateCount={1}; candidates='{2}'; hasCanonical={3}" -f
        $settingsDir,
        $candidateBackups.Count,
        (($candidateBackups | ForEach-Object { $_.Name }) -join ', '),
        ($canonicalBackup.Count -gt 0)
    )

    function Get-PreferredBackupForProfileName {
        param(
            [string]$profileName,
            [string[]]$fallbackProfileNames,
            [System.Collections.Generic.Dictionary[string, string]]$profileBackups,
            [System.IO.FileInfo[]]$canonicalSource,
            [string]$defaultBackup
        )

        if ($profileBackups.ContainsKey($profileName)) {
            return $profileBackups[$profileName]
        }

        foreach ($fallbackName in $fallbackProfileNames) {
            if ($profileBackups.ContainsKey($fallbackName)) {
                return $profileBackups[$fallbackName]
            }
        }

        if ($canonicalSource.Count -gt 0) {
            return $canonicalSource[0].FullName
        }

        Write-Verbose ("PowerShell restore fallback diagnostics: targetProfile='{0}'; selectedFallback='{1}'; reason=no_profile_specific_or_canonical_match" -f $profileName, (Split-Path -Path $defaultBackup -Leaf))
        return $defaultBackup
    }

    $targetPathComparer = if (Test-IsWindowsPlatform) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }

    $profileTargets = New-Object System.Collections.Generic.List[object]
    $seenTargetPaths = New-Object System.Collections.Generic.HashSet[string]($targetPathComparer)

    $currentUserCurrentHostPath = [string]$PROFILE.CurrentUserCurrentHost
    if (-not [string]::IsNullOrWhiteSpace($currentUserCurrentHostPath) -and $seenTargetPaths.Add($currentUserCurrentHostPath)) {
        [void]$profileTargets.Add([pscustomobject]@{
                Name         = 'CurrentUserCurrentHost'
                Path         = $currentUserCurrentHostPath
                FallbackList = @('CurrentUserAllHosts', 'WindowsPowerShellFallback')
            })
    }

    $currentUserAllHostsPath = [string]$PROFILE.CurrentUserAllHosts
    if (-not [string]::IsNullOrWhiteSpace($currentUserAllHostsPath) -and $seenTargetPaths.Add($currentUserAllHostsPath)) {
        [void]$profileTargets.Add([pscustomobject]@{
                Name         = 'CurrentUserAllHosts'
                Path         = $currentUserAllHostsPath
                FallbackList = @('CurrentUserCurrentHost', 'WindowsPowerShellFallback')
            })
    }

    if (Test-IsWindowsPlatform) {
        $documentsPath = Join-Path -Path $HOME -ChildPath 'Documents'
        $windowsPowerShellLegacyPath = Join-Path -Path $documentsPath -ChildPath 'WindowsPowerShell'
        $windowsPowerShellLegacyPath = Join-Path -Path $windowsPowerShellLegacyPath -ChildPath $profileLeafName

        if ($seenTargetPaths.Add($windowsPowerShellLegacyPath)) {
            [void]$profileTargets.Add([pscustomobject]@{
                    Name         = 'WindowsPowerShellFallback'
                    Path         = $windowsPowerShellLegacyPath
                    FallbackList = @('CurrentUserCurrentHost', 'CurrentUserAllHosts')
                })
        }
    }

    if ($profileTargets.Count -eq 0) {
        Write-Error 'E_POWERSHELL_RESTORE_NO_TARGET_PROFILES: No destination profile paths were discovered from $PROFILE for this platform.'
        exit 1
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFolder = Join-Path -Path $HOME -ChildPath 'PowerShell_Settings_Backup'
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($backupFolder) | Out-Null
    }

    $profilesRestored = 0
    foreach ($target in $profileTargets) {
        $sourcePath = Get-PreferredBackupForProfileName -profileName $target.Name -fallbackProfileNames $target.FallbackList -profileBackups $prefixedBackups -canonicalSource $canonicalBackup -defaultBackup $fallbackBackupPath

        Write-Verbose ("PowerShell restore target diagnostics: targetProfile='{0}'; destinationPath='{1}'; sourcePath='{2}'" -f $target.Name, $target.Path, $sourcePath)

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            Write-Error "E_POWERSHELL_RESTORE_SELECTED_SOURCE_MISSING: Selected backup source for '$($target.Name)' does not exist at '$sourcePath'."
            exit 1
        }

        $targetDirectory = Split-Path -Path $target.Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($targetDirectory) -and -not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            Write-Host "PowerShell profile directory not found at $targetDirectory, creating..."
            [System.IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
        }

        if (Test-Path -LiteralPath $target.Path -PathType Leaf) {
            $existingBackupName = "{0}_{1}_{2}" -f $target.Name, $timestamp, $profileLeafName
            $existingBackupPath = Join-Path -Path $backupFolder -ChildPath $existingBackupName
            Copy-Item -LiteralPath $target.Path -Destination $existingBackupPath -Force
            Write-Host "Current PowerShell profile ($($target.Name)) backed up to $existingBackupPath"
        }
        else {
            Write-Warning "W_POWERSHELL_RESTORE_NO_EXISTING_TARGET_PROFILE($($target.Name)): No existing profile found at '$($target.Path)'; skipping safety backup."
        }

        Copy-Item -LiteralPath $sourcePath -Destination $target.Path -Force
        $profilesRestored++
    }

    Write-Host ("PowerShell settings restored successfully for {0} profile target(s) from '{1}'." -f $profilesRestored, $settingsDir)
}
finally {
    Pop-Location
}
