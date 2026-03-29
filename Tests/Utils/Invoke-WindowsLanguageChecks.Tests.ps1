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

Describe "Convert-CapturedTextToLines" {
    It "normalizes captured text consistently: <Case>" -TestCases @(
        @{
            Case     = "empty text"
            Text     = ""
            Expected = @()
        },
        @{
            Case     = "single line with trailing newline"
            Text     = "ok`n"
            Expected = @("ok")
        },
        @{
            Case     = "multiline CRLF with trailing newline"
            Text     = "line1`r`nline2`r`n"
            Expected = @("line1", "line2")
        },
        @{
            Case     = "single line without newline"
            Text     = "no-newline"
            Expected = @("no-newline")
        }
    ) {
        param(
            [string]$Case,
            [string]$Text,
            [string[]]$Expected
        )

        $null = $Case
        $result = @(Convert-CapturedTextToLines -Text $Text)
        ($result -join "`n") | Should -Be ($Expected -join "`n")
    }
}

Describe "Invoke-AutoHotkeyCommand" {
    It "captures exit code and output deterministically: <Case>" -TestCases @(
        @{
            Case               = "stdout and zero exit"
            LinuxExecutable    = "pwsh"
            LinuxArguments     = @("-NoLogo", "-NoProfile", "-Command", "Write-Output 'ok-stdout'")
            WindowsExecutable  = "pwsh"
            WindowsArguments   = @("-NoLogo", "-NoProfile", "-Command", "Write-Output 'ok-stdout'")
            LinuxExitCode      = 0
            WindowsExitCode    = 0
            ExpectedOutputLike = "ok-stdout"
        },
        @{
            Case               = "stderr and nonzero exit"
            LinuxExecutable    = "pwsh"
            LinuxArguments     = @("-NoLogo", "-NoProfile", "-Command", "Write-Error 'problem-stderr'; exit 7")
            WindowsExecutable  = "pwsh"
            WindowsArguments   = @("-NoLogo", "-NoProfile", "-Command", "Write-Error 'problem-stderr'; exit 7")
            LinuxExitCode      = 7
            WindowsExitCode    = 7
            ExpectedOutputLike = "problem-stderr"
        },
        @{
            Case               = "stdout without trailing newline"
            LinuxExecutable    = "pwsh"
            LinuxArguments     = @("-NoLogo", "-NoProfile", "-Command", "[Console]::Out.Write('ok-no-newline')")
            WindowsExecutable  = "pwsh"
            WindowsArguments   = @("-NoLogo", "-NoProfile", "-Command", "[Console]::Out.Write('ok-no-newline')")
            LinuxExitCode      = 0
            WindowsExitCode    = 0
            ExpectedOutputLike = "ok-no-newline"
        },
        @{
            Case               = "large stderr stream remains deterministic"
            LinuxExecutable    = "pwsh"
            LinuxArguments     = @("-NoLogo", "-NoProfile", "-Command", '1..1500 | ForEach-Object { [Console]::Error.WriteLine("problem-stderr-$_") }; exit 9')
            WindowsExecutable  = "pwsh"
            WindowsArguments   = @("-NoLogo", "-NoProfile", "-Command", '1..1500 | ForEach-Object { [Console]::Error.WriteLine("problem-stderr-$_") }; exit 9')
            LinuxExitCode      = 9
            WindowsExitCode    = 9
            ExpectedOutputLike = "problem-stderr-750"
        }
    ) {
        param(
            [string]$Case,
            [string]$LinuxExecutable,
            [string[]]$LinuxArguments,
            [string]$WindowsExecutable,
            [string[]]$WindowsArguments,
            [int]$LinuxExitCode,
            [int]$WindowsExitCode,
            [string]$ExpectedOutputLike
        )

        $null = $Case
        $expectedExitCode = 0
        if ($IsWindows) {
            $result = Invoke-AutoHotkeyCommand -Executable $WindowsExecutable -Arguments $WindowsArguments
            $expectedExitCode = $WindowsExitCode
        }
        else {
            $result = Invoke-AutoHotkeyCommand -Executable $LinuxExecutable -Arguments $LinuxArguments
            $expectedExitCode = $LinuxExitCode
        }

        # Emit diagnostic context unconditionally so CI logs always contain enough info
        # to diagnose exit-code or output-capture regressions without re-running the build.
        $diagnostics = if ($null -ne $result.Diagnostics) {
            $result.Diagnostics | ConvertTo-Json -Compress -Depth 4
        }
        else {
            "(none)"
        }
        $outputLineCount = @($result.Output).Count
        $outputPreview = if ($outputLineCount -gt 6) {
            (@($result.Output[0..2]) + @("... ($outputLineCount total lines) ...") + @($result.Output[($outputLineCount - 2)..($outputLineCount - 1)])) -join "`n"
        }
        else {
            $result.Output -join "`n"
        }
        Write-Host "[Invoke-AutoHotkeyCommand diag] Case='$Case' ExitCode=$($result.ExitCode) ExpectedExitCode=$expectedExitCode OutputLines=$outputLineCount IsWindows=$IsWindows diagnostics=$diagnostics"
        Write-Host "[Invoke-AutoHotkeyCommand diag] OutputPreview:`n$outputPreview"

        $result.ExitCode | Should -Be $expectedExitCode -Because "Case='$Case' expected exit code $expectedExitCode but got $($result.ExitCode). diagnostics=$diagnostics"
        $outputText = ($result.Output -join " ")

        $outputText | Should -Match ([regex]::Escape($ExpectedOutputLike)) -Because "Case='$Case' should capture expected text. diagnostics=$diagnostics"

        $result.Diagnostics | Should -Not -BeNullOrEmpty -Because "capture diagnostics should always be present"
        $expectedCaptureMode = if ($IsWindows) { "start-process-redirect" } else { "dotnet-process" }
        $result.Diagnostics.CaptureMode | Should -Be $expectedCaptureMode
    }

    It "returns structured error output when the specified executable does not exist" {
        $result = Invoke-AutoHotkeyCommand -Executable "no-such-exe-$(New-Guid)" -Arguments @("--version")
        $result.ExitCode | Should -Be -1
        ($result.Output -join " ") | Should -Match 'E_AHK_PROCESS_EXECUTION_FAILED'
    }
}

Describe "Invoke-AutoHotkeyValidationCommand" {
    It "probes validation modes and returns expected status: <Case>" -TestCases @(
        @{
            Case              = "validate succeeds immediately"
            CommandResults    = @(
                [PSCustomObject]@{ ExitCode = 0; Output = @("ok") }
            )
            ExpectedStatus    = "ok"
            ExpectedMode      = "/validate"
            ExpectedCallCount = 1
        },
        @{
            Case              = "validate unsupported then iLib succeeds"
            CommandResults    = @(
                [PSCustomObject]@{ ExitCode = 2; Output = @("Unknown switch /validate") },
                [PSCustomObject]@{ ExitCode = 0; Output = @("ok") }
            )
            ExpectedStatus    = "ok"
            ExpectedMode      = "/iLib"
            ExpectedCallCount = 2
        },
        @{
            Case              = "both validation modes unsupported"
            CommandResults    = @(
                [PSCustomObject]@{ ExitCode = 2; Output = @("Unknown switch /validate") },
                [PSCustomObject]@{ ExitCode = 2; Output = @("Invalid command line option /iLib") }
            )
            ExpectedStatus    = "unsupported"
            ExpectedMode      = ""
            ExpectedCallCount = 2
        },
        @{
            Case              = "validate reports real script failure"
            CommandResults    = @(
                [PSCustomObject]@{ ExitCode = 1; Output = @("Error: Missing close-quote") }
            )
            ExpectedStatus    = "validation-failed"
            ExpectedMode      = "/validate"
            ExpectedCallCount = 1
        },
        @{
            # Regression: AHK v2 returns exit=-1 with no output when processing a v1 script.
            # This is ambiguous — must fall through to /iLib rather than reporting validation-failed.
            Case              = "validate returns exit=-1 with no output falls through to iLib success"
            CommandResults    = @(
                [PSCustomObject]@{ ExitCode = -1; Output = @() },
                [PSCustomObject]@{ ExitCode = 0; Output = @() }
            )
            ExpectedStatus    = "ok"
            ExpectedMode      = "/iLib"
            ExpectedCallCount = 2
        },
        @{
            # Both modes return exit=-1 with no output: should be "unsupported", not "validation-failed".
            Case              = "both modes return exit=-1 with no output yields unsupported"
            CommandResults    = @(
                [PSCustomObject]@{ ExitCode = -1; Output = @() },
                [PSCustomObject]@{ ExitCode = -1; Output = @() }
            )
            ExpectedStatus    = "unsupported"
            ExpectedMode      = ""
            ExpectedCallCount = 2
        },
        @{
            # Non-standard exit code but with actual diagnostic output → real failure.
            Case              = "non-standard exit code with error output is validation-failed"
            CommandResults    = @(
                [PSCustomObject]@{ ExitCode = 3; Output = @("Error at line 5: unexpected token") }
            )
            ExpectedStatus    = "validation-failed"
            ExpectedMode      = "/validate"
            ExpectedCallCount = 1
        },
        @{
            # Whitespace-only output is treated as no output — ambiguous, falls through.
            Case              = "whitespace-only output falls through to iLib"
            CommandResults    = @(
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
                ExitCode    = [int]$current.ExitCode
                Output      = @($current.Output)
                Diagnostics = [PSCustomObject]@{
                    CaptureMode         = "test-mock"
                    Executable          = "mock"
                    ArgumentCount       = 0
                    StdOutLineCount     = @($current.Output).Count
                    StdErrLineCount     = 0
                    TimeoutMilliseconds = 0
                    StdOutCaptureExists = $false
                    StdErrCaptureExists = $false
                }
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

    It "classifies no-output attempt collections correctly: <Case>" -TestCases @(
        @{
            Case     = "all attempts empty"
            Attempts = @(
                [PSCustomObject]@{ Mode = "/validate"; ExitCode = -1; Output = @() },
                [PSCustomObject]@{ Mode = "/iLib"; ExitCode = -1; Output = @("   ", "") }
            )
            Expected = $true
        },
        @{
            Case     = "one attempt has output"
            Attempts = @(
                [PSCustomObject]@{ Mode = "/validate"; ExitCode = -1; Output = @() },
                [PSCustomObject]@{ Mode = "/iLib"; ExitCode = 2; Output = @("Unknown switch /iLib") }
            )
            Expected = $false
        },
        @{
            Case     = "empty attempt list"
            Attempts = @()
            Expected = $false
        }
    ) {
        param(
            [string]$Case,
            [object[]]$Attempts,
            [bool]$Expected
        )

        $null = $Case
        (Test-AutoHotkeyAttemptsProducedNoOutput -Attempts $Attempts) | Should -Be $Expected
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

    It "adds explicit runtime/capture hint when all validation probes return no output in required mode" {
        $repoRoot = (Join-Path -Path $TestDrive -ChildPath "repo-required-no-output")
        $scriptsRoot = Join-Path -Path $repoRoot -ChildPath "Scripts/AutoHotKey"
        New-Item -Path $scriptsRoot -ItemType Directory -Force | Out-Null

        $fileA = Join-Path -Path $scriptsRoot -ChildPath "a.ahk"
        Set-Content -Path $fileA -Value "#Requires AutoHotkey v2" -NoNewline

        Mock -CommandName Get-AutoHotkeyExecutablePath -MockWith { "AutoHotkey64.exe" }
        Mock -CommandName Invoke-AutoHotkeyValidationCommand -MockWith {
            return [PSCustomObject]@{
                Status   = "unsupported"
                Mode     = ""
                Attempts = @(
                    [PSCustomObject]@{ Mode = "/validate"; ExitCode = -1; Output = @() },
                    [PSCustomObject]@{ Mode = "/iLib"; ExitCode = -1; Output = @("  ") }
                )
            }
        }

        {
            Test-AutoHotkeyScripts -RepoRoot $repoRoot -RequestedTargetFilePaths @($fileA) -RequireAutoHotkey
        } | Should -Throw "*Hint: all probe attempts returned no output*"

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
        }
        else {
            {
                Test-BatchScriptsStaticSmoke -RepoRoot $repoRoot -RequestedTargetFilePaths @($batchFilePath)
            } | Should -Not -Throw
        }
    }
}
