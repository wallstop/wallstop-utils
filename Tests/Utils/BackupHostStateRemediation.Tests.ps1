Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:runbookPath = Join-Path -Path $script:repoRoot -ChildPath "docs/operator-runbooks/backup-host-state.md"
    $script:profileRepairPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Powershell/Repair-PowerShellProfilePortability.ps1"
    $script:komorebiRepairPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Komorebi/Repair-KomorebiBackupSource.ps1"
    $script:tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-backup-remediation-tests-" + [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($script:tempRoot) | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:tempRoot -PathType Container) {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Backup host-state remediation" {
    It "documents explicit, non-bypassing recovery commands" {
        $content = (Get-Content -LiteralPath $script:runbookPath -Raw) -replace "`r", ""

        $content | Should -Match "Repair-PowerShellProfilePortability\.ps1"
        $content | Should -Match "Repair-KomorebiBackupSource\.ps1"
        $content | Should -Match "-Apply"
        $content | Should -Match "timestamped copy"
        $content | Should -Match "must not silently substitute"
        $content | Should -Not -Match "git\s+commit\s+--no-verify"
    }

    It "links both backup failures to the operator runbook and remediation scripts" {
        $powershellBackup = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Powershell/PowershellBackup.ps1") -Raw
        $komorebiHelpers = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Komorebi/KomorebiProfileHelpers.ps1") -Raw

        $powershellBackup | Should -Match "https://github\.com/wallstop/wallstop-utils/blob/main/docs/operator-runbooks/backup-host-state\.md"
        $powershellBackup | Should -Match "Repair-PowerShellProfilePortability\.ps1\s+-ProfilePath\s+'\{1\}'\s+-Apply"
        $komorebiHelpers | Should -Match "https://github\.com/wallstop/wallstop-utils/blob/main/docs/operator-runbooks/backup-host-state\.md"
        $komorebiHelpers | Should -Match "Repair-KomorebiBackupSource\.ps1\s+-ProfileName"
    }

    It "parses remediation scripts without errors" {
        foreach ($path in @($script:profileRepairPath, $script:komorebiRepairPath)) {
            $tokens = $null
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
            $parseErrors.Count | Should -Be 0 -Because $path
        }
    }

    It "repairs a selected profile only when explicitly applied and preserves the old file" {
        $destination = Join-Path -Path $script:tempRoot -ChildPath "PowerShell/Microsoft.PowerShell_profile.ps1"
        $destinationDirectory = [System.IO.Path]::GetDirectoryName($destination)
        [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
        [System.IO.File]::WriteAllText($destination, "# old profile`n", [System.Text.UTF8Encoding]::new($false))

        $pwshPath = if (Test-Path -LiteralPath "/usr/bin/pwsh" -PathType Leaf) { "/usr/bin/pwsh" } else { "pwsh" }
        $childProcess = Start-Process -FilePath $pwshPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $script:profileRepairPath,
            "-ProfilePath", $destination, "-Apply"
        ) -Wait -PassThru
        $childProcess.ExitCode | Should -Be 0
        Test-Path -LiteralPath $destination -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $destinationDirectory -Filter "*.pre-portability-repair-*.bak" -File) | Should -HaveCount 1
        (Get-Content -LiteralPath $destination -Raw) | Should -Match "Parameters\.ContainsKey\('PredictionSource'\)"
    }

    It "repairs a selected Komorebi source into an explicit destination" {
        $destination = Join-Path -Path $script:tempRoot -ChildPath "komorebi-user"
        [System.IO.Directory]::CreateDirectory($destination) | Out-Null

        $pwshPath = if (Test-Path -LiteralPath "/usr/bin/pwsh" -PathType Leaf) { "/usr/bin/pwsh" } else { "pwsh" }
        $childProcess = Start-Process -FilePath $pwshPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $script:komorebiRepairPath,
            "-ProfileName", "default", "-UserProfileRoot", $destination, "-Apply"
        ) -Wait -PassThru
        $childProcess.ExitCode | Should -Be 0
        foreach ($fileName in @("applications.json", "komorebi.bar.json", "komorebi.json")) {
            Test-Path -LiteralPath (Join-Path -Path $destination -ChildPath $fileName) -PathType Leaf | Should -BeTrue
        }
    }
}
