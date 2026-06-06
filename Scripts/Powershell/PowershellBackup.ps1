Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '../Utils/Common/CompatibilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $compatibilityHelpersPath

$psReadLineProfilePortabilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath '../Utils/Common/PSReadLineProfilePortabilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $psReadLineProfilePortabilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: PSReadLine profile portability helper file not found at '$psReadLineProfilePortabilityHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $psReadLineProfilePortabilityHelpersPath

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$backupFolder = Join-Path -Path (Join-Path -Path $baseDirectory -ChildPath "Config") -ChildPath "Powershell"
Push-Location -LiteralPath $baseDirectory

function Assert-PowerShellProfileBackupPortability {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    try {
        $violations = @(Get-PSReadLineProfilePortabilityViolation -Path $resolvedPath)
    }
    catch {
        throw (
            "E_POWERSHELL_BACKUP_PROFILE_PARSE_FAILED: PowerShell profile '{0}' at '{1}' could not be parsed before backup. error={2}" -f
            $ProfileName,
            $resolvedPath,
            $_.Exception.Message
        )
    }

    if ($violations.Count -gt 0) {
        throw (
            "E_POWERSHELL_BACKUP_PROFILE_PORTABILITY: PowerShell profile '{0}' at '{1}' contains PSReadLine setup that is not guarded for Windows PowerShell 5.1 and older PSReadLine versions. violations={2}. Restore the repository profile or update the source profile before backup." -f
            $ProfileName,
            $resolvedPath,
            ($violations -join ',')
        )
    }
}

try {
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($backupFolder) | Out-Null
    }

    $profilesBackedUp = 0

    $candidateProfiles = New-Object System.Collections.Generic.List[object]
    [void]$candidateProfiles.Add([pscustomobject]@{
            Name = "CurrentUserCurrentHost"
            Path = $PROFILE.CurrentUserCurrentHost
        })
    [void]$candidateProfiles.Add([pscustomobject]@{
            Name = "CurrentUserAllHosts"
            Path = $PROFILE.CurrentUserAllHosts
        })

    if (Test-IsWindowsPlatform) {
        $documentsPath = Join-Path -Path $HOME -ChildPath "Documents"
        [void]$candidateProfiles.Add([pscustomobject]@{
                Name = "WindowsPowerShellFallback"
                Path = Join-Path -Path (Join-Path -Path $documentsPath -ChildPath "WindowsPowerShell") -ChildPath "Microsoft.PowerShell_profile.ps1"
            })
    }

    $pathComparer = if (Test-IsWindowsPlatform) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }

    $seenProfilePaths = New-Object System.Collections.Generic.HashSet[string]($pathComparer)
    $normalizedCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidateProfiles) {
        if ([string]::IsNullOrWhiteSpace($candidate.Path)) {
            continue
        }

        $trimmedPath = $candidate.Path.Trim()
        if (-not $seenProfilePaths.Add($trimmedPath)) {
            continue
        }

        [void]$normalizedCandidates.Add([pscustomobject]@{
                Name = $candidate.Name
                Path = $trimmedPath
            })
    }

    foreach ($candidate in $normalizedCandidates) {
        if (Test-Path -LiteralPath $candidate.Path -PathType Leaf) {
            Assert-PowerShellProfileBackupPortability -ProfileName $candidate.Name -Path $candidate.Path
        }
    }

    Write-Verbose (
        "PowerShell backup profile discovery diagnostics: candidateCount={0}; backupFolder='{1}'" -f
        $normalizedCandidates.Count,
        $backupFolder
    )

    $canonicalLeafName = "Microsoft.PowerShell_profile.ps1"
    $canonicalBackupFile = Join-Path -Path $backupFolder -ChildPath $canonicalLeafName
    $canonicalBackupSourceProfile = $null

    foreach ($candidate in $normalizedCandidates) {
        if (Test-Path -LiteralPath $candidate.Path -PathType Leaf) {
            $leafName = [System.IO.Path]::GetFileName($candidate.Path)
            $destinationFileName = "{0}_{1}" -f $candidate.Name, $leafName
            $backupFile = Join-Path -Path $backupFolder -ChildPath $destinationFileName
            Copy-Item -LiteralPath $candidate.Path -Destination $backupFile -Force
            $profilesBackedUp++
            Write-Host ("PowerShell profile '{0}' exported successfully from '{1}' to '{2}'." -f $candidate.Name, $candidate.Path, $backupFile) -ForegroundColor Green

            if ($leafName -ieq $canonicalLeafName) {
                $shouldWriteCanonicalBackup = [string]::IsNullOrWhiteSpace($canonicalBackupSourceProfile) -or $candidate.Name -eq "CurrentUserCurrentHost"
                if ($shouldWriteCanonicalBackup) {
                    Copy-Item -LiteralPath $candidate.Path -Destination $canonicalBackupFile -Force
                    $canonicalBackupSourceProfile = $candidate.Name
                    Write-Verbose ("PowerShell canonical backup diagnostics: canonicalProfileSource='{0}'; canonicalBackupFile='{1}'" -f $candidate.Name, $canonicalBackupFile)
                }
            }

            continue
        }

        Write-Warning ("W_POWERSHELL_BACKUP_PROFILE_MISSING({0}): PowerShell profile not found at '{1}'." -f $candidate.Name, $candidate.Path)
    }

    if ($profilesBackedUp -eq 0) {
        Write-Error "E_POWERSHELL_BACKUP_NO_PROFILES_FOUND: No PowerShell profile files were found to back up from discovered CurrentUser profile paths."
        exit 1
    }

    Write-Verbose (
        "PowerShell backup output diagnostics: profilesBackedUp={0}; canonicalBackupFile='{1}'; canonicalSourceProfile='{2}'" -f
        $profilesBackedUp,
        $canonicalBackupFile,
        $(if ([string]::IsNullOrWhiteSpace($canonicalBackupSourceProfile)) { "none" } else { $canonicalBackupSourceProfile })
    )
}
finally {
    Pop-Location
}
