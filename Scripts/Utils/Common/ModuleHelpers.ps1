$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath 'CompatibilityHelpers.ps1'
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $compatibilityHelpersPath

function Add-ModulePathCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Verbose "Module path candidate skipped: empty-or-whitespace path."
        return
    }

    if (-not (Test-Path -Path $Path -PathType Container)) {
        Write-Verbose ("Module path candidate skipped: directory does not exist; path='{0}'." -f $Path)
        return
    }

    $separator = [System.IO.Path]::PathSeparator
    $currentEntries = @($env:PSModulePath -split [regex]::Escape([string]$separator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($currentEntries -contains $Path) {
        Write-Verbose ("Module path candidate skipped: already present; path='{0}'." -f $Path)
        return
    }

    $env:PSModulePath = if ([string]::IsNullOrWhiteSpace($env:PSModulePath)) {
        $Path
    }
    else {
        "$Path$separator$env:PSModulePath"
    }

    Write-Verbose ("Module path candidate added: path='{0}'." -f $Path)
}

function Ensure-PortableUserModulePaths {
    $myDocuments = [Environment]::GetFolderPath("MyDocuments")

    if (-not [string]::IsNullOrWhiteSpace($myDocuments)) {
        # Hooks run with -NoProfile, so add user-scope module paths explicitly.
        Add-ModulePathCandidate -Path (Join-Path -Path $myDocuments -ChildPath "PowerShell/Modules")
        Add-ModulePathCandidate -Path (Join-Path -Path $myDocuments -ChildPath "WindowsPowerShell/Modules")
    }
    else {
        Write-Verbose "Module path discovery: MyDocuments path unavailable."
    }

    $userHome = [Environment]::GetFolderPath("UserProfile")
    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
        Add-ModulePathCandidate -Path (Join-Path -Path $userHome -ChildPath ".local/share/powershell/Modules")

        $snapCodeRoot = Join-Path -Path $userHome -ChildPath "snap/code"
        if (Test-Path -Path $snapCodeRoot -PathType Container) {
            $snapCodeProfiles = Get-ChildItem -Path $snapCodeRoot -Directory -ErrorAction SilentlyContinue
            foreach ($snapProfile in @($snapCodeProfiles)) {
                Add-ModulePathCandidate -Path (Join-Path -Path $snapProfile.FullName -ChildPath ".local/share/powershell/Modules")
            }
        }
    }
    else {
        Write-Verbose "Module path discovery: UserProfile path unavailable."
    }

    if (-not (Test-IsWindowsPlatform)) {
        Add-ModulePathCandidate -Path "/usr/local/share/powershell/Modules"
    }

    $separator = [System.IO.Path]::PathSeparator
    $entryCount = @($env:PSModulePath -split [regex]::Escape([string]$separator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    Write-Verbose (
        "Module path diagnostics: entryCount={0}; hasMyDocuments={1}; hasUserProfile={2}; isWindows={3}; isMacOS={4}; isLinux={5}" -f
        $entryCount,
        -not [string]::IsNullOrWhiteSpace($myDocuments),
        -not [string]::IsNullOrWhiteSpace($userHome),
        (Test-IsWindowsPlatform),
        (Test-IsMacOSPlatform),
        (Test-IsLinuxPlatform)
    )
}

function Get-AvailableModuleVersionsText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1,20)]
        [int]$MaxCount = 3
    )

    Ensure-PortableUserModulePaths
    $availableModules = @(
        Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            Select-Object -ExpandProperty Version -Unique
    )

    if ($availableModules.Count -eq 0) {
        Write-Verbose ("Module version diagnostics: module={0}; discoveredVersions=(none)." -f $ModuleName)
        return "(none)"
    }

    $preview = @($availableModules | Select-Object -First $MaxCount | ForEach-Object { $_.ToString() })
    Write-Verbose (
        "Module version diagnostics: module={0}; discoveredVersions={1}; totalCount={2}; previewCount={3}" -f
        $ModuleName,
        ($preview -join ', '),
        $availableModules.Count,
        $preview.Count
    )

    if ($availableModules.Count -gt $MaxCount) {
        return ("{0} (showing first {1} of {2})" -f ($preview -join ', '),$preview.Count,$availableModules.Count)
    }

    return ($preview -join ', ')
}

function Get-AvailableModuleVersionScopeText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1,20)]
        [int]$MaxCount = 6
    )

    Ensure-PortableUserModulePaths

    $availableModules = @(
        Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending
    )

    if ($availableModules.Count -eq 0) {
        Write-Verbose ("Module version scope diagnostics: module={0}; discoveredScopes=(none)." -f $ModuleName)
        return "(none)"
    }

    $scopeEntries = New-Object 'System.Collections.Generic.List[string]'
    $scopeEntrySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($moduleInfo in $availableModules) {
        $moduleBase = [string]$moduleInfo.ModuleBase
        $scopeLabel = if ($moduleBase -match '(?i)[\\/]WindowsPowerShell[\\/]Modules([\\/]|$)') {
            "windows-powershell"
        }
        elseif ($moduleBase -match '(?i)[\\/]PowerShell[\\/]Modules([\\/]|$)' -or $moduleBase -match '(?i)[\\/]\.local[\\/]share[\\/]powershell[\\/]Modules([\\/]|$)') {
            "pwsh"
        }
        elseif ($moduleBase -match '(?i)[\\/]scoop[\\/]modules([\\/]|$)') {
            "scoop"
        }
        else {
            "other"
        }

        $scopeEntry = ("{0}@{1}" -f $moduleInfo.version,$scopeLabel)
        if ($scopeEntrySet.Add($scopeEntry)) {
            $scopeEntries.Add($scopeEntry) | Out-Null
        }
    }

    $preview = @($scopeEntries | Select-Object -First $MaxCount)
    Write-Verbose (
        "Module version scope diagnostics: module={0}; discoveredScopes={1}; totalCount={2}; previewCount={3}" -f
        $ModuleName,
        ($preview -join ', '),
        $scopeEntries.Count,
        $preview.Count
    )

    if ($scopeEntries.Count -gt $MaxCount) {
        return ("{0} (showing first {1} of {2})" -f ($preview -join ', '),$preview.Count,$scopeEntries.Count)
    }

    return ($preview -join ', ')
}

function Get-ModulePathDiagnosticsText {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateRange(1,20)]
        [int]$MaxPreviewEntries = 8
    )

    Ensure-PortableUserModulePaths

    $separator = [System.IO.Path]::PathSeparator
    $entries = @($env:PSModulePath -split [regex]::Escape([string]$separator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries.Count -eq 0) {
        return "entryCount=0; existingEntryCount=0; entries=(none)"
    }

    $entryPreview = New-Object 'System.Collections.Generic.List[string]'
    $existingEntryCount = 0

    foreach ($entry in @($entries)) {
        $entryExists = Test-Path -Path $entry -PathType Container
        if ($entryExists) {
            $existingEntryCount++
        }

        if ($entryPreview.Count -lt $MaxPreviewEntries) {
            $status = if ($entryExists) { "exists" } else { "missing" }
            $entryPreview.Add(("[{0}] {1}" -f $status,$entry)) | Out-Null
        }
    }

    $entriesText = $entryPreview -join ' | '
    if ($entries.Count -gt $MaxPreviewEntries) {
        $remaining = $entries.Count - $MaxPreviewEntries
        $entriesText = "{0} | ... ({1} more entries)" -f $entriesText,$remaining
    }

    return (
        "entryCount={0}; existingEntryCount={1}; entries={2}" -f
        $entries.Count,
        $existingEntryCount,
        $entriesText
    )
}

function Get-CommandWithOptionalModuleImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $true)]
        [version]$MinimumVersion
    )

    Ensure-PortableUserModulePaths

    try {
        Import-Module -Name $ModuleName -MinimumVersion $MinimumVersion -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Verbose (
            "Module import diagnostics: module={0}; minimumVersion={1}; importFailure={2}" -f
            $ModuleName,
            $MinimumVersion,
            $_.Exception.Message
        )
        return $null
    }

    $loadedModule = @(Get-Module -Name $ModuleName | Sort-Object -Property Version -Descending | Select-Object -First 1)
    if ($loadedModule.Count -eq 0) {
        Write-Verbose ("Module import diagnostics: module={0}; loadedModuleCount=0 after import." -f $ModuleName)
        return $null
    }

    $loadedVersion = $loadedModule[0].version
    if ($loadedVersion -isnot [version] -or $loadedVersion -lt $MinimumVersion) {
        Write-Verbose (
            "Module import diagnostics: module={0}; loadedVersion={1}; minimumVersion={2}; compatible={3}" -f
            $ModuleName,
            $loadedVersion,
            $MinimumVersion,
            $false
        )
        return $null
    }

    Write-Verbose (
        "Module import diagnostics: module={0}; loadedVersion={1}; minimumVersion={2}; compatible={3}" -f
        $ModuleName,
        $loadedVersion,
        $MinimumVersion,
        $true
    )

    $moduleCommand = @(Get-Command -Name $CommandName -Module $ModuleName -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($moduleCommand.Count -gt 0) {
        Write-Verbose (
            "Module import diagnostics: module={0}; command={1}; commandResolved={2}" -f
            $ModuleName,
            $CommandName,
            $true
        )
        return $moduleCommand[0]
    }

    Write-Verbose (
        "Module import diagnostics: module={0}; command={1}; commandResolved={2}" -f
        $ModuleName,
        $CommandName,
        $false
    )

    return $null
}

function Assert-ModuleCommandRequirements {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Requirements,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ErrorCode,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ContextLabel = "PowerShell module prerequisites"
    )

    $normalizedRequirements = @($Requirements)
    if ($normalizedRequirements.Count -eq 0) {
        Write-Verbose ("Module requirement diagnostics: context='{0}'; requirementCount=0; status=skipped" -f $ContextLabel)
        return
    }

    $missingDiagnostics = New-Object System.Collections.Generic.List[string]

    foreach ($requirement in $normalizedRequirements) {
        $moduleName = [string]$requirement.ModuleName
        $minimumVersion = [version]$requirement.MinimumVersion
        $commandNames = @($requirement.CommandNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $installCommand = [string]$requirement.InstallCommand
        $additionalNotes = @($requirement.AdditionalNotes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

        if ([string]::IsNullOrWhiteSpace($moduleName) -or $commandNames.Count -eq 0) {
            throw "E_CONFIG_ERROR: invalid module requirement definition for context '$ContextLabel'."
        }

        if ([string]::IsNullOrWhiteSpace($installCommand)) {
            $installCommand = "Install-Module $moduleName -Scope CurrentUser -MinimumVersion $minimumVersion -Force"
        }

        $primaryCommand = [string]$commandNames[0]
        $resolvedPrimary = Get-CommandWithOptionalModuleImport -CommandName $primaryCommand -ModuleName $moduleName -MinimumVersion $minimumVersion

        if ($null -eq $resolvedPrimary) {
            $installedVersions = Get-AvailableModuleVersionsText -ModuleName $moduleName
            $installedVersionScopes = Get-AvailableModuleVersionScopeText -ModuleName $moduleName
            $modulePathDiagnostics = Get-ModulePathDiagnosticsText
            $diagnosticNotes = New-Object System.Collections.Generic.List[string]
            foreach ($note in $additionalNotes) {
                $diagnosticNotes.Add([string]$note) | Out-Null
            }
            $diagnosticNotes.Add(("versionScopes={0}" -f $installedVersionScopes)) | Out-Null
            $notesText = if ($diagnosticNotes.Count -gt 0) { "; notes={0}" -f ($diagnosticNotes -join ' | ') } else { "" }

            $missingDiagnostics.Add(
                "- module={0}; commands={1}; minimumVersion={2}; installedVersions={3}; modulePathDiagnostics={4}; installCommand='{5}'{6}" -f @(
                    $moduleName
                    ($commandNames -join ', ')
                    $minimumVersion
                    $installedVersions
                    $modulePathDiagnostics
                    $installCommand
                    $notesText
                )
            ) | Out-Null
            continue
        }

        foreach ($commandName in $commandNames) {
            $moduleCommand = @(Get-Command -Name $commandName -Module $moduleName -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($moduleCommand.Count -gt 0) {
                continue
            }

            $missingDiagnostics.Add(
                "- module={0}; command={1}; minimumVersion={2}; issue=command-not-exported; installCommand='{3}'" -f @(
                    $moduleName
                    $commandName
                    $minimumVersion
                    $installCommand
                )
            ) | Out-Null
        }
    }

    if ($missingDiagnostics.Count -eq 0) {
        Write-Verbose ("Module requirement diagnostics: context='{0}'; requirementCount={1}; status=ok" -f $ContextLabel,$normalizedRequirements.Count)
        return
    }

    throw (
        "{0}: {1} are unavailable for -NoProfile validation contexts.`n{2}`nInstall the required module(s), then rerun in the same shell session." -f
        $ErrorCode,
        $ContextLabel,
        ($missingDiagnostics -join [Environment]::NewLine)
    )
}
