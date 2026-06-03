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
    }

    BeforeEach {
        Mock Install-Module {}
        Mock Set-PSRepository {}
        Mock Get-PackageProvider {}
        Mock Get-PSRepository { [pscustomobject]@{ Name = "PSGallery"; InstallationPolicy = "Trusted" } }
        Mock Write-Host {}
        Mock Write-Warning {}

        # Register-PSRepository -Default exposes mandatory dynamic parameters (Location) that break
        # Pester Mock parameter binding on PowerShellGet v2, so it is intercepted with a plain global
        # function shadow plus a global invocation counter rather than Mock. This is the one command
        # that cannot use Mock here; everything else uses Mock (which correctly intercepts the
        # dot-sourced ModuleHelpers functions).
        $global:WallstopRegisterPSRepositoryCalls = [System.Collections.Generic.List[object]]::new()
        function Global:Register-PSRepository {
            [CmdletBinding()]
            param(
                [switch]$Default
            )

            $global:WallstopRegisterPSRepositoryCalls.Add([pscustomobject]@{ Default = [bool]$Default })
        }
    }

    AfterEach {
        Remove-Item -Path Function:Register-PSRepository -ErrorAction SilentlyContinue
        Remove-Variable -Name WallstopRegisterPSRepositoryCalls -Scope Global -ErrorAction SilentlyContinue
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

        & $script:bootstrapPath -Modules $Module

        Should -Invoke Install-Module -Times 0
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

        & $script:bootstrapPath -Modules Pester

        Should -Invoke Install-Module -Times 1
    }

    It "throws an actionable diagnostic when installation fails" {
        Mock Get-CommandWithOptionalModuleImport { $null }
        Mock Install-Module { throw "simulated install failure" }
        Mock Get-AvailableModuleVersionsText { "(none)" }
        Mock Get-ModulePathDiagnosticsText { "entryCount=0; existingEntryCount=0; entries=(none)" }

        { & $script:bootstrapPath -Modules Pester } | Should -Throw -ExpectedMessage "*E_MODULE_BOOTSTRAP_INSTALL_FAILED*"
    }

    It "throws an actionable diagnostic when verification fails after install" {
        # Always-null command: the install reports success but the module is still unavailable.
        Mock Get-CommandWithOptionalModuleImport { $null }
        Mock Get-AvailableModuleVersionsText { "(none)" }
        Mock Get-ModulePathDiagnosticsText { "entryCount=0; existingEntryCount=0; entries=(none)" }

        { & $script:bootstrapPath -Modules Pester } | Should -Throw -ExpectedMessage "*E_MODULE_BOOTSTRAP_VERIFY_FAILED*"
    }

    It "bypasses all repository setup when -SkipPSGalleryTrust is supplied" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Get-PSRepository { $null }

        & $script:bootstrapPath -Modules Pester -SkipPSGalleryTrust

        Should -Invoke Set-PSRepository -Times 0
        Should -Invoke Get-PackageProvider -Times 0
        @($global:WallstopRegisterPSRepositoryCalls).Count | Should -Be 0
    }

    It "treats a PSGallery trust-update failure as non-fatal degradation" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Set-PSRepository { throw "simulated trust failure" }

        { & $script:bootstrapPath -Modules Pester } | Should -Not -Throw
        Should -Invoke Write-Warning -ParameterFilter { $Message -match "W_MODULE_BOOTSTRAP_TRUST_UPDATE_FAILED" }
    }

    It "registers the default PSGallery repository only when it is missing" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Get-PSRepository { $null }

        & $script:bootstrapPath -Modules Pester

        @($global:WallstopRegisterPSRepositoryCalls).Count | Should -Be 1
        $global:WallstopRegisterPSRepositoryCalls[0].Default | Should -BeTrue
    }

    It "does not register the default PSGallery repository when it already exists" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }
        Mock Get-PSRepository { [pscustomobject]@{ Name = "PSGallery" } }

        & $script:bootstrapPath -Modules Pester

        @($global:WallstopRegisterPSRepositoryCalls).Count | Should -Be 0
    }

    It "bootstraps the NuGet package provider" {
        Mock Get-CommandWithOptionalModuleImport { [pscustomobject]@{ Name = "Invoke-Pester" } }

        & $script:bootstrapPath -Modules Pester

        Should -Invoke Get-PackageProvider -ParameterFilter { $Name -eq "NuGet" }
    }
}
