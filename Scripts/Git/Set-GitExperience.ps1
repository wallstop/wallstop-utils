<#
.SYNOPSIS
Audit, apply, or remove a reversible user-wide Git profile. See docs/git-experience.md.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Audit', 'Apply', 'Remove')][string]$Action = 'Audit',
    [switch]$WithDelta,
    [switch]$InstallDependencies,
    [switch]$ReplaceConflicts,
    [string]$StateDirectory,
    [string]$LazygitConfigPath,
    [switch]$NoInvokeMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GitExperience.IO.ps1')
. (Join-Path $PSScriptRoot 'GitExperience.Delta.ps1')

function Invoke-GitExperience {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Action, [switch]$WithDelta, [switch]$InstallDependencies,
        [switch]$ReplaceConflicts, [string]$StateDirectory, [string]$LazygitConfigPath
    )
    $gitCommand = Get-Command -Name 'git' -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) { throw 'E_GIT_EXPERIENCE_GIT_NOT_AVAILABLE: Install Git and add it to PATH.' }
    $gitPath = $gitCommand.Source
    $manifest = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'GitExperience.settings.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $version = Assert-GitExperienceVersion $gitPath $manifest.gitMinimum
    if (-not $StateDirectory) {
        $storage = if (Test-IsWindowsPlatform) { $env:LOCALAPPDATA } elseif ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $HOME '.local/state' }
        $StateDirectory = Join-Path $storage 'wallstop-utils/git-experience'
    }
    $StateDirectory = [System.IO.Path]::GetFullPath($StateDirectory)
    $profilePath = Join-Path $StateDirectory 'profile.gitconfig'
    $statePath = Join-Path $StateDirectory 'installation.json'
    $profileOrigin = 'file:' + ($profilePath -replace '\\', '/')
    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    if ($null -ne $state -and $state.WithDelta) { $WithDelta = $true }
    if ($null -ne $state -and $state.OverridePreferences) { $ReplaceConflicts = $true }
    $globalPath = Resolve-GitExperienceGlobalPath -OverridePreferences:$ReplaceConflicts
    if ($null -ne $state -and -not (Test-GitExperienceSamePath $state.GlobalPath $globalPath)) {
        if ($Action -eq 'Remove' -and -not $env:GIT_CONFIG_GLOBAL) { $globalPath = $state.GlobalPath }
        else { throw 'E_GIT_EXPERIENCE_CONTEXT: Global configuration target changed. Remove the existing installation with its original environment before reapplying.' }
    }
    $settings = [ordered]@{}
    foreach ($property in $manifest.settings.PSObject.Properties) { $settings[$property.Name] = [string]$property.Value }
    if ($WithDelta) {
        foreach ($property in $manifest.deltaSettings.PSObject.Properties) { $settings[$property.Name] = [string]$property.Value }
    }
    $selected = [ordered]@{}
    $report = foreach ($key in $settings.Keys) {
        $globalValues = @(Get-GitExperienceValues $gitPath $key -Global)
        $existing = @($globalValues | Where-Object { -not (Test-GitExperienceSamePath ($_.Origin -replace '\\', '/') $profileOrigin) })
        $effective = @(Get-GitExperienceValues $gitPath $key)
        $status = 'Recommended'
        if ($existing.Count -gt 0 -and -not $ReplaceConflicts) { $status = 'Preserved' }
        else { $selected[$key] = $settings[$key] }
        if ($effective.Count -gt 0 -and $effective[-1].Value -eq $settings[$key]) { $status = 'Active' }
        [pscustomobject]@{
            Key = $key; Recommended = $settings[$key]; Status = $status
            Effective = if ($effective.Count) { $effective[-1].Value } else { '(Git default)' }
            Origin = if ($effective.Count) { $effective[-1].Origin } else { '' }
        }
    }
    Write-Verbose $version
    if ($Action -eq 'Audit') {
        $report
        if ($WithDelta) { Get-GitExperienceDeltaAudit -StateDirectory $StateDirectory -LazygitConfigPath $LazygitConfigPath }
        return
    }
    if ($Action -eq 'Remove' -and $null -eq $state) { Write-Host 'Git experience is not installed.'; return }
    if (-not $PSCmdlet.ShouldProcess($globalPath, "$Action Git experience configuration")) { return }
    if ($null -ne $state -and (Get-GitExperienceFile $profilePath) -cne $state.ProfileBytes) {
        throw "E_GIT_EXPERIENCE_DRIFT: Managed profile was edited; preserve it elsewhere before $Action."
    }
    if ($null -eq $state -and (Test-Path -LiteralPath $profilePath)) {
        throw 'E_GIT_EXPERIENCE_UNOWNED: Existing profile has no installation record.'
    }
    $globalBefore = Get-GitExperienceFile $globalPath
    [void][System.IO.Directory]::CreateDirectory($StateDirectory)
    Set-GitExperiencePrivatePath $StateDirectory -Directory
    $lock = $null
    $globalLock = $null
    $scratch = Join-Path $StateDirectory ('candidate-' + [guid]::NewGuid().ToString('N'))
    $changes = New-Object System.Collections.Generic.List[object]
    $published = New-Object System.Collections.Generic.List[object]
    try {
        try { $lock = [System.IO.File]::Open((Join-Path $StateDirectory 'installation.lock'), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) }
        catch { throw 'E_GIT_EXPERIENCE_LOCK: Another installation may be running. Inspect installation.lock before retrying.' }
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $globalPath))
        try { $globalLock = [System.IO.File]::Open(($globalPath + '.lock'), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) }
        catch { throw 'E_GIT_EXPERIENCE_LOCK: Global Git configuration is locked. Retry when the other writer completes.' }
        if ((Get-GitExperienceFile $globalPath) -cne $globalBefore) { throw 'E_GIT_EXPERIENCE_CONCURRENT: Global config changed during preparation.' }
        $initialGlobal = if ($null -eq $globalBefore) { '' } else { $globalBefore }
        Write-GitExperienceFile $scratch $initialGlobal
        $include = $profilePath -replace '\\', '/'
        Invoke-GitExperienceProcess $gitPath @('config', '--file', $scratch, '--fixed-value', '--unset-all', 'include.path', $include) -AllowedExitCodes @(0, 5) | Out-Null
        $originalGlobal = if ($null -eq $state) { $globalBefore } elseif ($globalBefore -ceq $state.InstalledGlobal) { $state.OriginalGlobal } else { Get-GitExperienceFile $scratch }
        $deltaState = if ($null -ne $state) { $state.Delta } else { $null }
        if ($Action -eq 'Apply') {
            if ($WithDelta) {
                $deltaChange = Get-GitExperienceDeltaChange -StateDirectory $StateDirectory -ConfigPath $LazygitConfigPath -Previous $deltaState -InstallDependencies:$InstallDependencies -ReplaceConflicts:$ReplaceConflicts
                if ($null -ne $deltaChange) { $changes.Add($deltaChange.Change); $deltaState = $deltaChange.State }
            }
            $profileText = "# Managed by wallstop-utils. Personal overrides belong in your own Git config.`n"
            foreach ($key in $settings.Keys) {
                $section, $name = $key.Split('.', 2)
                $profileText += "[$section]`n`t$name = $($settings[$key])`n"
            }
            $profileBytes = ConvertTo-GitExperienceBytes $profileText
            $changes.Add([pscustomobject]@{ Path = $profilePath; Before = Get-GitExperienceFile $profilePath; After = $profileBytes })
            # git config --add can reuse an earlier section; text position controls precedence.
            $escapedInclude = $include.Replace('"', '\"').Replace("`n", '\n').Replace("`t", '\t')
            $existingBytes = [System.IO.File]::ReadAllBytes($scratch)
            $includeText = '[include]' + "`n`tpath = " + '"' + $escapedInclude + '"' + "`n"
            $includeBytes = [System.Text.Encoding]::UTF8.GetBytes($includeText)
            $combinedBytes = New-Object System.Collections.Generic.List[byte]
            if ($ReplaceConflicts) {
                $combinedBytes.AddRange($existingBytes)
                if ($existingBytes.Length -gt 0 -and $existingBytes[-1] -ne 10) { $combinedBytes.Add(10) }
                $combinedBytes.AddRange($includeBytes)
            }
            else {
                $combinedBytes.AddRange($existingBytes)
                # Git accepts a UTF-8 BOM only at byte zero.
                $insertAt = if ($existingBytes.Length -ge 3 -and $existingBytes[0] -eq 0xef -and $existingBytes[1] -eq 0xbb -and $existingBytes[2] -eq 0xbf) { 3 } else { 0 }
                $combinedBytes.InsertRange($insertAt, $includeBytes)
            }
            Write-GitExperienceFile $scratch ([Convert]::ToBase64String($combinedBytes.ToArray()))
            $newState = [ordered]@{ Version = 1; GlobalPath = $globalPath; WithDelta = [bool]$WithDelta; OverridePreferences = [bool]$ReplaceConflicts; ProfileBytes = $profileBytes; Delta = $deltaState; OriginalGlobal = $originalGlobal; InstalledGlobal = Get-GitExperienceFile $scratch }
            $stateAfter = ConvertTo-GitExperienceBytes (($newState | ConvertTo-Json -Depth 12) + "`n")
        }
        else {
            if ($null -ne $deltaState) { $changes.Add((Get-GitExperienceDeltaRemoval $deltaState)) }
            $changes.Add([pscustomobject]@{ Path = $profilePath; Before = Get-GitExperienceFile $profilePath; After = $null })
            $stateAfter = $null
        }
        $globalAfter = Get-GitExperienceFile $scratch
        if ($Action -eq 'Remove' -and $globalBefore -ceq $state.InstalledGlobal) { $globalAfter = $state.OriginalGlobal }
        $changes.Add([pscustomobject]@{ Path = $globalPath; Before = $globalBefore; After = $globalAfter })
        $changes.Add([pscustomobject]@{ Path = $statePath; Before = Get-GitExperienceFile $statePath; After = $stateAfter })
        # Persist originals before publishing. This journal remains available for manual recovery.
        $journal = Join-Path $StateDirectory ('backup-' + [guid]::NewGuid().ToString('N') + '.json')
        $actualChanges = @($changes.ToArray() | Where-Object { $_.Before -cne $_.After })
        if ($actualChanges.Count -gt 0) {
            Write-GitExperienceFile $journal (ConvertTo-GitExperienceBytes (ConvertTo-Json -InputObject $actualChanges -Depth 12))
        }
        foreach ($change in $actualChanges) {
            if ((Get-GitExperienceFile $change.Path) -cne $change.Before) { throw "E_GIT_EXPERIENCE_CONCURRENT: '$($change.Path)' changed during preparation." }
            Write-GitExperienceFile $change.Path $change.After
            $published.Add($change)
        }
        if ($Action -eq 'Apply') {
            foreach ($key in $selected.Keys) {
                $values = @(Get-GitExperienceValues $gitPath $key -Global)
                if ($values.Count -eq 0 -or $values[-1].Value -ne $selected[$key]) { throw "E_GIT_EXPERIENCE_VERIFY: '$key' did not activate globally." }
            }
        }
        Write-Host "Git experience: $Action completed. Recovery records: $StateDirectory"
    }
    catch {
        $originalError = $_
        for ($index = $published.Count - 1; $index -ge 0; $index--) {
            $change = $published[$index]
            if ((Get-GitExperienceFile $change.Path) -ceq $change.After) { Write-GitExperienceFile $change.Path $change.Before }
            else { Write-Warning "W_GIT_EXPERIENCE_ROLLBACK_CONFLICT: Preserve concurrent edits in '$($change.Path)'; consult recovery records." }
        }
        throw $originalError
    }
    finally {
        if ($null -ne $globalLock) { $globalLock.Dispose(); Remove-Item -LiteralPath ($globalPath + '.lock') -Force }
        if ($null -ne $lock) { $lock.Dispose(); Remove-Item -LiteralPath (Join-Path $StateDirectory 'installation.lock') -Force }
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Force }
    }
    if ($Action -eq 'Apply') {
        Invoke-GitExperience -Action Audit -StateDirectory $StateDirectory -WithDelta:$WithDelta -LazygitConfigPath $LazygitConfigPath
    }
}

if (-not $NoInvokeMain) {
    Invoke-GitExperience -Action $Action -StateDirectory $StateDirectory -WithDelta:$WithDelta -InstallDependencies:$InstallDependencies -ReplaceConflicts:$ReplaceConflicts -LazygitConfigPath $LazygitConfigPath -WhatIf:$WhatIfPreference
}
