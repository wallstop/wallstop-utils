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
    # Enable TLS 1.2 on Windows PowerShell 5.1 (Desktop edition) only; the .NET Framework default
    # protocol set predates TLS 1.2 and PSGallery requires it. Gate on PSEdition (never bare
    # $IsWindows, which is undefined under StrictMode on 5.1) so PowerShell 7+ is unaffected.
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Verbose "PowerShell module bootstrap diagnostics: enabled TLS 1.2 for Windows PowerShell 5.1."
        }
        catch {
            Write-Verbose ("PowerShell module bootstrap diagnostics: TLS 1.2 enable skipped: {0}" -f $_.Exception.Message)
        }
    }

    # Bootstrap the NuGet package provider when available. This registers PSGallery as a side effect
    # on hosts where it is missing and is the step the passing Windows PowerShell 5.1 lane relied on.
    $getPackageProviderCommand = Get-Command -Name "Get-PackageProvider" -ErrorAction SilentlyContinue
    if ($null -ne $getPackageProviderCommand) {
        try {
            Get-PackageProvider -Name NuGet -ForceBootstrap | Out-Null
            Write-Verbose "PowerShell module bootstrap diagnostics: NuGet package provider bootstrapped."
        }
        catch {
            Write-Verbose ("PowerShell module bootstrap diagnostics: NuGet provider bootstrap skipped: {0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Verbose "PowerShell module bootstrap diagnostics: Get-PackageProvider command unavailable; skipping NuGet provider bootstrap."
    }

    # Register the default PSGallery repository ONLY when it is missing. GitHub runner images
    # intermittently ship with PSGallery unregistered, which makes Set-PSRepository / Install-Module
    # fail with "No repository with the name 'PSGallery' was found." Register-PSRepository -Default
    # THROWS when PSGallery already exists, so the existence guard is mandatory.
    $getPsRepositoryCommand = Get-Command -Name "Get-PSRepository" -ErrorAction SilentlyContinue
    if ($null -ne $getPsRepositoryCommand) {
        if ($null -eq (Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue)) {
            try {
                Register-PSRepository -Default -ErrorAction Stop
                Write-Verbose "PowerShell module bootstrap diagnostics: registered default PSGallery repository."
            }
            catch {
                Write-Warning "W_MODULE_BOOTSTRAP_GALLERY_REGISTER_FAILED: unable to register the default PSGallery repository. Continuing with explicit -Force installs."
                Write-Verbose ("PowerShell module bootstrap gallery registration diagnostics: {0}" -f $_.Exception.Message)
            }
        }
        else {
            Write-Verbose "PowerShell module bootstrap diagnostics: PSGallery repository already registered."
        }
    }
    else {
        Write-Verbose "PowerShell module bootstrap diagnostics: Get-PSRepository command unavailable; skipping default repository registration."
    }

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
        Install-Module -Name $requirement.ModuleName -Repository "PSGallery" -Scope CurrentUser -MinimumVersion $requirement.MinimumVersion -Force -SkipPublisherCheck -ErrorAction Stop
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
