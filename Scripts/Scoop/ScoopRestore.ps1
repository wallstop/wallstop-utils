Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/CompatibilityHelpers.ps1")

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
function Install-MozillaUpdateBlockingPolicies {
    $scoopRoot = if (-not [string]::IsNullOrWhiteSpace($env:SCOOP)) {
        $env:SCOOP
    }
    elseif (Test-IsWindowsPlatform) {
        Join-Path -Path $HOME -ChildPath "scoop"
    }
    else {
        return
    }

    $appsRoot = Join-Path -Path $scoopRoot -ChildPath "apps"
    if (-not (Test-Path -LiteralPath $appsRoot -PathType Container)) {
        Write-Warning ("W_SCOOP_RESTORE_MOZILLA_POLICY_SKIPPED: Scoop apps root not found at '{0}'." -f $appsRoot)
        return
    }

    $mozillaAppDirectories = @(Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(thunderbird|firefox)' -and $_.Name -ne 'scoop' })
    if ($mozillaAppDirectories.Count -eq 0) {
        return
    }

    $policyPayload = '{"policies":{"DisableAppUpdate":true,"DisableTelemetry":true}}'
    foreach ($appDirectory in $mozillaAppDirectories) {
        $distributionDirectory = Join-Path -Path $scoopRoot -ChildPath (
            "persist/{0}/distribution" -f $appDirectory.Name
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

            if ($existingPayload -ne $policyPayload) {
                [System.IO.File]::WriteAllText($policyPath, $policyPayload + "`n", [System.Text.UTF8Encoding]::new($false))
                Write-Host ("Deployed Mozilla update-blocking policy: {0}" -f $policyPath) -ForegroundColor Green
            }
            else {
                Write-Verbose ("Mozilla update-blocking policy already current: {0}" -f $policyPath)
            }
        }
        catch {
            Write-Warning (
                "W_SCOOP_RESTORE_MOZILLA_POLICY_FAILED: Failed to deploy '{0}'. Detail: {1}" -f
                $policyPath,
                [string]$_.Exception.Message
            )
        }
    }
}

Install-MozillaUpdateBlockingPolicies
