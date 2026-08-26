Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:runbookPath = Join-Path -Path $script:repoRoot -ChildPath "docs/operator-runbooks/backup-host-state.md"
    $script:profileRepairPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Powershell/Repair-PowerShellProfilePortability.ps1"
    $script:komorebiRepairPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Komorebi/Repair-KomorebiBackupSource.ps1"
    $script:tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-backup-remediation-tests-" + [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($script:tempRoot) | Out-Null

    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1")
    $script:pwshExecutable = Resolve-PowerShellExecutablePath

    function Invoke-RemediationScriptBounded {
        # Runs a remediation script in an isolated child pwsh with a bounded wait, avoiding both
        # the Start-Process exit-code population race, its unbounded -Wait hang risk, and the
        # -ArgumentList spaced-path mangling hazard (arguments go through
        # Set-PortableProcessArguments on a ProcessStartInfo instead).
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$ArgumentList,

            [Parameter(Mandatory = $false)]
            [int]$TimeoutSeconds = 60
        )

        $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = $script:pwshExecutable
        $processStartInfo.UseShellExecute = $false
        Set-PortableProcessArguments -StartInfo $processStartInfo -ArgumentList $ArgumentList

        $childProcess = [System.Diagnostics.Process]::Start($processStartInfo)
        $didExit = $childProcess.WaitForExit($TimeoutSeconds * 1000)
        if (-not $didExit) {
            $childProcess.Kill()
            throw "Remediation script did not exit within ${TimeoutSeconds}s: $($ArgumentList -join ' ')"
        }

        return $childProcess.ExitCode
    }
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

    It "replaces a drifted host profile from the validated repository source and preserves a timestamped backup" {
        . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/PSReadLineProfilePortabilityHelpers.ps1")

        $destination = Join-Path -Path $script:tempRoot -ChildPath "self-heal/Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
        $driftedContent = "Set-PSReadLineOption -PredictionSource History`nSet-PSReadLineOption -PredictionViewStyle InlineView`n"
        $destinationDirectory = [System.IO.Path]::GetDirectoryName($destination)
        [void][System.IO.Directory]::CreateDirectory($destinationDirectory)
        [System.IO.File]::WriteAllText($destination, $driftedContent, [System.Text.UTF8Encoding]::new($false))

        $repositorySource = Join-Path -Path $script:repoRoot -ChildPath "Config/Powershell/CurrentUserCurrentHost_Microsoft.PowerShell_profile.ps1"
        $repairResult = Restore-PowerShellProfileFromValidatedSource -ProfilePath $destination -RepositoryProfilePath $repositorySource

        $repairResult.Repaired | Should -BeTrue
        @(Get-PSReadLineProfilePortabilityViolation -Path $destination) | Should -HaveCount 0

        $backupFiles = @(Get-ChildItem -LiteralPath $destinationDirectory -Filter "*.pre-portability-repair-*.bak" -File)
        $backupFiles.Count | Should -Be 1
        $repairResult.BackupPath | Should -Be $backupFiles[0].FullName
        (Get-Content -LiteralPath $backupFiles[0].FullName -Raw) | Should -Be $driftedContent
    }

    It "fails closed when the repository repair source is itself non-portable" {
        . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/PSReadLineProfilePortabilityHelpers.ps1")

        $destination = Join-Path -Path $script:tempRoot -ChildPath "bad-source/profile.ps1"
        $originalDestinationContent = "# untouched destination`n"
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
        [System.IO.File]::WriteAllText($destination, $originalDestinationContent, [System.Text.UTF8Encoding]::new($false))
        $nonPortableSource = Join-Path -Path $script:tempRoot -ChildPath "bad-source/non-portable-repo-profile.ps1"
        [System.IO.File]::WriteAllText($nonPortableSource, "Set-PSReadLineOption -PredictionSource History`n", [System.Text.UTF8Encoding]::new($false))

        { Restore-PowerShellProfileFromValidatedSource -ProfilePath $destination -RepositoryProfilePath $nonPortableSource } |
            Should -Throw "E_PSREADLINE_PROFILE_REPAIR_SOURCE_NOT_PORTABLE*"
        (Get-Content -LiteralPath $destination -Raw) | Should -Be $originalDestinationContent
    }

    It "declines to repair a profile from itself instead of looping on an unfixable target" {
        . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/PSReadLineProfilePortabilityHelpers.ps1")

        $repositorySource = Join-Path -Path $script:repoRoot -ChildPath "Config/Powershell/CurrentUserCurrentHost_Microsoft.PowerShell_profile.ps1"
        $sourceContent = Get-Content -LiteralPath $repositorySource -Raw

        $repairResult = Restore-PowerShellProfileFromValidatedSource -ProfilePath $repositorySource -RepositoryProfilePath $repositorySource

        $repairResult.Repaired | Should -BeFalse
        (Get-Content -LiteralPath $repositorySource -Raw) | Should -Be $sourceContent
    }

    It "repairs a selected profile only when explicitly applied and preserves the old file" {
        $destination = Join-Path -Path $script:tempRoot -ChildPath "PowerShell/Microsoft.PowerShell_profile.ps1"
        $destinationDirectory = [System.IO.Path]::GetDirectoryName($destination)
        [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
        [System.IO.File]::WriteAllText($destination, "# old profile`n", [System.Text.UTF8Encoding]::new($false))

        $repairExitCode = Invoke-RemediationScriptBounded -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $script:profileRepairPath,
            "-ProfilePath", $destination, "-Apply"
        )
        $repairExitCode | Should -Be 0
        Test-Path -LiteralPath $destination -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $destinationDirectory -Filter "*.pre-portability-repair-*.bak" -File) | Should -HaveCount 1
        (Get-Content -LiteralPath $destination -Raw) | Should -Match "Parameters\.ContainsKey\('PredictionSource'\)"
    }

    It "repairs a selected Komorebi source into an explicit destination" {
        $destination = Join-Path -Path $script:tempRoot -ChildPath "komorebi-user"
        [System.IO.Directory]::CreateDirectory($destination) | Out-Null

        $komorebiExitCode = Invoke-RemediationScriptBounded -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $script:komorebiRepairPath,
            "-ProfileName", "default", "-UserProfileRoot", $destination, "-Apply"
        )
        $komorebiExitCode | Should -Be 0
        foreach ($fileName in @("applications.json", "komorebi.bar.json", "komorebi.json")) {
            Test-Path -LiteralPath (Join-Path -Path $destination -ChildPath $fileName) -PathType Leaf | Should -BeTrue
        }
    }
}
