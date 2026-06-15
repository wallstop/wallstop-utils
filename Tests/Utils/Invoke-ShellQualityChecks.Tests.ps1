Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:shellQualityScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1"
    . $script:shellQualityScriptPath -NoInvokeMain
    . (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/Common/CompatibilityHelpers.ps1")
}

Describe "Invoke-ShellQualityChecks platform resolution" {
    It "uses the pinned Windows x64 asset as the explicit Windows ARM64 fallback" {
        $manifest = [pscustomobject]@{
            tools = [pscustomobject]@{
                shfmt = [pscustomobject]@{
                    version = "3.13.0"
                    releaseTag = "v3.13.0"
                    repository = "mvdan/sh"
                    versionPattern = "v3.13.0"
                    executableBaseName = "shfmt"
                    assets = [pscustomobject]@{
                        "windows-x64" = [pscustomobject]@{
                            assetName = "shfmt_v3.13.0_windows_amd64.exe"
                            sha256 = "62241aaf6b0ca236f8625d8892784b73fa67ad40bc677a1ad1a64ae395f6a7d5"
                            kind = "executable"
                        }
                    }
                }
            }
        }

        $assetSpec = Resolve-ShellQualityAssetSpec -Manifest $manifest -ToolName shfmt -OperatingSystem windows -Architecture arm64

        $assetSpec.AssetKey | Should -Be "windows-x64"
        $assetSpec.RequestedAssetKey | Should -Be "windows-arm64"
        $assetSpec.ExecutableName | Should -Be "shfmt.exe"
        $assetSpec.FallbackReason | Should -Match "Windows ARM64"
        $assetSpec.DownloadUrl | Should -Be "https://github.com/mvdan/sh/releases/download/v3.13.0/shfmt_v3.13.0_windows_amd64.exe"
    }

    It "fails with a stable diagnostic for unsupported platform assets" {
        $manifest = [pscustomobject]@{
            tools = [pscustomobject]@{
                shellcheck = [pscustomobject]@{
                    version = "0.11.0"
                    releaseTag = "v0.11.0"
                    repository = "koalaman/shellcheck"
                    versionPattern = "version:\\s*0\\.11\\.0"
                    executableBaseName = "shellcheck"
                    assets = [pscustomobject]@{
                        "linux-x64" = [pscustomobject]@{
                            assetName = "shellcheck-v0.11.0.linux.x86_64.tar.gz"
                            sha256 = "b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6"
                            kind = "tar.gz"
                        }
                    }
                }
            }
        }

        { Resolve-ShellQualityAssetSpec -Manifest $manifest -ToolName shellcheck -OperatingSystem darwin -Architecture arm64 } |
            Should -Throw -ExpectedMessage "*E_SHELL_TOOL_PLATFORM_UNSUPPORTED*"
    }
}

Describe "Invoke-ShellQualityChecks target scoping" {
    It "does not widen an empty or missing target list" {
        $targets = @(Resolve-ShellQualityTargetFiles -RepositoryRoot $script:repoRoot -InputFiles @("does-not-exist.sh", ""))
        $targets.Count | Should -Be 0
    }

    It "rejects targets outside the repository" {
        $outsidePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "outside-shell-quality.sh"
        { Resolve-ShellQualityTargetFiles -RepositoryRoot $script:repoRoot -InputFiles @($outsidePath) } |
            Should -Throw -ExpectedMessage "*E_SHELL_QUALITY_TARGET_OUTSIDE_REPOSITORY*"
    }

    It "filters resolved targets to the managed shell quality scope" {
        $shellPath = Join-Path -Path $script:repoRoot -ChildPath ".devcontainer/post-create.sh"
        $nonShellPath = Join-Path -Path $script:repoRoot -ChildPath "README.md"

        $targets = @(Select-ShellQualityTargetFiles -RepositoryRoot $script:repoRoot -Files @($shellPath, $nonShellPath))

        $targets.Count | Should -Be 1
        (ConvertTo-ShellQualityRelativePath -RepositoryRoot $script:repoRoot -Path $targets[0]) | Should -Be ".devcontainer/post-create.sh"
    }

    It "skips zero selected targets before reading the manifest or resolving tools" {
        Mock Read-ShellQualityToolManifest { throw "manifest should not be read for zero-target checks" }
        Mock Resolve-ShellQualityToolExecutable { throw "tool resolution should not run for zero-target checks" }

        { Invoke-ShellQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @("does-not-exist.sh") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-ShellQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-ShellQualityToolExecutable -Times 0 -Exactly
    }

    It "skips existing non-shell targets before reading the manifest or resolving tools" {
        Mock Read-ShellQualityToolManifest { throw "manifest should not be read for non-shell targets" }
        Mock Resolve-ShellQualityToolExecutable { throw "tool resolution should not run for non-shell targets" }
        Mock Invoke-ShfmtQualityCheck { throw "shfmt should not run for non-shell targets" }
        Mock Invoke-ShellCheckQualityCheck { throw "shellcheck should not run for non-shell targets" }

        { Invoke-ShellQualityChecksMain -SelectedTool shfmt -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @("README.md") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-ShellQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-ShellQualityToolExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Invoke-ShfmtQualityCheck -Times 0 -Exactly
        Assert-MockCalled -CommandName Invoke-ShellCheckQualityCheck -Times 0 -Exactly
    }

    It "still resolves all requested tools in EnsureOnly mode" {
        $script:resolvedShellEnsureTools = New-Object System.Collections.Generic.List[string]

        Mock Read-ShellQualityToolManifest {
            return [pscustomobject]@{ tools = [pscustomobject]@{} }
        }
        Mock Resolve-ShellQualityToolExecutable {
            param($Manifest, $ToolName, $RepositoryRoot)
            $script:resolvedShellEnsureTools.Add($ToolName) | Out-Null
            return "/tmp/$ToolName"
        }

        Invoke-ShellQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$true -InputFiles @()

        @($script:resolvedShellEnsureTools.ToArray()) | Should -Be @("shfmt", "shellcheck")
    }
}

Describe "Invoke-ShellQualityChecks bounded process execution" {
    It "kills a long-running child process when the timeout elapses" {
        $pwshPath = $null
        try {
            $pwshPath = Resolve-PowerShellExecutablePath
        }
        catch {
            $pwshPath = $null
        }

        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            try {
                $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            }
            catch {
                $pwshPath = $null
            }
        }

        if ([string]::IsNullOrWhiteSpace($pwshPath) -or -not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
            Set-ItResult -Skipped -Because "pwsh executable could not be resolved on this runner."
            return
        }

        $elapsed = Measure-Command {
            { Invoke-QualityToolingCapturedProcess -Context $script:ShellQualityContext -FilePath $pwshPath -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -WorkingDirectory $script:repoRoot -TimeoutSeconds 2 } |
                Should -Throw -ExpectedMessage "*E_SHELL_TOOL_PROCESS_TIMEOUT*"
        }

        $elapsed.TotalSeconds | Should -BeLessThan 25
    }
}

Describe "Invoke-ShellQualityChecks archive path safety" {
    It "accepts ordinary relative archive entries" {
        Test-ShellQualityArchiveEntryPath -EntryPath "shellcheck-v0.11.0/shellcheck" | Should -BeTrue
    }

    It "rejects path traversal and absolute archive entries" {
        Test-ShellQualityArchiveEntryPath -EntryPath "../shellcheck" | Should -BeFalse
        Test-ShellQualityArchiveEntryPath -EntryPath "/tmp/shellcheck" | Should -BeFalse
        Test-ShellQualityArchiveEntryPath -EntryPath "shellcheck/../../bad" | Should -BeFalse
        Test-ShellQualityArchiveEntryPath -EntryPath "C:/tmp/shellcheck.exe" | Should -BeFalse
        Test-ShellQualityArchiveEntryPath -EntryPath "C:\tmp\shellcheck.exe" | Should -BeFalse
        Test-ShellQualityArchiveEntryPath -EntryPath "C:shellcheck.exe" | Should -BeFalse
        Test-ShellQualityArchiveEntryPath -EntryPath "shellcheck/C:shellcheck.exe" | Should -BeFalse
    }

    It "detects symlink-like zip entries from external attributes" {
        Add-Type -AssemblyName System.IO.Compression
        $memoryStream = [System.IO.MemoryStream]::new()
        try {
            $zipArchive = [System.IO.Compression.ZipArchive]::new($memoryStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                $entry = $zipArchive.CreateEntry("shellcheck")
                $entry.ExternalAttributes = 0xA000 -shl 16
                Test-ShellQualityZipEntryIsLinkLike -Entry $entry | Should -BeTrue
            }
            finally {
                $zipArchive.Dispose()
            }
        }
        finally {
            $memoryStream.Dispose()
        }
    }

    It "rejects tar symlink and hardlink metadata lines" {
        Test-ShellQualityTarMetadataLineSafe -MetadataLine '-rwxr-xr-x 0/0 1 2026-01-01 00:00 shellcheck' | Should -BeTrue
        Test-ShellQualityTarMetadataLineSafe -MetadataLine 'drwxr-xr-x 0/0 0 2026-01-01 00:00 shellcheck-v0.11.0/' | Should -BeTrue
        Test-ShellQualityTarMetadataLineSafe -MetadataLine 'lrwxrwxrwx 0/0 0 2026-01-01 00:00 shellcheck -> /tmp/shellcheck' | Should -BeFalse
        Test-ShellQualityTarMetadataLineSafe -MetadataLine 'hrwxr-xr-x 0/0 0 2026-01-01 00:00 shellcheck link to shellcheck-real' | Should -BeFalse
        Test-ShellQualityTarMetadataLineSafe -MetadataLine 'crw-rw-rw- 0/0 0 2026-01-01 00:00 shellcheck-device' | Should -BeFalse
        Test-ShellQualityTarMetadataLineSafe -MetadataLine 'prw-r--r-- 0/0 0 2026-01-01 00:00 shellcheck-fifo' | Should -BeFalse
    }

    It "rejects extracted link-like executables before copying" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "Windows symlink creation requires host-specific privileges."
            return
        }

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("shell-quality-link-test-{0}" -f [guid]::NewGuid().ToString("N"))
        $extractRoot = Join-Path -Path $tempRoot -ChildPath "extract"
        $binRoot = Join-Path -Path $tempRoot -ChildPath "bin"

        try {
            New-Item -Path $extractRoot -ItemType Directory -Force | Out-Null
            $realExecutable = Join-Path -Path $extractRoot -ChildPath "shellcheck-real"
            [System.IO.File]::WriteAllText($realExecutable, "#!/bin/sh`n", [System.Text.UTF8Encoding]::new($false))
            $linkPath = Join-Path -Path $extractRoot -ChildPath "shellcheck"

            try {
                New-Item -ItemType SymbolicLink -Path $linkPath -Target $realExecutable -ErrorAction Stop | Out-Null
            }
            catch {
                Set-ItResult -Skipped -Because "This platform did not allow symlink creation for test setup: $($_.Exception.Message)"
                return
            }

            $assetSpec = [pscustomobject]@{
                AssetName = "shellcheck-test.tar.gz"
                ExecutableName = "shellcheck"
            }

            { Copy-ShellQualityExecutableFromArchive -ExtractRoot $extractRoot -BinRoot $binRoot -AssetSpec $assetSpec } |
                Should -Throw -ExpectedMessage "*E_SHELL_TOOL_ARCHIVE_UNSAFE*"
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
