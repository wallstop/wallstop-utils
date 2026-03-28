Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1") -NoInvokeMain
}

Describe "Test-OutputLooksLikeUnsupportedAhkSwitch" {
    It "classifies unsupported-switch output: <Case>" -TestCases @(
        @{
            Case     = "unknown switch wording"
            Output   = @("Error: Unknown switch: /validate")
            Expected = $true
        },
        @{
            Case     = "invalid parameter wording"
            Output   = @("Invalid command line parameter '/iLib'")
            Expected = $true
        },
        @{
            Case     = "runtime syntax error wording"
            Output   = @("Error: Missing '}'", "Line Text: MsgBox('x'")
            Expected = $false
        },
        @{
            Case     = "invalid argument text without switch name"
            Output   = @("Error: invalid argument near line 5")
            Expected = $false
        },
        @{
            Case     = "empty output"
            Output   = @()
            Expected = $false
        }
    ) {
        param(
            [string]$Case,
            [string[]]$Output,
            [bool]$Expected
        )

        $null = $Case
        (Test-OutputLooksLikeUnsupportedAhkSwitch -Output $Output) | Should -Be $Expected
    }
}

Describe "Test-IsAutoHotkeyV1Script" {
    It "detects v1 syntax markers correctly: <Case>" -TestCases @(
        @{
            Case     = "#NoEnv directive"
            Content  = "#NoEnv`nSendMode Input"
            Expected = $true
        },
        @{
            Case     = "#Persistent directive"
            Content  = "#Persistent`nSetTimer, Label, 100"
            Expected = $true
        },
        @{
            Case     = "comma-syntax SetTimer"
            Content  = "SetTimer, WatchWindows, 1000"
            Expected = $true
        },
        @{
            Case     = "variable-percent SetWorkingDir"
            Content  = "SetWorkingDir %A_ScriptDir%"
            Expected = $true
        },
        @{
            Case     = "comma-syntax CoordMode"
            Content  = "CoordMode, Mouse, Screen"
            Expected = $true
        },
        @{
            Case     = "comma-syntax WinGet"
            Content  = "WinGet, activeWin, ID, A"
            Expected = $true
        },
        @{
            Case     = "comma-syntax WinGetTitle"
            Content  = "WinGetTitle, winTitle, ahk_id %hwnd%"
            Expected = $true
        },
        @{
            Case     = "comma-syntax MouseMove"
            Content  = "MouseMove, %x%, %y%, 0"
            Expected = $true
        },
        @{
            Case     = "VarSetCapacity call"
            Content  = "VarSetCapacity(rect, 16, 0)"
            Expected = $true
        },
        @{
            Case     = "IfWinExist command"
            Content  = "IfWinExist, ahk_exe Discord.exe"
            Expected = $true
        },
        @{
            Case     = "clean v2 script with Requires"
            Content  = "#Requires AutoHotkey v2.0`nSetWorkingDir(A_ScriptDir)"
            Expected = $false
        },
        @{
            Case     = "clean v2 SetTimer function call"
            Content  = "SetTimer(MyFunc, 100)"
            Expected = $false
        },
        @{
            Case     = "empty script"
            Content  = ""
            Expected = $false
        }
    ) {
        param(
            [string]$Case,
            [string]$Content,
            [bool]$Expected
        )

        $null = $Case
        (Test-IsAutoHotkeyV1Script -Content $Content) | Should -Be $Expected
    }
}

Describe "Invoke-AutoHotkeyCommand" {
    It "captures exit code from a native command without throwing under strict mode: <Case>" -TestCases @(
        @{
            Case     = "nonzero exit code is captured"
            ExitCode = 5
        },
        @{
            Case     = "zero exit code is captured"
            ExitCode = 0
        }
    ) {
        param([string]$Case, [int]$ExitCode)

        $null = $Case
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue

        if ($IsWindows) {
            $result = Invoke-AutoHotkeyCommand -Executable "cmd.exe" -Arguments @("/c", "exit $ExitCode")
        } else {
            $result = Invoke-AutoHotkeyCommand -Executable "sh" -Arguments @("-c", "exit $ExitCode")
        }
        $result.ExitCode | Should -Be $ExitCode
    }

    It "throws when the specified executable does not exist" {
        { Invoke-AutoHotkeyCommand -Executable "no-such-exe-$(New-Guid)" -Arguments @() } | Should -Throw
    }

    It "Get-Variable pattern does not throw when LASTEXITCODE is unset (anti-regression proof)" {
        # Directly proves why Get-Variable is used instead of bare $LASTEXITCODE or $global:LASTEXITCODE.
        # Both bare and $global: forms throw under Set-StrictMode -Version Latest in a fresh session
        # where no native command has run. Get-Variable with SilentlyContinue is the only safe pattern.
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue

        # New code pattern: Get-Variable does not throw even when the variable is absent.
        $getVarThrew = $false
        $getVarResult = $null
        try {
            $getVarResult = Get-Variable -Name 'LASTEXITCODE' -ValueOnly -ErrorAction SilentlyContinue
        } catch {
            $getVarThrew = $true
        }
        $getVarThrew | Should -Be $false -Because 'Get-Variable SilentlyContinue must return $null rather than throw'
        $getVarResult | Should -BeNullOrEmpty

        # Both bare $LASTEXITCODE and the $global: qualifier throw under strict mode when unset.
        $bareReadThrew = $false
        try {
            $null = $LASTEXITCODE
        } catch {
            $bareReadThrew = $true
        }
        $bareReadThrew | Should -Be $true -Because 'bare $LASTEXITCODE throws under Set-StrictMode -Version Latest when never set'

        $globalReadThrew = $false
        try {
            $null = $global:LASTEXITCODE
        } catch {
            $globalReadThrew = $true
        }
        $globalReadThrew | Should -Be $true -Because '$global:LASTEXITCODE also throws under Set-StrictMode -Version Latest when never set'
    }
}

Describe "Invoke-AutoHotkeyValidationCommand" {
    It "probes validation modes and returns expected status: <Case>" -TestCases @(
        @{
            Case = "validate succeeds immediately"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = 0; Output = @("ok") }
            )
            ExpectedStatus    = "ok"
            ExpectedMode      = "/validate"
            ExpectedCallCount = 1
        },
        @{
            Case = "validate unsupported then iLib succeeds"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = 2; Output = @("Unknown switch /validate") },
                [PSCustomObject]@{ ExitCode = 0; Output = @("ok") }
            )
            ExpectedStatus    = "ok"
            ExpectedMode      = "/iLib"
            ExpectedCallCount = 2
        },
        @{
            Case = "both validation modes unsupported"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = 2; Output = @("Unknown switch /validate") },
                [PSCustomObject]@{ ExitCode = 2; Output = @("Invalid command line option /iLib") }
            )
            ExpectedStatus    = "unsupported"
            ExpectedMode      = ""
            ExpectedCallCount = 2
        },
        @{
            Case = "validate reports real script failure"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = 1; Output = @("Error: Missing close-quote") }
            )
            ExpectedStatus    = "validation-failed"
            ExpectedMode      = "/validate"
            ExpectedCallCount = 1
        },
        @{
            # Regression: AHK v2 returns exit=-1 with no output when processing a v1 script.
            # This is ambiguous — must fall through to /iLib rather than reporting validation-failed.
            Case = "validate returns exit=-1 with no output falls through to iLib success"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = -1; Output = @() },
                [PSCustomObject]@{ ExitCode = 0; Output = @() }
            )
            ExpectedStatus    = "ok"
            ExpectedMode      = "/iLib"
            ExpectedCallCount = 2
        },
        @{
            # Both modes return exit=-1 with no output: should be "unsupported", not "validation-failed".
            Case = "both modes return exit=-1 with no output yields unsupported"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = -1; Output = @() },
                [PSCustomObject]@{ ExitCode = -1; Output = @() }
            )
            ExpectedStatus    = "unsupported"
            ExpectedMode      = ""
            ExpectedCallCount = 2
        },
        @{
            # Non-standard exit code but with actual diagnostic output → real failure.
            Case = "non-standard exit code with error output is validation-failed"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = 3; Output = @("Error at line 5: unexpected token") }
            )
            ExpectedStatus    = "validation-failed"
            ExpectedMode      = "/validate"
            ExpectedCallCount = 1
        },
        @{
            # Whitespace-only output is treated as no output — ambiguous, falls through.
            Case = "whitespace-only output falls through to iLib"
            CommandResults = @(
                [PSCustomObject]@{ ExitCode = 2; Output = @("   ", "") },
                [PSCustomObject]@{ ExitCode = 0; Output = @() }
            )
            ExpectedStatus    = "ok"
            ExpectedMode      = "/iLib"
            ExpectedCallCount = 2
        }
    ) {
        param(
            [string]$Case,
            [object[]]$CommandResults,
            [string]$ExpectedStatus,
            [string]$ExpectedMode,
            [int]$ExpectedCallCount
        )

        $null = $Case
        $script:commandCallIndex = 0

        Mock -CommandName Invoke-AutoHotkeyCommand -MockWith {
            if ($script:commandCallIndex -ge $CommandResults.Count) {
                throw "Test setup error: received more command invocations than configured."
            }

            $current = $CommandResults[$script:commandCallIndex]
            $script:commandCallIndex += 1
            return [PSCustomObject]@{
                ExitCode = [int]$current.ExitCode
                Output   = @($current.Output)
            }
        }

        $result = Invoke-AutoHotkeyValidationCommand -Executable "AutoHotkey64.exe" -ScriptPath "C:\repo\test.ahk"

        $result.Status | Should -Be $ExpectedStatus
        $result.Mode | Should -Be $ExpectedMode
        @($result.Attempts).Count | Should -Be $ExpectedCallCount
        Assert-MockCalled -CommandName Invoke-AutoHotkeyCommand -Times $ExpectedCallCount -Exactly
    }
}

Describe "Diagnostic helpers" {
    It "renders attempt diagnostics with mode and exit code" {
        $attempts = @(
            [PSCustomObject]@{
                Mode     = "/validate"
                ExitCode = 3
                Output   = @("Unknown switch /validate")
            },
            [PSCustomObject]@{
                Mode     = "/iLib"
                ExitCode = 1
                Output   = @("Error: Missing close-brace")
            }
        )

        $diagnostics = Get-AutoHotkeyAttemptDiagnostics -Attempts $attempts
        $diagnostics | Should -Match "/validate: exit=3"
        $diagnostics | Should -Match "/iLib: exit=1"
        $diagnostics | Should -Match "Unknown switch /validate"
    }

    It "truncates long output previews" {
        $veryLong = @("x" * 400)
        $preview = Get-OutputPreview -Output $veryLong -MaxLength 40

        $preview.Length | Should -BeGreaterThan 40
        $preview | Should -Match "\.\.\.$"
    }
}

Describe "Test-AutoHotkeyScripts control flow" {
    It "preserves collected validation failures when a later file reports unsupported mode" {
        $repoRoot = (Join-Path -Path $TestDrive -ChildPath "repo")
        $scriptsRoot = Join-Path -Path $repoRoot -ChildPath "Scripts/AutoHotKey"
        New-Item -Path $scriptsRoot -ItemType Directory -Force | Out-Null

        $fileA = Join-Path -Path $scriptsRoot -ChildPath "a.ahk"
        $fileB = Join-Path -Path $scriptsRoot -ChildPath "b.ahk"
        Set-Content -Path $fileA -Value "#Requires AutoHotkey v2" -NoNewline
        Set-Content -Path $fileB -Value "#Requires AutoHotkey v2" -NoNewline

        $callIndex = 0
        Mock -CommandName Get-AutoHotkeyExecutablePath -MockWith { "AutoHotkey64.exe" }
        Mock -CommandName Invoke-AutoHotkeyValidationCommand -MockWith {
            $callIndex += 1
            if ($callIndex -eq 1) {
                return [PSCustomObject]@{
                    Status   = "validation-failed"
                    Mode     = "/validate"
                    Attempts = @([PSCustomObject]@{ Mode = "/validate"; ExitCode = 1; Output = @("syntax error") })
                }
            }

            return [PSCustomObject]@{
                Status   = "unsupported"
                Mode     = ""
                Attempts = @([PSCustomObject]@{ Mode = "/validate"; ExitCode = 2; Output = @("Unknown switch /validate") })
            }
        }

        {
            Test-AutoHotkeyScripts -RepoRoot $repoRoot -RequestedTargetFilePaths @($fileA, $fileB)
        } | Should -Throw "*E_AHK_VALIDATION_FAILED*"

        Assert-MockCalled -CommandName Invoke-AutoHotkeyValidationCommand -Times 2 -Exactly
    }

    It "fails immediately with E_AHK_VALIDATE_UNAVAILABLE in required mode" {
        $repoRoot = (Join-Path -Path $TestDrive -ChildPath "repo-required")
        $scriptsRoot = Join-Path -Path $repoRoot -ChildPath "Scripts/AutoHotKey"
        New-Item -Path $scriptsRoot -ItemType Directory -Force | Out-Null

        $fileA = Join-Path -Path $scriptsRoot -ChildPath "a.ahk"
        Set-Content -Path $fileA -Value "#Requires AutoHotkey v2" -NoNewline

        Mock -CommandName Get-AutoHotkeyExecutablePath -MockWith { "AutoHotkey64.exe" }
        Mock -CommandName Invoke-AutoHotkeyValidationCommand -MockWith {
            return [PSCustomObject]@{
                Status   = "unsupported"
                Mode     = ""
                Attempts = @([PSCustomObject]@{ Mode = "/validate"; ExitCode = 2; Output = @("Unknown switch /validate") })
            }
        }

        {
            Test-AutoHotkeyScripts -RepoRoot $repoRoot -RequestedTargetFilePaths @($fileA) -RequireAutoHotkey
        } | Should -Throw "*E_AHK_VALIDATE_UNAVAILABLE*"

        Assert-MockCalled -CommandName Invoke-AutoHotkeyValidationCommand -Times 1 -Exactly
    }
}

Describe "Test-BatchScriptsStaticSmoke" {
    It "handles single-line batch files correctly: <Case>" -TestCases @(
        @{
            Case         = "clean single-line batch file passes"
            Content      = "echo hello"
            ExpectThrow  = $false
            ErrorPattern = ""
        },
        @{
            Case         = "single-line trailing whitespace fails"
            Content      = "echo hello   "
            ExpectThrow  = $true
            ErrorPattern = "*trailing whitespace*"
        },
        @{
            Case         = "single-line unbalanced parenthesis fails"
            Content      = "set X=(unclosed"
            ExpectThrow  = $true
            ErrorPattern = "*unbalanced parentheses at end-of-file*"
        },
        @{
            Case         = "single-line merge marker fails"
            Content      = "<<<<<<< HEAD"
            ExpectThrow  = $true
            ErrorPattern = "*unresolved merge marker*"
        }
    ) {
        param(
            [string]$Case,
            [string]$Content,
            [bool]$ExpectThrow,
            [string]$ErrorPattern
        )

        $null = $Case
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString())
        $scriptsRoot = Join-Path -Path $repoRoot -ChildPath "Scripts"
        New-Item -Path $scriptsRoot -ItemType Directory -Force | Out-Null

        $batchFilePath = Join-Path -Path $scriptsRoot -ChildPath "sample.bat"
        Set-Content -Path $batchFilePath -Value $Content -NoNewline

        if ($ExpectThrow) {
            {
                Test-BatchScriptsStaticSmoke -RepoRoot $repoRoot -RequestedTargetFilePaths @($batchFilePath)
            } | Should -Throw $ErrorPattern
        } else {
            {
                Test-BatchScriptsStaticSmoke -RepoRoot $repoRoot -RequestedTargetFilePaths @($batchFilePath)
            } | Should -Not -Throw
        }
    }
}
