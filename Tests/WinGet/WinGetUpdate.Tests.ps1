Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    # Dot-source the update script. The run guard ($MyInvocation.InvocationName -ne ".") prevents
    # the live winget invocation from executing on dot-source, exposing only the classifiers.
    . (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/WinGet/WinGetUpdate.ps1")

    # CompatibilityHelpers provides Resolve-PowerShellExecutablePath for child-process tests.
    . (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/Common/CompatibilityHelpers.ps1")

    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:updateScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/WinGet/WinGetUpdate.ps1"
    $script:pwshExecutable = Resolve-PowerShellExecutablePath
    $script:winGetHarnessRoots = @()

    function New-Utf8NoBomTextFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Text
        )

        $parentDirectory = [System.IO.Path]::GetDirectoryName($Path)
        if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($parentDirectory)
        }

        [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
    }

    function ConvertTo-BashSingleQuotedLiteral {
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Text
        )

        $bashEscaped = $Text -replace "'", "'\\''"
        return "'" + $bashEscaped + "'"
    }

    function ConvertTo-PowerShellSingleQuotedLiteral {
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Text
        )

        return "'" + ($Text -replace "'", "''") + "'"
    }

    function New-FakeWingetCommandBin {
        # Writes fixture-driven fake `winget` shims into an isolated bin directory: a bash shim for
        # Unix hosts and a winget.ps1 shim for Windows hosts. The upgrade payload and exit code are
        # embedded directly in the shim source so each fake is self-contained and deterministic.
        param(
            [Parameter(Mandatory = $true)]
            [string]$BinDirectory,

            [Parameter(Mandatory = $false)]
            [AllowEmptyString()]
            [string]$UpgradeOutput = "",

            [Parameter(Mandatory = $true)]
            [int]$UpgradeExitCode
        )

        [void][System.IO.Directory]::CreateDirectory($BinDirectory)

        $normalizedOutput = $UpgradeOutput -replace "`r`n", "`n"
        $escapedOutputBash = ConvertTo-BashSingleQuotedLiteral -Text $normalizedOutput
        $escapedOutputPowerShell = ConvertTo-PowerShellSingleQuotedLiteral -Text $normalizedOutput

        $bashShimText = @"
#!/usr/bin/env bash
set -u
printf '%s\n' $escapedOutputBash
exit $UpgradeExitCode
"@
        $bashShimPath = Join-Path -Path $BinDirectory -ChildPath "winget"
        New-Utf8NoBomTextFile -Path $bashShimPath -Text ($bashShimText -replace "`r`n", "`n")

        $ps1ShimText = @"
param()
# Pipeline output, never [Console]::Out: console writes bypass PowerShell's output pipeline,
# so a caller capturing @(`$script 2>&1) would see nothing.
Write-Output $escapedOutputPowerShell
exit $UpgradeExitCode
"@
        $ps1ShimPath = Join-Path -Path $BinDirectory -ChildPath "winget.ps1"
        New-Utf8NoBomTextFile -Path $ps1ShimPath -Text ($ps1ShimText -replace "`r`n", "`n")

        if (-not (Test-IsWindowsPlatform)) {
            $chmodOutcome = @(& chmod "+x" $bashShimPath 2>&1)
            $chmodExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
            $chmodExitCode = if ($null -ne $chmodExitVariable) { [int]$chmodExitVariable } else { 0 }
            if ($chmodExitCode -ne 0) {
                throw "Failed to mark the fake winget bash shim executable: $($chmodOutcome -join ' ')"
            }
        }
    }

    function Invoke-WinGetUpdateInChild {
        # Runs the update script in an isolated child pwsh with a fake winget bin prepended to
        # PATH, returning merged output plus the child exit code. Environment mutations are
        # restored by the caller's finally block.
        param(
            [Parameter(Mandatory = $true)]
            [string]$FakeBinDirectory
        )

        $previousPath = $env:PATH
        $env:PATH = "{0}{1}{2}" -f $FakeBinDirectory, [System.IO.Path]::PathSeparator, $env:PATH
        try {
            $childOutput = @(& $script:pwshExecutable -NoLogo -NoProfile -File $script:updateScriptPath 2>&1)
        }
        finally {
            $env:PATH = $previousPath
        }

        $childExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
        $childExitCode = if ($null -ne $childExitVariable) { [int]$childExitVariable } else { -1 }

        return [pscustomobject]@{
            Output   = $childOutput
            ExitCode = $childExitCode
            Text     = (($childOutput | ForEach-Object { [string]$_ }) -join "`n")
        }
    }

    function Register-WinGetHarnessForCleanup {
        param(
            [Parameter(Mandatory = $true)]
            [string]$HarnessRoot
        )

        $script:winGetHarnessRoots = @($script:winGetHarnessRoots) + @($HarnessRoot)
    }
}

AfterAll {
    foreach ($harnessRootToDelete in $script:winGetHarnessRoots) {
        Remove-Item -LiteralPath $harnessRootToDelete -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Get-WinGetUpgradePackageOutcomes" {
    It "accounts every Found block from the observed issue #46 upgrade output" {
        # Shapes taken verbatim from the Config/backup-step-failures.json outputPreview of the
        # 2026-08-25 backup run (issue #46): three failing packages between successful blocks.
        $observedLines = @(
            "Name                               Id                                             Version        Available      Source",
            "------------------------------------------------------------------------------------------------------",
            "Focusrite Control 2 1.1081.0.0     FocusriteAudioEngineeringLtd.FocusriteControl2 1.1081.0.0     1.1108.0.0     winget",
            "9 upgrades available.",
            "(1/7) Found Focusrite Control 2 [FocusriteAudioEngineeringLtd.FocusriteControl2] Version 1.1108.0.0",
            "Successfully verified installer hash",
            "Starting package install...",
            "Installer failed with exit code: 1602",
            "",
            "(6/7) Found Plex [Plex.Plex] Version 1.115.0",
            "This application is licensed to you by its owner.",
            "Successfully verified installer hash",
            "Starting package install...",
            "Installer failed with exit code: 1223",
            "",
            "(7/7) Found Windows Subsystem for Linux [Microsoft.WSL] Version 2.7.12",
            "Successfully verified installer hash",
            "Starting package install...",
            "Installer failed with exit code: 0x80073d28 : The package installation failed because administrator privileges are required.",
            ""
        )

        $outcomes = @(Get-WinGetUpgradePackageOutcomes -OutputLines $observedLines)

        $outcomes.Count | Should -Be 3
        $outcomes[0].PackageId | Should -Be "FocusriteAudioEngineeringLtd.FocusriteControl2"
        $outcomes[0].Status | Should -Be "Failed"
        $outcomes[0].InstallerExitCode | Should -Be "1602"
        $outcomes[1].PackageId | Should -Be "Plex.Plex"
        $outcomes[1].Status | Should -Be "Failed"
        $outcomes[1].InstallerExitCode | Should -Be "1223"
        $outcomes[2].PackageId | Should -Be "Microsoft.WSL"
        $outcomes[2].Status | Should -Be "Failed"
        $outcomes[2].InstallerExitCode | Should -Be "0x80073d28"
    }

    It "expands a single multi-line capture element (script-shim output shape)" {
        $singleElementPayload = (@(
                "(1/2) Found Example App [Example.Publisher] Version 1.0.0",
                "Installer failed with exit code: 1602",
                "(2/2) Found Other App [Other.Publisher] Version 2.0.0",
                "Successfully installed"
            ) -join "`n")

        $outcomes = @(Get-WinGetUpgradePackageOutcomes -OutputLines @($singleElementPayload))

        $outcomes.Count | Should -Be 2
        $outcomes[0].PackageId | Should -Be "Example.Publisher"
        $outcomes[0].Status | Should -Be "Failed"
        $outcomes[1].PackageId | Should -Be "Other.Publisher"
        $outcomes[1].Status | Should -Be "Upgraded"
    }

    It "marks Found blocks without a terminal marker as Unresolved so unparsed failures cannot hide" {
        $outcomes = @(Get-WinGetUpgradePackageOutcomes -OutputLines @(
                "(1/2) Found Healthy App [Healthy.Publisher] Version 2.0.0",
                "Successfully installed",
                "(2/2) Found Silent Failure [Silent.Publisher] Version 1.0.0",
                "Some unrecognized failure phrasing."
            ))

        $outcomes.Count | Should -Be 2
        $outcomes[0].PackageId | Should -Be "Healthy.Publisher"
        $outcomes[0].Status | Should -Be "Upgraded"
        $outcomes[1].PackageId | Should -Be "Silent.Publisher"
        $outcomes[1].Status | Should -Be "Unresolved"
    }

    It "attributes in-block dependency installer failures to the owning package block" {
        # Dependency installers run inside the parent's numbered progress block; winget fails
        # the parent when its dependency fails, so parent ownership is the truthful pairing.
        $outcomes = @(Get-WinGetUpgradePackageOutcomes -OutputLines @(
                "(1/1) Found Focusrite Control 2 [FocusriteAudioEngineeringLtd.FocusriteControl2] Version 1.1108.0.0",
                "Installing dependencies:",
                "This package requires the following dependencies:",
                "- Packages",
                "Microsoft.VCRedist.2015+.x64",
                "Installer failed with exit code: 1602"
            ))

        $outcomes.Count | Should -Be 1
        $outcomes[0].PackageId | Should -Be "FocusriteAudioEngineeringLtd.FocusriteControl2"
        $outcomes[0].Status | Should -Be "Failed"
        $outcomes[0].InstallerExitCode | Should -Be "1602"
    }

    It "returns no outcomes for empty input" {
        @(Get-WinGetUpgradePackageOutcomes -OutputLines @()).Count | Should -Be 0
    }
}

Describe "Test-WinGetInstallerExitCodeIsConsentBlocked" {
    It "classifies installer exit '<InstallerExitCode>' as consentBlocked=<Expected>" -ForEach @(
        # UAC declined/suppressed shapes observed on the host (issue #46).
        @{ InstallerExitCode = "1602"; Expected = $true },
        @{ InstallerExitCode = "1223"; Expected = $true },
        @{ InstallerExitCode = " 1223 "; Expected = $true },
        @{ InstallerExitCode = "0x80073d28"; Expected = $true },
        @{ InstallerExitCode = "0x80073D28"; Expected = $true },
        # Genuine installer failures stay red.
        @{ InstallerExitCode = "1603"; Expected = $false },
        @{ InstallerExitCode = "0x80070005"; Expected = $false },
        @{ InstallerExitCode = ""; Expected = $false },
        @{ InstallerExitCode = "garbage"; Expected = $false }
    ) {
        param($InstallerExitCode, $Expected)

        Test-WinGetInstallerExitCodeIsConsentBlocked -InstallerExitCode $InstallerExitCode | Should -Be $Expected
    }
}

Describe "Resolve-WinGetUpdateOutcome" {
    It "classifies winget exit <WingetExitCode> (<Description>)" -ForEach @(
        @{
            Description      = "full success"
            WingetExitCode   = 0
            ExpectedExitZero = $true
            ExpectedExitCode = 0
        },
        @{
            Description      = "no applicable upgrades"
            WingetExitCode   = -1978335189
            ExpectedExitZero = $true
            ExpectedExitCode = 0
            ExpectNoApplicable = $true
        },
        @{
            Description         = "consent-blocked partial failure"
            WingetExitCode      = -1978335188
            OutputLines         = @(
                "(1/2) Found Plex [Plex.Plex] Version 1.115.0",
                "Installer failed with exit code: 1223",
                "(2/2) Found Windows Subsystem for Linux [Microsoft.WSL] Version 2.7.12",
                "Installer failed with exit code: 0x80073d28 : administrator privileges are required."
            )
            ExpectedExitZero    = $true
            ExpectedExitCode    = 0
            ExpectWarningCode   = "W_WINGET_UPGRADE_DEFERRED_INTERACTIVE"
        },
        @{
            Description         = "genuine package failure"
            WingetExitCode      = -1978335188
            OutputLines         = @(
                "(1/1) Found Broken App [Broken.Publisher] Version 1.0.0",
                "Installer failed with exit code: 1603"
            )
            ExpectedExitZero    = $false
            ExpectedExitCode    = -1978335188
            ExpectErrorCode     = "E_WINGET_UPDATE_PACKAGE_INSTALL_FAILED"
        },
        @{
            Description         = "mixed consent-blocked and genuine failures keep both diagnostics"
            WingetExitCode      = -1978335188
            OutputLines         = @(
                "(1/2) Found Plex [Plex.Plex] Version 1.115.0",
                "Installer failed with exit code: 1602",
                "(2/2) Found Broken App [Broken.Publisher] Version 1.0.0",
                "Installer failed with exit code: 1603"
            )
            ExpectedExitZero    = $false
            ExpectedExitCode    = -1978335188
            ExpectWarningCode   = "W_WINGET_UPGRADE_DEFERRED_INTERACTIVE"
            ExpectErrorCode     = "E_WINGET_UPDATE_PACKAGE_INSTALL_FAILED"
        },
        @{
            Description         = "unattributable aggregate failure fails closed"
            WingetExitCode      = -1978335188
            OutputLines         = @("Some localized aggregate failure text without per-package blocks.")
            ExpectedExitZero    = $false
            ExpectedExitCode    = -1978335188
            ExpectErrorCode     = "E_WINGET_UPDATE_UNATTRIBUTED_FAILURE"
        },
        @{
            Description         = "unknown exit code fails closed with preview"
            WingetExitCode      = -1978335215
            OutputLines         = @("Unexpected catastrophic winget failure.")
            ExpectedExitZero    = $false
            ExpectedExitCode    = -1978335215
            ExpectErrorCode     = "E_WINGET_UPDATE_FAILED"
        }
    ) {
        param($Description, $WingetExitCode, $OutputLines, $ExpectedExitZero, $ExpectedExitCode, $ExpectNoApplicable, $ExpectWarningCode, $ExpectErrorCode)

        if (-not $OutputLines) {
            $OutputLines = @()
        }

        $outcome = Resolve-WinGetUpdateOutcome -WingetExitCode $WingetExitCode -OutputLines $OutputLines

        $outcome.ExitZero | Should -Be $ExpectedExitZero -Because $Description
        $outcome.ExitCode | Should -Be $ExpectedExitCode -Because $Description

        if ($ExpectNoApplicable) {
            $outcome.NoApplicable | Should -BeTrue
        }

        if ($ExpectWarningCode) {
            $outcome.WarningDiagnostic | Should -Match $ExpectWarningCode
            if ($Description -eq "consent-blocked partial failure") {
                $outcome.WarningDiagnostic | Should -Match "Plex\.Plex \(installer exit 1223\)"
                $outcome.WarningDiagnostic | Should -Match "Microsoft\.WSL \(installer exit 0x80073d28\)"
            }
        }
        else {
            $outcome.WarningDiagnostic | Should -Be ""
        }

        if ($ExpectErrorCode) {
            $outcome.ErrorDiagnostic | Should -Match $ExpectErrorCode
            if ($ExpectErrorCode -eq "E_WINGET_UPDATE_PACKAGE_INSTALL_FAILED") {
                $outcome.ErrorDiagnostic | Should -Match "Broken\.Publisher \(installer exit 1603\)"
            }
        }
        else {
            $outcome.ErrorDiagnostic | Should -Be ""
        }
    }

    It "fails closed when an unparsed failure rides along behind consent-blocked deferrals" {
        # Bugbot round on PR #76: an aggregate failure whose Found blocks include one consent
        # attribution and one block with no terminal marker must NOT green the step.
        $outcome = Resolve-WinGetUpdateOutcome -WingetExitCode -1978335188 -OutputLines @(
            "(1/2) Found Plex [Plex.Plex] Version 1.115.0",
            "Installer failed with exit code: 1223",
            "(2/2) Found Silent Failure [Silent.Publisher] Version 1.0.0",
            "Some unrecognized failure phrasing."
        )

        $outcome.ExitZero | Should -BeFalse
        $outcome.ExitCode | Should -Be -1978335188
        $outcome.ErrorDiagnostic | Should -Match "E_WINGET_UPDATE_UNATTRIBUTED_FAILURE"
        $outcome.ErrorDiagnostic | Should -Match "Silent\.Publisher"
        $outcome.WarningDiagnostic | Should -Match "W_WINGET_UPGRADE_DEFERRED_INTERACTIVE"
    }

    It "greens a mixed run where every Found block reaches a terminal marker" {
        $outcome = Resolve-WinGetUpdateOutcome -WingetExitCode -1978335188 -OutputLines @(
            "(1/2) Found Plex [Plex.Plex] Version 1.115.0",
            "Installer failed with exit code: 1223",
            "(2/2) Found Healthy App [Healthy.Publisher] Version 2.0.0",
            "Successfully installed"
        )

        $outcome.ExitZero | Should -BeTrue
        $outcome.WarningDiagnostic | Should -Match "Plex\.Plex \(installer exit 1223\)"
        $outcome.ErrorDiagnostic | Should -Be ""
    }
}

Describe "WinGetUpdate step behavior" {
    It "exits cleanly when fake winget succeeds" {
        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winget-update-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        Register-WinGetHarnessForCleanup -HarnessRoot $harnessRoot
        New-FakeWingetCommandBin -BinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin") `
            -UpgradeOutput "Everything is up to date." `
            -UpgradeExitCode 0

        $result = Invoke-WinGetUpdateInChild -FakeBinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin")

        $result.ExitCode | Should -Be 0
        $result.Text | Should -Not -Match "E_WINGET_UPDATE_FAILED|E_WINGET_UPDATE_NOT_AVAILABLE"
    }

    It "treats the winget no-applicable-upgrade no-op as success" {
        if (-not (Test-IsWindowsPlatform)) {
            Set-ItResult -Skipped -Because "POSIX children truncate winget's int32 aggregate HRESULT to 8 bits; resolver branches are unit-covered."
            return
        }

        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winget-update-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        Register-WinGetHarnessForCleanup -HarnessRoot $harnessRoot
        New-FakeWingetCommandBin -BinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin") `
            -UpgradeOutput "No applicable upgrade found." `
            -UpgradeExitCode -1978335189

        $result = Invoke-WinGetUpdateInChild -FakeBinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin")

        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match "no applicable upgrades found"
    }

    It "fails closed with a bounded preview when fake winget exits with an unknown code" {
        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winget-update-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        Register-WinGetHarnessForCleanup -HarnessRoot $harnessRoot
        New-FakeWingetCommandBin -BinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin") `
            -UpgradeOutput "Unexpected catastrophic winget failure." `
            -UpgradeExitCode 1

        $result = Invoke-WinGetUpdateInChild -FakeBinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin")

        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match "E_WINGET_UPDATE_FAILED"
        $result.Text | Should -Match "outputPreview="
    }

    It "greens consent-blocked partial failures with an explicit warning" {
        if (-not (Test-IsWindowsPlatform)) {
            Set-ItResult -Skipped -Because "POSIX children truncate winget's int32 aggregate HRESULT to 8 bits; resolver branches are unit-covered."
            return
        }

        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winget-update-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        Register-WinGetHarnessForCleanup -HarnessRoot $harnessRoot
        New-FakeWingetCommandBin -BinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin") `
            -UpgradeOutput (@(
                "(1/2) Found Plex [Plex.Plex] Version 1.115.0",
                "Starting package install...",
                "Installer failed with exit code: 1223",
                "(2/2) Found Windows Subsystem for Linux [Microsoft.WSL] Version 2.7.12",
                "Starting package install...",
                "Installer failed with exit code: 0x80073d28 : The package installation failed because administrator privileges are required."
            ) -join "`n") `
            -UpgradeExitCode -1978335188

        $result = Invoke-WinGetUpdateInChild -FakeBinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin")

        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match "W_WINGET_UPGRADE_DEFERRED_INTERACTIVE"
        $result.Text | Should -Match "Plex\.Plex \(installer exit 1223\)"
        $result.Text | Should -Match "Microsoft\.WSL \(installer exit 0x80073d28\)"
        $result.Text | Should -Not -Match "E_WINGET_UPDATE_PACKAGE_INSTALL_FAILED"
    }

    It "fails non-consent package failures with attributable diagnostics" {
        if (-not (Test-IsWindowsPlatform)) {
            Set-ItResult -Skipped -Because "POSIX children truncate winget's int32 aggregate HRESULT to 8 bits; resolver branches are unit-covered."
            return
        }

        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winget-update-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        Register-WinGetHarnessForCleanup -HarnessRoot $harnessRoot
        New-FakeWingetCommandBin -BinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin") `
            -UpgradeOutput (@(
                "(1/1) Found Broken App [Broken.Publisher] Version 1.0.0",
                "Starting package install...",
                "Installer failed with exit code: 1603"
            ) -join "`n") `
            -UpgradeExitCode -1978335188

        $result = Invoke-WinGetUpdateInChild -FakeBinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin")

        $result.ExitCode | Should -Be -1978335188
        $result.Text | Should -Match "E_WINGET_UPDATE_PACKAGE_INSTALL_FAILED"
        $result.Text | Should -Match "Broken\.Publisher \(installer exit 1603\)"
        $result.Text | Should -Not -Match "W_WINGET_UPGRADE_DEFERRED_INTERACTIVE"
    }

    It "fails closed when aggregate failures cannot be attributed" {
        if (-not (Test-IsWindowsPlatform)) {
            Set-ItResult -Skipped -Because "POSIX children truncate winget's int32 aggregate HRESULT to 8 bits; resolver branches are unit-covered."
            return
        }

        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winget-update-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        Register-WinGetHarnessForCleanup -HarnessRoot $harnessRoot
        New-FakeWingetCommandBin -BinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin") `
            -UpgradeOutput "Some localized aggregate failure text without per-package blocks." `
            -UpgradeExitCode -1978335188

        $result = Invoke-WinGetUpdateInChild -FakeBinDirectory (Join-Path -Path $harnessRoot -ChildPath "fake-bin")

        $result.ExitCode | Should -Be -1978335188
        $result.Text | Should -Match "E_WINGET_UPDATE_UNATTRIBUTED_FAILURE"
        $result.Text | Should -Match "outputPreview="
    }
}
