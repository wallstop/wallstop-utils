Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    # Dot-source the orchestrator. Its run guard ($MyInvocation.InvocationName -ne ".")
    # prevents any update step from executing, exposing only the pure helpers.
    . (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Update.ps1")

    . (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/Common/CompatibilityHelpers.ps1")

    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path

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
}

Describe "Resolve-UpdateElevationAction" {
    It "resolves WithAdmin=<WithAdmin> onWindows=<IsWindowsPlatform> elevated=<IsRunningElevated> to <ExpectedAction>" -ForEach @(
        @{
            WithAdmin         = $true
            IsWindowsPlatform = $true
            IsRunningElevated = $false
            ExpectedAction    = "RelaunchElevated"
        },
        @{
            WithAdmin         = $true
            IsWindowsPlatform = $true
            IsRunningElevated = $true
            ExpectedAction    = "Proceed"
        },
        @{
            WithAdmin         = $true
            IsWindowsPlatform = $false
            IsRunningElevated = $false
            ExpectedAction    = "WarnUnsupportedPlatform"
        },
        @{
            WithAdmin         = $true
            IsWindowsPlatform = $false
            IsRunningElevated = $true
            ExpectedAction    = "WarnUnsupportedPlatform"
        },
        @{ WithAdmin = $false; IsWindowsPlatform = $true; IsRunningElevated = $false; ExpectedAction = "Proceed" },
        @{ WithAdmin = $false; IsWindowsPlatform = $false; IsRunningElevated = $false; ExpectedAction = "Proceed" }
    ) {
        param($WithAdmin, $IsWindowsPlatform, $IsRunningElevated, $ExpectedAction)

        $decision = Resolve-UpdateElevationAction `
            -WithAdmin $WithAdmin -IsWindowsPlatform $IsWindowsPlatform -IsRunningElevated $IsRunningElevated

        $decision.Action | Should -Be $ExpectedAction
    }

    It "never relaunches elevation outside an explicit -WithAdmin opt-in" {
        # Default runs must stay fully headless/no-prompt (issue #77): the headless row of
        # every matrix cell above pins Proceed, including the elevated-Windows case here so
        # an administrator console never spontaneously spawns a second session either.
        $decision = Resolve-UpdateElevationAction -WithAdmin $false -IsWindowsPlatform $true -IsRunningElevated $true
        $decision.Action | Should -Be "Proceed"

        $optInDecision = Resolve-UpdateElevationAction -WithAdmin $true -IsWindowsPlatform $true -IsRunningElevated $false
        $optInDecision.Action | Should -Be "RelaunchElevated"
    }

    It "degrades the unsupported-platform branch with a stable warning code instead of failing" {
        $decision = Resolve-UpdateElevationAction -WithAdmin $true -IsWindowsPlatform $false -IsRunningElevated $false
        $decision.Code | Should -Be "W_UPDATE_ELEVATION_UNSUPPORTED_PLATFORM"
        $decision.Detail | Should -Match "headless"
    }
}

Describe "Resolve-UpdateElevationStartFailure" {
    It "maps a Process.Start failure of kind '<Description>' to <ExpectedCode>" -ForEach @(
        @{
            Description      = "operator declining UAC (ERROR_CANCELLED)"
            IsWin32Exception = $true
            NativeErrorCode  = 1223
            ExceptionMessage = "The operation was canceled by the user"
            ExpectedCode     = "E_UPDATE_ELEVATION_DECLINED"
        },
        @{
            Description      = "UAC disabled by policy (generic win32)"
            IsWin32Exception = $true
            NativeErrorCode  = 1260
            ExceptionMessage = "This program is blocked by group policy"
            ExpectedCode     = "E_UPDATE_ELEVATION_START_FAILED"
        },
        @{
            Description      = "resolver returned an unusable executable (non-win32)"
            IsWin32Exception = $false
            NativeErrorCode  = 0
            ExceptionMessage = "Cannot find the requested file"
            ExpectedCode     = "E_UPDATE_ELEVATION_START_FAILED"
        }
    ) {
        param($Description, $IsWin32Exception, $NativeErrorCode, $ExceptionMessage, $ExpectedCode)

        $failure = Resolve-UpdateElevationStartFailure `
            -IsWin32Exception $IsWin32Exception `
            -NativeErrorCode $NativeErrorCode `
            -ExceptionTypeName "System.Exception" `
            -ExceptionMessage $ExceptionMessage

        $failure.Code | Should -Be $ExpectedCode -Because $Description
        if ($ExpectedCode -eq "E_UPDATE_ELEVATION_DECLINED") {
            $failure.Detail | Should -Match "win32Error=1223"
        }
        else {
            $failure.Detail | Should -Match ([regex]::Escape($ExceptionMessage))
        }
    }
}

Describe "Test-UpdateRunningElevated" {
    It "answers without throwing and reports elevation state per platform" {
        $isElevated = Test-UpdateRunningElevated
        ($isElevated -is [bool]) | Should -BeTrue

        if (-not (Test-IsWindowsPlatform)) {
            $isElevated | Should -BeFalse
        }
    }
}

Describe "Get-UpdateSelfRelaunchArguments" {
    It "relays the relay switches plus the resolved script path verbatim" {
        $arguments = @(Get-UpdateSelfRelaunchArguments -ScriptPath "C:/repos/utils/Scripts/Update.ps1")

        $arguments.Count | Should -Be 7
        $arguments | Should -Contain "-NoLogo"
        $arguments | Should -Contain "-NoProfile"
        $arguments | Should -Contain "-ExecutionPolicy"
        $arguments | Should -Contain "-WithAdmin"
        $arguments[4] | Should -Be "-File"
        $arguments[5] | Should -Be "C:/repos/utils/Scripts/Update.ps1"
    }
}

Describe "Update orchestrator behavior" {
    BeforeAll {
        # Seeded up front so AfterAll stays safe even if this block throws before creating
        # the sandbox (Pester 5 still runs AfterAll on BeforeAll failure; binding errors are
        # not suppressed by -ErrorAction SilentlyContinue under Set-StrictMode Latest).
        $script:sandboxRoot = $null

        # Sandbox copy of the repository's Scripts tree: Update.ps1 verbatim beside stub
        # step scripts and a deterministic pseudo-helper. The parent passes its own resolved
        # PowerShell executable into the pseudo-helper so stub steps launch portably. No real
        # package manager is touched from any host - Windows CI lanes included.
        $script:realPowerShellExecutable = Resolve-PowerShellExecutablePath
        $script:sandboxRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("update-sandbox-{0}" -f [System.Guid]::NewGuid().ToString("N"))
        $script:sandboxScriptsDirectory = Join-Path -Path $script:sandboxRoot -ChildPath "Scripts"
        [void][System.IO.Directory]::CreateDirectory((Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "Utils/Common"))
        foreach ($stepRelativeDirectory in @("Komorebi", "Scoop", "WinGet")) {
            [void][System.IO.Directory]::CreateDirectory((Join-Path -Path $script:sandboxScriptsDirectory -ChildPath $stepRelativeDirectory))
        }

        $updateScriptSource = (Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Update.ps1") -Raw)
        New-Utf8NoBomTextFile -Path (Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "Update.ps1") -Text $updateScriptSource

        # Stub every SupportedPlatforms=@("Windows") step target so nothing outside the
        # sandbox executes even on the primary Windows host.
        $stubStepContent = @"
if (\$env:WALLSTOP_UPDATE_SANDBOX_RECEIPT) { Add-Content -LiteralPath \$env:WALLSTOP_UPDATE_SANDBOX_RECEIPT -Value \$MyInvocation.MyCommand.Name }
Write-Output ('sandbox-step-ok:' + \$MyInvocation.MyCommand.Name)
exit 0
"@
        foreach ($stubStepPath in @(
                (Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "Komorebi/StopKomorebi.ps1"),
                (Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "Scoop/ScoopUpdate.ps1"),
                (Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "WinGet/WinGetUpdate.ps1")
            )) {
            New-Utf8NoBomTextFile -Path $stubStepPath -Text $stubStepContent
        }

        # Single-quoted here-string: this text must reach disk verbatim, so no interpolation
        # besides the explicit placeholder replacement below.
        $pseudoHelpersContent = @'
function Test-IsWindowsPlatform {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}
function Test-IsMacOSPlatform {
    return $false
}
function Test-IsLinuxPlatform {
    return (-not (Test-IsWindowsPlatform))
}
function Resolve-PowerShellExecutablePath {
    return '<REALPWSH>'
}
'@
        New-Utf8NoBomTextFile -Path (
            Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "Utils/Common/CompatibilityHelpers.ps1"
        ) -Text ($pseudoHelpersContent.Replace("<REALPWSH>", [string]$script:realPowerShellExecutable))
    }

    AfterAll {
        if ($script:sandboxRoot -and (Test-Path -LiteralPath $script:sandboxRoot -PathType Container)) {
            Remove-Item -LiteralPath $script:sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "runs fully headless with no arguments and exits clean" {
        $receiptPath = Join-Path -Path $script:sandboxRoot -ChildPath "headless-receipt.txt"
        $previousReceiptValue = Get-Item -Path "env:WALLSTOP_UPDATE_SANDBOX_RECEIPT" -ErrorAction SilentlyContinue
        $env:WALLSTOP_UPDATE_SANDBOX_RECEIPT = $receiptPath
        try {
            $childOutput = @(& $script:realPowerShellExecutable -NoLogo -NoProfile -File (Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "Update.ps1") 2>&1)
        }
        finally {
            if ($null -ne $previousReceiptValue) {
                $env:WALLSTOP_UPDATE_SANDBOX_RECEIPT = [string]$previousReceiptValue.Value
            }
            else {
                Remove-Item -Path "env:WALLSTOP_UPDATE_SANDBOX_RECEIPT" -ErrorAction SilentlyContinue
            }
        }

        $childExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
        $childExitCode = if ($null -ne $childExitVariable) { [int]$childExitVariable } else { -1 }

        $childText = (($childOutput | ForEach-Object { [string]$_ }) -join "`n")

        $childExitContext = $childText.Substring([Math]::Max(0, $childText.Length - 400))

        $childExitCode | Should -Be 0 -Because ("sandbox child exit context: {0}" -f $childExitContext)
        $childText | Should -Match "UPDATE SUMMARY"
        $childText | Should -Match "Planned steps: 3"

        # On Windows the three sandbox stubs are platform-applicable and must have executed
        # exactly once each through the sandbox receipt; POSIX hosts skip them all by design.
        if (Test-IsWindowsPlatform) {
            @(Get-Content -LiteralPath $receiptPath).Count | Should -Be 3
        }
        else {
            (Test-Path -LiteralPath $receiptPath -PathType Leaf) | Should -BeFalse
        }
    }

    It "warns on -WithAdmin outside Windows and still completes headless" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "the Windows -WithAdmin branch spawns a UAC prompt; Windows behavior is pinned by the pure decision matrix."
            return
        }

        $childOutput = @(& $script:realPowerShellExecutable -NoLogo -NoProfile -File (Join-Path -Path $script:sandboxScriptsDirectory -ChildPath "Update.ps1") -WithAdmin 2>&1)
        $childExitVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
        $childExitCode = if ($null -ne $childExitVariable) { [int]$childExitVariable } else { -1 }

        $childText = (($childOutput | ForEach-Object { [string]$_ }) -join "`n")

        $childExitContext = $childText.Substring([Math]::Max(0, $childText.Length - 400))

        $childExitCode | Should -Be 0 -Because ("sandbox child exit context: {0}" -f $childExitContext)
        $childText | Should -Match "W_UPDATE_ELEVATION_UNSUPPORTED_PLATFORM"
        $childText | Should -Match "UPDATE SUMMARY"
        $childText | Should -Not -Match "INFO_UPDATE_ELEVATION_RELAY"
    }
}
