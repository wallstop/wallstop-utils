Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    # ScoopRestore.ps1 cannot be dot-sourced safely: its top-level block immediately invokes
    # `scoop import`. Behavioral coverage therefore runs it as an isolated child pwsh with a fake
    # scoop shim on PATH and environment-driven install roots.
    . "$PSScriptRoot/../../Scripts/Utils/Common/CompatibilityHelpers.ps1"

    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:scoopRestoreScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Scoop/ScoopRestore.ps1"
    $script:pwshExecutable = Resolve-PowerShellExecutablePath
    $script:scoopRestoreHarnessRoots = @()

    function New-FakeScoopImportBin {
        # A scoop shim whose only contract is "import succeeds": writes nothing and exits 0 for any
        # arguments. Bash variant for Unix hosts, .ps1 variant for Windows hosts.
        param(
            [Parameter(Mandatory = $true)]
            [string]$BinDirectory
        )

        [void][System.IO.Directory]::CreateDirectory($BinDirectory)

        $bashShimPath = Join-Path -Path $BinDirectory -ChildPath "scoop"
        $bashShimText = @"
#!/usr/bin/env bash
exit 0
"@
        [System.IO.File]::WriteAllText($bashShimPath, ($bashShimText -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

        $ps1ShimPath = Join-Path -Path $BinDirectory -ChildPath "scoop.ps1"
        [System.IO.File]::WriteAllText($ps1ShimPath, "exit 0`n", [System.Text.UTF8Encoding]::new($false))

        if (-not (Test-IsWindowsPlatform)) {
            $chmodOutcome = @(& chmod "+x" $bashShimPath 2>&1)
            $chmodExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
            $chmodExitCode = if ($null -ne $chmodExitVariable) { [int]$chmodExitVariable } else { 0 }
            if ($chmodExitCode -ne 0) {
                throw "Failed to mark the fake scoop import shim executable: $($chmodOutcome -join ' ')"
            }
        }
    }

    function Register-ScoopRestoreHarnessForCleanup {
        param(
            [Parameter(Mandatory = $true)]
            [string]$HarnessRoot
        )

        if ($null -eq $script:scoopRestoreHarnessRoots) {
            $script:scoopRestoreHarnessRoots = @()
        }

        $script:scoopRestoreHarnessRoots = @($script:scoopRestoreHarnessRoots) + @($HarnessRoot)
    }
}

AfterAll {
    if (@($script:scoopRestoreHarnessRoots).Count -gt 0) {
        foreach ($harnessRootToDelete in @($script:scoopRestoreHarnessRoots)) {
            Remove-Item -LiteralPath $harnessRootToDelete -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "ScoopRestore Mozilla update-blocking policy deployment" {
    It "deploys policies under the user root and additionally under SCOOP_GLOBAL when present" {
        $harnessRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("scoop-restore-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        Register-ScoopRestoreHarnessForCleanup -HarnessRoot $harnessRoot

        $fakeBin = Join-Path -Path $harnessRoot -ChildPath "fake-bin"
        $userScoopRoot = Join-Path -Path $harnessRoot -ChildPath "user-scoop"
        $globalScoopRoot = Join-Path -Path $harnessRoot -ChildPath "global-scoop"

        # A Thunderbird app under the user root; a Firefox app only under the global root so the
        # previously-missed admin-install coverage is provable.
        [void][System.IO.Directory]::CreateDirectory((Join-Path -Path $userScoopRoot -ChildPath "apps/thunderbird"))
        [void][System.IO.Directory]::CreateDirectory((Join-Path -Path $globalScoopRoot -ChildPath "apps/firefox"))

        New-FakeScoopImportBin -BinDirectory $fakeBin

        $originalPath = $env:PATH
        $originalScoop = $env:SCOOP
        $originalScoopGlobal = $env:SCOOP_GLOBAL
        try {
            $env:PATH = "{0}{1}{2}" -f $fakeBin, [System.IO.Path]::PathSeparator, $env:PATH
            $env:SCOOP = $userScoopRoot
            $env:SCOOP_GLOBAL = $globalScoopRoot

            $childOutput = @(& $script:pwshExecutable -NoLogo -NoProfile -File $script:scoopRestoreScriptPath 2>&1)
            $childExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
            $childExitCode = if ($null -ne $childExitVariable) { [int]$childExitVariable } else { -1 }
            $childText = (($childOutput | ForEach-Object { [string]$_ }) -join "`n")

            $childExitCode | Should -Be 0
            $expectedPolicyPayload = '{"policies":{"DisableAppUpdate":true,"DisableTelemetry":true}}'

            $userPolicyPath = Join-Path -Path $userScoopRoot -ChildPath "persist/thunderbird/distribution/policies.json"
            Test-Path -LiteralPath $userPolicyPath -PathType Leaf | Should -BeTrue
            ([System.IO.File]::ReadAllText($userPolicyPath, [System.Text.Encoding]::UTF8)).Trim() | Should -Be $expectedPolicyPayload

            # Deployment must reach every installed Mozilla app, not just the first.
            $deployedMessages = @($childOutput | Where-Object { ([string]$_) -match "Deployed Mozilla update-blocking policy" })
            @($deployedMessages).Count | Should -BeGreaterOrEqual 1

            if (Test-IsWindowsPlatform) {
                $globalPolicyPath = Join-Path -Path $globalScoopRoot -ChildPath "persist/firefox/distribution/policies.json"
                Test-Path -LiteralPath $globalPolicyPath -PathType Leaf | Should -BeTrue
                ([System.IO.File]::ReadAllText($globalPolicyPath, [System.Text.Encoding]::UTF8)).Trim() | Should -Be $expectedPolicyPayload
            }
            else {
                # The global root is a Windows-only concept; on Unix only the user root is scanned,
                # so the firefox app under the unused global directory stays untouched and no skip
                # warning may fire (the user root WAS found).
                Test-Path -LiteralPath (Join-Path -Path $globalScoopRoot -ChildPath "persist/firefox/distribution/policies.json") -PathType Leaf | Should -BeFalse
                $childText | Should -Not -Match "W_SCOOP_RESTORE_MOZILLA_POLICY_SKIPPED"
            }
        }
        finally {
            $env:PATH = $originalPath
            $env:SCOOP = $originalScoop
            $env:SCOOP_GLOBAL = $originalScoopGlobal
        }
    }
}
