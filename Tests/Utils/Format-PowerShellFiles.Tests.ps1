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
}
