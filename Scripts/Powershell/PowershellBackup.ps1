Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$backupFolder = Join-Path -Path (Join-Path -Path $baseDirectory -ChildPath "Config") -ChildPath "Powershell"
Push-Location -LiteralPath $baseDirectory

try {
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        New-Item -LiteralPath $backupFolder -ItemType Directory | Out-Null
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

    if ($IsWindows) {
        $documentsPath = Join-Path -Path $HOME -ChildPath "Documents"
        [void]$candidateProfiles.Add([pscustomobject]@{
                Name = "WindowsPowerShellFallback"
                Path = Join-Path -Path (Join-Path -Path $documentsPath -ChildPath "WindowsPowerShell") -ChildPath "Microsoft.PowerShell_profile.ps1"
            })
    }

    $seenProfilePaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
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

    Write-Verbose (
        "PowerShell backup profile discovery diagnostics: candidateCount={0}; backupFolder='{1}'" -f
        $normalizedCandidates.Count,
        $backupFolder
    )

    foreach ($candidate in $normalizedCandidates) {
        if (Test-Path -LiteralPath $candidate.Path -PathType Leaf) {
            $destinationFileName = "{0}_{1}" -f $candidate.Name, [System.IO.Path]::GetFileName($candidate.Path)
            $backupFile = Join-Path -Path $backupFolder -ChildPath $destinationFileName
            Copy-Item -LiteralPath $candidate.Path -Destination $backupFile -Force
            $profilesBackedUp++
            Write-Host ("PowerShell profile '{0}' exported successfully from '{1}' to '{2}'." -f $candidate.Name, $candidate.Path, $backupFile) -ForegroundColor Green
            continue
        }

        Write-Warning ("W_POWERSHELL_BACKUP_PROFILE_MISSING({0}): PowerShell profile not found at '{1}'." -f $candidate.Name, $candidate.Path)
    }

    if ($profilesBackedUp -eq 0) {
        Write-Error "E_POWERSHELL_BACKUP_NO_PROFILES_FOUND: No PowerShell profile files were found to back up from discovered CurrentUser profile paths."
        exit 1
    }
}
finally {
    Pop-Location
}
