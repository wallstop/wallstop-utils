Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Describe "Install-PowerShellQualityModules behavioral conventions" {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
        $script:bootstrapPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1"

        # The bootstrap script dot-sources ModuleHelpers.ps1 at runtime; dot-source it here too so
        # Pester Mock can intercept the helper functions it defines (for example
        # Get-CommandWithOptionalModuleImport, which the script re-imports internally).
        . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/ModuleHelpers.ps1")
        . $script:bootstrapPath -NoInvokeMain
    }

    BeforeEach {
        $script:installModuleCalls = [System.Collections.Generic.List[hashtable]]::new()
        $script:installPsResourceCalls = [System.Collections.Generic.List[hashtable]]::new()

        function Global:Set-PSRepository {
            [CmdletBinding()]
            param(
                [string]$Name,
                [string]$InstallationPolicy
            )
        }

        function Global:Get-PackageProvider {
            [CmdletBinding()]
            param(
                [string]$Name,
                [switch]$ForceBootstrap
            )
        }

        function Global:Get-PSRepository {
            [CmdletBinding()]
            param(
                [string]$Name
            )

            return [pscustomobject]@{ Name = "PSGallery"; InstallationPolicy = "Trusted" }
        }

        Mock Set-PSRepository {}
        Mock Get-PackageProvider {}
        Mock Get-PSRepository { [pscustomobject]@{ Name = "PSGallery"; InstallationPolicy = "Trusted" } }
        Mock Import-Module {} -ParameterFilter { $Name -in @("PowerShellGet", "Microsoft.PowerShell.PSResourceGet") }
        Mock Write-Host {}
        Mock Write-Warning {}

        # Register-PSRepository -Default exposes mandatory dynamic parameters (Location) that break
        # Pester Mock parameter binding on PowerShellGet v2, so it is intercepted with a plain global
        # function shadow plus a global invocation counter rather than Mock. This is the one command
        # that cannot use Mock here; everything else uses Mock (which correctly intercepts the
        # dot-sourced ModuleHelpers functions).
        $global:WallstopInstallModuleShouldThrow = $false
        $global:WallstopInstallPSResourceShouldThrow = $false
        function Global:Install-Module {
            [CmdletBinding()]
            param(
                [string]$Name,
                [string]$Repository,
                [string]$Scope,
                [version]$MinimumVersion,
                [switch]$Force,
                [switch]$SkipPublisherCheck
            )

            $parameters = @{}
            foreach ($key in $PSBoundParameters.Keys) {
                $parameters[$key] = $PSBoundParameters[$key]
            }

            $script:installModuleCalls.Add($parameters) | Out-Null
            if ($global:WallstopInstallModuleShouldThrow) {
                throw "simulated install failure"
            }
        }

        function Global:Install-PSResource {
            [CmdletBinding()]
            param(
                [string[]]$Name,
                [string[]]$Repository,
                [string]$Scope,
                [string]$Version,
                [switch]$Reinstall,
                [switch]$Quiet,
                [switch]$AcceptLicense,
                [switch]$TrustRepository
            )

            $parameters = @{}
            foreach ($key in $PSBoundParameters.Keys) {
                $parameters[$key] = $PSBoundParameters[$key]
            }

            $script:installPsResourceCalls.Add($parameters) | Out-Null
            if ($global:WallstopInstallPSResourceShouldThrow) {
                throw "simulated psresource failure"
            }
        }

        $global:WallstopRegisterPSRepositoryCalls = [System.Collections.Generic.List[object]]::new()
        $global:WallstopRegisterPSRepositoryShouldThrow = $false
        function Global:Register-PSRepository {
            [CmdletBinding()]
            param(
                [switch]$Default
            )

            if ($global:WallstopRegisterPSRepositoryShouldThrow) {
                throw "simulated registration failure"
            }

            $global:WallstopRegisterPSRepositoryCalls.Add([pscustomobject]@{ Default = [bool]$Default })
        }
    }

    AfterEach {
        Remove-Item -Path Function:Install-Module -ErrorAction SilentlyContinue
        Remove-Item -Path Function:Install-PSResource -ErrorAction SilentlyContinue
        Remove-Item -Path Function:Register-PSRepository -ErrorAction SilentlyContinue
        Remove-Item -Path Function:Set-PSRepository -ErrorAction SilentlyContinue
        Remove-Item -Path Function:Get-PackageProvider -ErrorAction SilentlyContinue
        Remove-Item -Path Function:Get-PSRepository -ErrorAction SilentlyContinue
        Remove-Variable -Name WallstopInstallModuleShouldThrow -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name WallstopInstallPSResourceShouldThrow -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name WallstopRegisterPSRepositoryCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name WallstopRegisterPSRepositoryShouldThrow -Scope Global -ErrorAction SilentlyContinue
    }

    It "parses without syntax errors" {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:bootstrapPath, [ref]$null, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
    }

    It "skips installation when the requirement is already satisfied: <Module>" -TestCases @(
        @{ Module = 'Pester'; Command = 'Invoke-Pester' }
        @{ Module = 'PSScriptAnalyzer'; Command = 'Invoke-ScriptAnalyzer' }
    ) {
        param($Module, $Command)

        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = $Command } }.GetNewClosure()

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules $Module

        @($script:installModuleCalls).Count | Should -Be 0
    }

    It "installs the module when it is not yet satisfied" {
        # First availability probe (skip-if-satisfied) returns nothing; the post-install verify probe
        # returns a resolved command. The closure+hashtable form is used because in-mock $script:
        # lookups are unreliable under StrictMode.
        $state = @{ Count = 0 }
        Mock Get-CommandWithOptionalModuleImport {
            $state.Count++
            if ($state.Count -eq 1) { $null } else { [pscustomobject]@{ Name = "Invoke-Pester" } }
        }.GetNewClosure()

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester

        @($script:installModuleCalls).Count | Should -Be 1
        @($script:installPsResourceCalls).Count | Should -Be 0
    }

    It "installs without SkipPublisherCheck when PSGallery trust setup succeeds" {
        $state = @{ Count = 0 }
        Mock Get-CommandWithOptionalModuleImport {
            $state.Count++
            if ($state.Count -eq 1) { $null } else { [pscustomobject]@{ Name = "Invoke-Pester" } }
        }.GetNewClosure()

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester

        @($script:installModuleCalls).Count | Should -Be 1
        $script:installModuleCalls[0].ContainsKey("SkipPublisherCheck") | Should -BeFalse
        @($script:installPsResourceCalls).Count | Should -Be 0
        Should -Invoke Write-Warning -ParameterFilter { $Message -match "W_MODULE_BOOTSTRAP_SKIP_PUBLISHER_CHECK_FALLBACK" } -Times 0
    }

    It "uses SkipPublisherCheck when PSGallery trust setup is explicitly skipped" {
        $state = @{ Count = 0 }
        Mock Get-CommandWithOptionalModuleImport {
            $state.Count++
            if ($state.Count -eq 1) { $null } else { [pscustomobject]@{ Name = "Invoke-Pester" } }
        }.GetNewClosure()

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester -SkipPSGalleryTrust

        @($script:installModuleCalls).Count | Should -Be 1
        $script:installModuleCalls[0].ContainsKey("SkipPublisherCheck") | Should -BeTrue
        @($script:installPsResourceCalls).Count | Should -Be 0
        Should -Invoke Write-Warning -ParameterFilter { $Message -match "W_MODULE_BOOTSTRAP_SKIP_PUBLISHER_CHECK_FALLBACK" -and $Message -match "SkipPSGalleryTrust" } -Times 1
    }

    It "uses SkipPublisherCheck when PSGallery registration and trust setup degrade" {
        $state = @{ Count = 0 }
        Mock Get-CommandWithOptionalModuleImport {
            $state.Count++
            if ($state.Count -eq 1) { $null } else { [pscustomobject]@{ Name = "Invoke-Pester" } }
        }.GetNewClosure()
        Mock Get-PSRepository { $null }
        Mock Set-PSRepository { throw "simulated trust failure" }
        $global:WallstopRegisterPSRepositoryShouldThrow = $true

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester

        @($script:installModuleCalls).Count | Should -Be 1
        $script:installModuleCalls[0].ContainsKey("SkipPublisherCheck") | Should -BeTrue
        @($script:installPsResourceCalls).Count | Should -Be 0
        Should -Invoke Write-Warning -ParameterFilter { $Message -match "W_MODULE_BOOTSTRAP_SKIP_PUBLISHER_CHECK_FALLBACK" -and $Message -match "gallery-register-failed" -and $Message -match "gallery-trust-update-failed" } -Times 1
    }

    It "falls back to Install-PSResource when Install-Module fails" {
        $state = @{ Count = 0 }
        Mock Get-CommandWithOptionalModuleImport {
            $state.Count++
            if ($state.Count -eq 1) { $null } else { [pscustomobject]@{ Name = "Invoke-Pester" } }
        }.GetNewClosure()
        $global:WallstopInstallModuleShouldThrow = $true

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester

        @($script:installModuleCalls).Count | Should -Be 1
        @($script:installPsResourceCalls).Count | Should -Be 1
        $script:installPsResourceCalls[0]["Version"] | Should -Be "[5.5.0,)"
        Should -Invoke Write-Warning -ParameterFilter { $Message -match "W_MODULE_BOOTSTRAP_PSRESOURCE_FALLBACK" } -Times 1
    }

    It "throws an actionable diagnostic when installation fails" {
        Mock Get-CommandWithOptionalModuleImport { $null }
        $global:WallstopInstallModuleShouldThrow = $true
        $global:WallstopInstallPSResourceShouldThrow = $true
        Mock Get-AvailableModuleVersionsText { "(none)" }
        Mock Get-ModulePathDiagnosticsText { "entryCount=0; existingEntryCount=0; entries=(none)" }

        { Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester } | Should -Throw -ExpectedMessage "*E_MODULE_BOOTSTRAP_INSTALL_FAILED*simulated install failure*simulated psresource failure*"
    }

    It "throws an actionable diagnostic when verification fails after install" {
        # Always-null command: the install reports success but the module is still unavailable.
        Mock Get-CommandWithOptionalModuleImport { $null }
        Mock Get-AvailableModuleVersionsText { "(none)" }
        Mock Get-ModulePathDiagnosticsText { "entryCount=0; existingEntryCount=0; entries=(none)" }

        { Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester } | Should -Throw -ExpectedMessage "*E_MODULE_BOOTSTRAP_VERIFY_FAILED*"
    }

    It "bypasses all repository setup when -SkipPSGalleryTrust is supplied" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Get-PSRepository { $null }

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester -SkipPSGalleryTrust

        Should -Invoke Set-PSRepository -Times 0
        Should -Invoke Get-PackageProvider -Times 0
        @($global:WallstopRegisterPSRepositoryCalls).Count | Should -Be 0
    }

    It "treats a PSGallery trust-update failure as non-fatal degradation" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Set-PSRepository { throw "simulated trust failure" }

        { Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester } | Should -Not -Throw
        Should -Invoke Write-Warning -ParameterFilter { $Message -match "W_MODULE_BOOTSTRAP_TRUST_UPDATE_FAILED" }
    }

    It "registers the default PSGallery repository only when it is missing" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Get-PSRepository { $null }

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester

        @($global:WallstopRegisterPSRepositoryCalls).Count | Should -Be 1
        $global:WallstopRegisterPSRepositoryCalls[0].Default | Should -BeTrue
    }

    It "does not register the default PSGallery repository when it already exists" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Get-PSRepository { [pscustomobject]@{ Name = "PSGallery" } }

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester

        @($global:WallstopRegisterPSRepositoryCalls).Count | Should -Be 0
    }

    It "bootstraps the NuGet package provider" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }

        Invoke-PowerShellQualityModuleBootstrap -RequestedModules Pester

        Should -Invoke Get-PackageProvider -ParameterFilter { $Name -eq "NuGet" }
    }
}
