Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1")
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/PreCommitCliHelpers.ps1")
}

Describe "Windows PowerShell 5.1 runtime smoke" {
    BeforeEach {
        if ($PSVersionTable.PSEdition -ne "Desktop") {
            Set-ItResult -Skipped -Because "Windows PowerShell 5.1 runtime smoke runs only under Desktop edition."
            return
        }
    }

    It "resolves platform helpers without undefined PowerShell 7 automatic variables" {
        { Test-IsWindowsPlatform } | Should -Not -Throw
        { Test-IsMacOSPlatform } | Should -Not -Throw
        { Test-IsLinuxPlatform } | Should -Not -Throw
        Test-IsWindowsPlatform | Should -BeTrue
    }

    It "keeps JSON singleton arrays parseable on Windows PowerShell 5.1" {
        $json = ConvertTo-JsonArrayCompat -InputObject ([pscustomobject]@{ name = "value" })
        $json.TrimStart() | Should -Match '^\['

        $records = @(ConvertFrom-JsonCompat -InputObject $json)
        $records.Count | Should -Be 1
        $records[0].name | Should -Be "value"
    }

    It "uses portable process argument construction under Desktop edition" {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()

        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("alpha", "with space", "brace{0}")

        $startInfo.Arguments | Should -Match "alpha"
        $startInfo.Arguments | Should -Match '"with space"'
        $startInfo.Arguments | Should -Match 'brace\{0\}'
    }

    It "uses the Windows pre-commit executable name for managed uv state" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        $state = Get-PreCommitManagedUvState -RepositoryRoot $repoRoot

        Split-Path -Path $state.PreCommitExecutable -Leaf | Should -Be "pre-commit.exe"
    }
}
