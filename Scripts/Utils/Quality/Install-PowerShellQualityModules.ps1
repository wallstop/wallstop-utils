[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Pester","PSScriptAnalyzer")]
    [string[]]$Modules = @("Pester","PSScriptAnalyzer"),

    [Parameter(Mandatory = $false)]
    [switch]$SkipPSGalleryTrust
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$moduleHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/ModuleHelpers.ps1"
if (-not (Test-Path -Path $moduleHelpersPath -PathType Leaf)) {
    throw "E_MODULE_BOOTSTRAP_HELPER_MISSING: module helper file not found at '$moduleHelpersPath'."
}

.$moduleHelpersPath

$moduleRequirementsByName = @{
    Pester = [pscustomobject]@{
        ModuleName = "Pester"
        MinimumVersion = [version]"5.5.0"
        CommandName = "Invoke-Pester"
    }
    PSScriptAnalyzer = [pscustomobject]@{
        ModuleName = "PSScriptAnalyzer"
        MinimumVersion = [version]"1.21.0"
        CommandName = "Invoke-ScriptAnalyzer"
    }
}

$selectedModules = @(
    $Modules |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

if ($selectedModules.Count -eq 0) {
    Write-Host "No modules requested; skipping bootstrap."
    return
}

if (-not $SkipPSGalleryTrust) {
    $setRepositoryCommand = Get-Command -Name "Set-PSRepository" -ErrorAction SilentlyContinue
    if ($null -ne $setRepositoryCommand) {
        try {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction Stop
            Write-Verbose "PowerShell module bootstrap diagnostics: PSGallery installation policy set to Trusted."
        }
        catch {
            Write-Warning "W_MODULE_BOOTSTRAP_TRUST_UPDATE_FAILED: unable to set PSGallery InstallationPolicy to Trusted. Continuing with explicit -Force installs."
            Write-Verbose ("PowerShell module bootstrap trust diagnostics: {0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Verbose "PowerShell module bootstrap diagnostics: Set-PSRepository command unavailable; continuing with explicit -Force installs."
    }
}

foreach ($moduleName in $selectedModules) {
    if (-not $moduleRequirementsByName.ContainsKey($moduleName)) {
        throw "E_MODULE_BOOTSTRAP_INVALID_SELECTION: unsupported module '$moduleName'."
    }

    $requirement = $moduleRequirementsByName[$moduleName]
    $resolvedCommand = Get-CommandWithOptionalModuleImport -CommandName $requirement.CommandName -ModuleName $requirement.ModuleName -MinimumVersion $requirement.MinimumVersion

    if ($null -ne $resolvedCommand) {
        Write-Host ("PowerShell module already satisfies requirement: {0} >= {1}" -f $requirement.ModuleName,$requirement.MinimumVersion)
        continue
    }

    Write-Host ("Installing PowerShell module requirement: {0} >= {1}" -f $requirement.ModuleName,$requirement.MinimumVersion)

    try {
        Install-Module -Name $requirement.ModuleName -Repository "PSGallery" -Scope CurrentUser -MinimumVersion $requirement.MinimumVersion -Force -ErrorAction Stop
    }
    catch {
        $installedVersions = Get-AvailableModuleVersionsText -ModuleName $requirement.ModuleName
        $modulePathDiagnostics = Get-ModulePathDiagnosticsText
        throw (
            "E_MODULE_BOOTSTRAP_INSTALL_FAILED: failed to install module '{0}' (minimumVersion={1}). Installed versions: {2}. Module path diagnostics: {3}. Manual remediation: Install-Module {0} -Repository PSGallery -Scope CurrentUser -MinimumVersion {1} -Force" -f
            $requirement.ModuleName,
            $requirement.MinimumVersion,
            $installedVersions,
            $modulePathDiagnostics
        )
    }

    $verifiedCommand = Get-CommandWithOptionalModuleImport -CommandName $requirement.CommandName -ModuleName $requirement.ModuleName -MinimumVersion $requirement.MinimumVersion
    if ($null -eq $verifiedCommand) {
        $installedVersions = Get-AvailableModuleVersionsText -ModuleName $requirement.ModuleName
        $modulePathDiagnostics = Get-ModulePathDiagnosticsText
        throw (
            "E_MODULE_BOOTSTRAP_VERIFY_FAILED: module '{0}' still unavailable after installation attempt (minimumVersion={1}). Installed versions: {2}. Module path diagnostics: {3}." -f
            $requirement.ModuleName,
            $requirement.MinimumVersion,
            $installedVersions,
            $modulePathDiagnostics
        )
    }
}

Write-Host "PowerShell quality module bootstrap passed."
