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
