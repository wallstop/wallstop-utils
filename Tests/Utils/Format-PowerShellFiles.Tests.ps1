Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Describe "Format-PowerShellFiles idempotence" {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
        $script:formatterScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Format-PowerShellFiles.ps1"
        $script:utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    }

    BeforeEach {
        function Global:Invoke-Formatter {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ScriptDefinition,

                [Parameter(Mandatory = $true)]
                [string]$Settings
            )

            $null = $Settings
            return ($ScriptDefinition.TrimEnd() + "`n")
        }
    }

    AfterEach {
        Remove-Item -Path Function:Invoke-Formatter -ErrorAction SilentlyContinue
    }

    It "formats content once and is a no-op on a second run" {
        $samplePath = Join-Path -Path $TestDrive -ChildPath "sample.ps1"
        [System.IO.File]::WriteAllText($samplePath, "Write-Host 'hello'   `n", $script:utf8NoBom)

        Mock -CommandName Write-Host

        & $script:formatterScriptPath $samplePath
        $firstPassBytes = [System.IO.File]::ReadAllBytes($samplePath)

        & $script:formatterScriptPath $samplePath
        $secondPassBytes = [System.IO.File]::ReadAllBytes($samplePath)

        ([System.Convert]::ToBase64String($secondPassBytes)) | Should -Be ([System.Convert]::ToBase64String($firstPassBytes))
        Assert-MockCalled -CommandName Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like "Formatted *" }
        [System.IO.File]::ReadAllText($samplePath) | Should -Be "Write-Host 'hello'`n"
    }

    It "normalizes leading tab indentation when formatter returns space-indented output: <Name>" -TestCases @(
        @{
            Name            = "single leading tab"
            SourceContent   = "if (`$true) {`n`tWrite-Host 'hello'`n}`n"
            ExpectedSnippet = "    Write-Host 'hello'"
        }
        @{
            Name            = "double leading tabs"
            SourceContent   = "if (`$true) {`n`t`tWrite-Host 'hello'`n}`n"
            ExpectedSnippet = "        Write-Host 'hello'"
        }
    ) {
        param($Name, $SourceContent, $ExpectedSnippet)

        $samplePath = Join-Path -Path $TestDrive -ChildPath "tabs-$($Name -replace '\\s+', '-').ps1"
        [System.IO.File]::WriteAllText($samplePath, $SourceContent, $script:utf8NoBom)

        function Global:Invoke-Formatter {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ScriptDefinition,

                [Parameter(Mandatory = $true)]
                [string]$Settings
            )

            $null = $Settings
            return ($ScriptDefinition -replace "`t", '    ')
        }

        Mock -CommandName Write-Host

        & $script:formatterScriptPath $samplePath
        $result = [System.IO.File]::ReadAllText($samplePath)

        $result | Should -Not -Match "`t"
        $result | Should -Match ([regex]::Escape($ExpectedSnippet))
        Assert-MockCalled -CommandName Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like "Formatted *" }
    }

    It "fails fast with actionable diagnostics when formatter output still contains leading tabs: <Name>" -TestCases @(
        @{ Name = "single-line tab"; SourceContent = "`tWrite-Host 'tabbed'`n"; ExpectedLine = "1" }
        @{ Name = "double-tab line"; SourceContent = "`t`tWrite-Host 'tabbed'`n"; ExpectedLine = "1" }
    ) {
        param($Name, $SourceContent, $ExpectedLine)

        $samplePath = Join-Path -Path $TestDrive -ChildPath "tab-error-$($Name -replace '\\s+', '-').ps1"
        [System.IO.File]::WriteAllText($samplePath, $SourceContent, $script:utf8NoBom)

        function Global:Invoke-Formatter {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ScriptDefinition,

                [Parameter(Mandatory = $true)]
                [string]$Settings
            )

            $null = $Settings
            return $ScriptDefinition
        }

        {
            & $script:formatterScriptPath $samplePath
        } | Should -Throw -ExpectedMessage "*E_FORMATTER_TAB_INDENTATION_REMAINING*line(s): $ExpectedLine*"
    }

    It "fails fast when formatter returns invalid output: <Name>" -TestCases @(
        @{ Name = "null output"; InvalidOutput = $null }
        @{ Name = "empty output"; InvalidOutput = "" }
    ) {
        param($Name, $InvalidOutput)

        $samplePath = Join-Path -Path $TestDrive -ChildPath "invalid-output-$($Name -replace '\\s+', '-').ps1"
        [System.IO.File]::WriteAllText($samplePath, "Write-Host 'ok'`n", $script:utf8NoBom)

        function Global:Invoke-Formatter {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ScriptDefinition,

                [Parameter(Mandatory = $true)]
                [string]$Settings
            )

            $null = $ScriptDefinition
            $null = $Settings
            return $InvalidOutput
        }

        {
            & $script:formatterScriptPath $samplePath
        } | Should -Throw -ExpectedMessage "*E_FORMATTER_OUTPUT_INVALID*"
    }
}
