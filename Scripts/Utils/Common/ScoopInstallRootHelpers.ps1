Set-StrictMode -Version Latest

# Shared resolution of scoop install roots for Scripts/Scoop/* tooling. Both per-user installs
# ($env:SCOOP, default ~\scoop) and admin/global installs ($env:SCOOP_GLOBAL, default
# ProgramData\scoop) are honored so Mozilla policy deployment (issue #68/#70) and host health
# checks cannot silently miss global apps. Callers must have dot-sourced
# Scripts/Utils/Common/CompatibilityHelpers.ps1 (Test-IsWindowsPlatform).

function Get-ScoopInstallCandidateRoots {
    # Returns the existing, canonicalized, de-duplicated scoop install roots. Missing candidates are
    # skipped with Write-Verbose diagnostics; an empty result means no local scoop installation was
    # found in any standard location.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $candidateRoots = New-Object System.Collections.Generic.List[string]

    $userRoot = $env:SCOOP
    if ([string]::IsNullOrWhiteSpace($userRoot)) {
        $userRoot = Join-Path -Path $HOME -ChildPath "scoop"
    }
    [void]$candidateRoots.Add($userRoot)

    if (Test-IsWindowsPlatform) {
        $globalRoot = $env:SCOOP_GLOBAL
        if ([string]::IsNullOrWhiteSpace($globalRoot)) {
            $programDataRoot = $env:ProgramData
            if (-not [string]::IsNullOrWhiteSpace($programDataRoot)) {
                [void]$candidateRoots.Add((Join-Path -Path $programDataRoot -ChildPath "scoop"))
            }
        }
        else {
            [void]$candidateRoots.Add($globalRoot)
        }
    }

    $resolvedRoots = New-Object System.Collections.Generic.List[string]
    foreach ($candidateRoot in $candidateRoots) {
        if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
            Write-Verbose ("Scoop install root diagnostics: skipping missing root '{0}'" -f $candidateRoot)
            continue
        }

        $resolvedRoot = (Resolve-Path -LiteralPath $candidateRoot -ErrorAction Stop).Path
        $isDuplicate = $false
        foreach ($existingRoot in $resolvedRoots) {
            if ([string]::Equals($existingRoot, $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isDuplicate = $true
                break
            }
        }

        if (-not $isDuplicate) {
            [void]$resolvedRoots.Add($resolvedRoot)
        }
    }

    return $resolvedRoots.ToArray() # array-unwrap-safe: callers always wrap with @()
}
