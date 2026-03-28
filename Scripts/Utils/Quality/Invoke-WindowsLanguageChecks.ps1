[CmdletBinding()]
param(
    [string]$TargetFiles = "",
    [switch]$RequireAutoHotkey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AutoHotkeyExecutablePath {
    $commandCandidates = @("AutoHotkey64.exe", "AutoHotkey.exe", "autohotkey")
    foreach ($candidate in $commandCandidates) {
        $command = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            return $command.Source
        }
    }

    $pathCandidates = @(
        "$env:ProgramFiles/AutoHotkey/v2/AutoHotkey64.exe",
        "$env:ProgramFiles/AutoHotkey/AutoHotkey64.exe",
        "$env:ProgramFiles/AutoHotkey/AutoHotkey.exe",
        "$env:ProgramFiles(x86)/AutoHotkey/AutoHotkey.exe"
    )
    foreach ($candidate in $pathCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -Path $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Resolve-RequestedTargetFilePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string]$TargetFiles
    )

    if ([string]::IsNullOrWhiteSpace($TargetFiles)) {
        return @()
    }

    $requested = New-Object System.Collections.Generic.List[string]
    $candidates = @($TargetFiles -split "(`r`n|`n|`r|;)")
    foreach ($candidateRaw in $candidates) {
        $candidate = $candidateRaw.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $resolvedPath = $null
        if ([System.IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -Path $candidate -PathType Leaf) {
                $resolvedPath = (Resolve-Path -Path $candidate -ErrorAction Stop).Path
            }
        } else {
            $relativePath = $candidate.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\\', [System.IO.Path]::DirectorySeparatorChar)
            $absoluteCandidate = Join-Path -Path $RepoRoot -ChildPath $relativePath
            if (Test-Path -Path $absoluteCandidate -PathType Leaf) {
                $resolvedPath = (Resolve-Path -Path $absoluteCandidate -ErrorAction Stop).Path
            }
        }

        if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
            continue
        }

        $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
        if ($extension -ne ".ahk" -and $extension -ne ".bat") {
            continue
        }

        $requested.Add($resolvedPath) | Out-Null
    }

    if ($requested.Count -eq 0) {
        return @()
    }

    return @($requested | Sort-Object -Unique)
}

function Test-AutoHotkeyScripts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RequestedTargetFilePaths = @(),

        [Parameter(Mandatory = $false)]
        [switch]$RequireAutoHotkey
    )

    $ahkFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if ($RequestedTargetFilePaths.Count -gt 0) {
        foreach ($targetPath in $RequestedTargetFilePaths) {
            if ([System.IO.Path]::GetExtension($targetPath).ToLowerInvariant() -ne ".ahk") {
                continue
            }

            if (Test-Path -Path $targetPath -PathType Leaf) {
                $ahkFiles.Add((Get-Item -LiteralPath $targetPath -ErrorAction Stop)) | Out-Null
            }
        }
    } else {
        $searchRoots = @(
            (Join-Path -Path $RepoRoot -ChildPath "Scripts/AutoHotKey"),
            (Join-Path -Path $RepoRoot -ChildPath "Config/.config")
        )

        foreach ($root in $searchRoots) {
            if (Test-Path -Path $root -PathType Container) {
                Get-ChildItem -Path $root -Filter "*.ahk" -File -Recurse -ErrorAction Stop | ForEach-Object {
                    $ahkFiles.Add($_) | Out-Null
                }
            }
        }
    }

    if ($ahkFiles.Count -eq 0) {
        Write-Host "AutoHotkey checks: no .ahk files found for selected scope; skipping."
        return
    }

    $ahkExecutable = Get-AutoHotkeyExecutablePath
    if ([string]::IsNullOrWhiteSpace($ahkExecutable)) {
        if ($RequireAutoHotkey) {
            throw "E_AHK_UNAVAILABLE: AutoHotkey executable not found while AutoHotkey validation is required."
        }

        Write-Warning "W_AHK_UNAVAILABLE: AutoHotkey executable not found. Skipping AutoHotkey validation."
        return
    }

    $helpOutput = @(& $ahkExecutable "/?" 2>&1)
    $supportsValidate = (($helpOutput -join "`n") -match "(?im)(^|\\s)/validate(\\s|$)")
    if (-not $supportsValidate) {
        if ($RequireAutoHotkey) {
            throw "E_AHK_VALIDATE_UNAVAILABLE: '$ahkExecutable' does not advertise /validate while AutoHotkey validation is required."
        }

        Write-Warning "W_AHK_VALIDATE_UNAVAILABLE: '$ahkExecutable' does not advertise /validate. Skipping AutoHotkey compile validation."
        return
    }

    Write-Host "AutoHotkey checks: validating $($ahkFiles.Count) file(s) with /validate..."
    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($file in $ahkFiles) {
        $output = @(& $ahkExecutable "/ErrorStdOut" "/validate" $file.FullName 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName)
            $details = if ($output.Count -gt 0) { $output -join " " } else { "(no output)" }
            $failures.Add("$relative :: $details") | Out-Null
        }
    }

    if ($failures.Count -gt 0) {
        throw "E_AHK_VALIDATION_FAILED: AutoHotkey validation failed for: $($failures -join '; ')"
    }
}

function Test-BatchScriptsStaticSmoke {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RequestedTargetFilePaths = @()
    )

    $batchFiles = @()
    if ($RequestedTargetFilePaths.Count -gt 0) {
        $batchFiles = @(
            $RequestedTargetFilePaths |
                Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -eq ".bat" } |
                ForEach-Object {
                    if (Test-Path -Path $_ -PathType Leaf) {
                        Get-Item -LiteralPath $_ -ErrorAction Stop
                    }
                }
        )
    } else {
        $batchFiles = @(Get-ChildItem -Path (Join-Path -Path $RepoRoot -ChildPath "Scripts") -Filter "*.bat" -File -Recurse -ErrorAction Stop)
    }

    if ($batchFiles.Count -eq 0) {
        Write-Host "Batch checks: no .bat files found for selected scope; skipping."
        return
    }

    Write-Host "Batch checks: running best-effort static smoke checks for $($batchFiles.Count) file(s)."
    Write-Host "Batch checks limitation: this is heuristic validation and does not fully parse cmd.exe syntax."

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($file in $batchFiles) {
        $lines = Get-Content -Path $file.FullName
        $parenBalance = 0

        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]
            $lineNumber = $index + 1
            $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName)

            if ($line -match "\s+$") {
                $violations.Add("${relative}:$lineNumber trailing whitespace") | Out-Null
            }
            if ($line -match "^\t+") {
                $violations.Add("${relative}:$lineNumber leading tabs") | Out-Null
            }
            if ($line -match "^(<<<<<<<|=======|>>>>>>>)") {
                $violations.Add("${relative}:$lineNumber unresolved merge marker") | Out-Null
            }

            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }
            if ($trimmed -match "^(?i)(::|REM\b)") {
                continue
            }

            $openCount = [regex]::Matches($line, "(?<!\^)\(").Count
            $closeCount = [regex]::Matches($line, "(?<!\^)\)").Count
            $parenBalance += ($openCount - $closeCount)

            if ($parenBalance -lt 0) {
                $violations.Add("${relative}:$lineNumber parenthesis balance became negative") | Out-Null
                $parenBalance = 0
            }
        }

        if ($parenBalance -ne 0) {
            $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName)
            $violations.Add("$relative unbalanced parentheses at end-of-file") | Out-Null
        }
    }

    if ($violations.Count -gt 0) {
        throw "E_BATCH_SMOKE_FAILED: Batch static smoke checks failed. Violations: $($violations -join '; ')"
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../../..")).Path
$requestedTargetFilePaths = Resolve-RequestedTargetFilePaths -RepoRoot $repoRoot -TargetFiles $TargetFiles

if ($requestedTargetFilePaths.Count -gt 0) {
    Write-Host "Windows language checks: running in targeted mode for $($requestedTargetFilePaths.Count) file(s)."
}

Test-AutoHotkeyScripts -RepoRoot $repoRoot -RequestedTargetFilePaths $requestedTargetFilePaths -RequireAutoHotkey:$RequireAutoHotkey
Test-BatchScriptsStaticSmoke -RepoRoot $repoRoot -RequestedTargetFilePaths $requestedTargetFilePaths

Write-Host "Windows language checks passed."
