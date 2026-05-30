Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:nativeQualityScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1"
    . $script:nativeQualityScriptPath -NoInvokeMain
    . (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/Common/CompatibilityHelpers.ps1")
}

Describe "Invoke-NativeQualityChecks platform resolution" {
    It "uses the pinned Windows x64 StyLua asset as the explicit Windows ARM64 fallback" {
        $manifest = Read-NativeQualityToolManifest

        $assetSpec = Resolve-NativeQualityAssetSpec -Manifest $manifest -ToolName stylua -OperatingSystem windows -Architecture arm64

        $assetSpec.AssetKey | Should -Be "windows-x64"
        $assetSpec.RequestedAssetKey | Should -Be "windows-arm64"
        $assetSpec.ExecutableName | Should -Be "stylua.exe"
        $assetSpec.FallbackReason | Should -Match "Windows ARM64"
        $assetSpec.DownloadUrl | Should -Be "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.5.2/stylua-windows-x86_64.zip"
    }

    It "uses the native Windows ARM64 actionlint asset when upstream publishes one" {
        $manifest = Read-NativeQualityToolManifest

        $assetSpec = Resolve-NativeQualityAssetSpec -Manifest $manifest -ToolName actionlint -OperatingSystem windows -Architecture arm64

        $assetSpec.AssetKey | Should -Be "windows-arm64"
        $assetSpec.RequestedAssetKey | Should -Be "windows-arm64"
        $assetSpec.ExecutableName | Should -Be "actionlint.exe"
        $assetSpec.FallbackReason | Should -Be ""
    }

    It "fails with a stable diagnostic for unsupported platform assets" {
        $manifest = [pscustomobject]@{
            tools = [pscustomobject]@{
                stylua = [pscustomobject]@{
                    version = "2.5.2"
                    releaseTag = "v2.5.2"
                    repository = "JohnnyMorganz/StyLua"
                    versionPattern = "stylua\\s+2\\.5\\.2"
                    executableBaseName = "stylua"
                    assets = [pscustomobject]@{
                        "linux-x64" = [pscustomobject]@{
                            assetName = "stylua-linux-x86_64-musl.zip"
                            sha256 = "ca6f1cf52eaf69e6632b81acef9c197aa24b85eb30d2455a35e7dbe28ae77c72"
                            kind = "zip"
                        }
                    }
                }
            }
        }

        { Resolve-NativeQualityAssetSpec -Manifest $manifest -ToolName stylua -OperatingSystem darwin -Architecture arm64 } |
            Should -Throw -ExpectedMessage "*E_NATIVE_TOOL_PLATFORM_UNSUPPORTED*"
    }
}

Describe "Invoke-NativeQualityChecks target scoping" {
    It "does not widen an empty or missing target list" {
        $targets = @(Resolve-NativeQualityTargetFiles -RepositoryRoot $script:repoRoot -InputFiles @("does-not-exist.lua", ""))
        $targets.Count | Should -Be 0
    }

    It "rejects targets outside the repository" {
        $outsidePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "outside-native-quality.lua"
        { Resolve-NativeQualityTargetFiles -RepositoryRoot $script:repoRoot -InputFiles @($outsidePath) } |
            Should -Throw -ExpectedMessage "*E_NATIVE_QUALITY_TARGET_OUTSIDE_REPOSITORY*"
    }

    It "rejects a case-variant repository-root target on case-sensitive filesystems" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "Ordinal (case-sensitive) boundary rejection only applies on non-Windows filesystems."
            return
        }

        # Upper-case the final segment of the repository root so an Ordinal comparison
        # treats the candidate as outside the (lower/mixed-case) repository root. The
        # boundary check fires before Test-Path, so the file need not exist.
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $trimmedRoot = $script:repoRoot.TrimEnd($separator)
        $parent = [System.IO.Path]::GetDirectoryName($trimmedRoot)
        $leaf = [System.IO.Path]::GetFileName($trimmedRoot)
        $caseVariantLeaf = $leaf.ToUpperInvariant()
        if ($caseVariantLeaf -ceq $leaf) {
            $caseVariantLeaf = $leaf.ToLowerInvariant()
        }

        if ([string]::IsNullOrWhiteSpace($parent) -or ($caseVariantLeaf -ceq $leaf)) {
            Set-ItResult -Skipped -Because "Repository root leaf has no case to vary."
            return
        }

        $caseVariantRoot = Join-Path -Path $parent -ChildPath $caseVariantLeaf
        $caseVariantTarget = Join-Path -Path $caseVariantRoot -ChildPath "Config/Wezterm/wezterm.lua"

        { Resolve-NativeQualityTargetFiles -RepositoryRoot $script:repoRoot -InputFiles @($caseVariantTarget) } |
            Should -Throw -ExpectedMessage "*TARGET_OUTSIDE_REPOSITORY*"
    }

    It "splits All-mode targets by native tool ownership" {
        $styluaPath = Join-Path -Path $script:repoRoot -ChildPath "Config/Wezterm/wezterm.lua"
        $workflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/script-quality.yml"

        $styluaTargets = @(Select-NativeQualityToolTargetFiles -ToolName stylua -RepositoryRoot $script:repoRoot -Files @($styluaPath, $workflowPath) -FilterForTool $true)
        $actionlintTargets = @(Select-NativeQualityToolTargetFiles -ToolName actionlint -RepositoryRoot $script:repoRoot -Files @($styluaPath, $workflowPath) -FilterForTool $true)

        $styluaTargets.Count | Should -Be 1
        (ConvertTo-NativeQualityRelativePath -RepositoryRoot $script:repoRoot -Path $styluaTargets[0]) | Should -Be "Config/Wezterm/wezterm.lua"
        $actionlintTargets.Count | Should -Be 1
        (ConvertTo-NativeQualityRelativePath -RepositoryRoot $script:repoRoot -Path $actionlintTargets[0]) | Should -Be ".github/workflows/script-quality.yml"
    }
}

Describe "Invoke-NativeQualityChecks manifest contract" {
    It "pins native assets for required host platforms with SHA256 hashes" {
        $manifest = Read-NativeQualityToolManifest

        $manifest.tools.stylua.version | Should -Be "2.5.2"
        $manifest.tools.actionlint.version | Should -Be "1.7.12"

        $expectedAssetKeysByTool = @{
            stylua     = @("darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-x64")
            actionlint = @("darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-arm64", "windows-x64")
        }

        foreach ($toolName in @("stylua", "actionlint")) {
            $tool = $manifest.tools.$toolName
            $tool.repository | Should -Not -BeNullOrEmpty
            $tool.releaseTag | Should -Match '^v\d+\.\d+\.\d+'

            $actualAssetKeys = @($tool.assets.PSObject.Properties.Name | Sort-Object)
            $actualAssetKeys | Should -Be $expectedAssetKeysByTool[$toolName]

            foreach ($assetProperty in @($tool.assets.PSObject.Properties)) {
                $asset = $assetProperty.Value
                $asset.assetName | Should -Not -BeNullOrEmpty
                $asset.kind | Should -Match '^(executable|zip|tar\.gz)$'
                $asset.sha256 | Should -Match '^[a-f0-9]{64}$'
            }
        }
    }
}

Describe "Invoke-NativeQualityChecks install robustness" {
    It "times out with a stable diagnostic when another process holds the install lock" {
        $originalLockTimeoutSeconds = $script:NativeQualityLockTimeoutSeconds
        $originalLockRetryMilliseconds = $script:NativeQualityLockRetryMilliseconds
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("native-quality-lock-test-{0}" -f [guid]::NewGuid().ToString("N"))
        $lockPath = Join-Path -Path $tempRoot -ChildPath "tool.lock"

        try {
            New-Item -Path $lockPath -ItemType Directory -Force | Out-Null
            $script:NativeQualityLockTimeoutSeconds = 1
            $script:NativeQualityLockRetryMilliseconds = 10

            { Invoke-NativeQualityInstallLock -LockPath $lockPath -ScriptBlock { throw "should-not-run" } } |
                Should -Throw -ExpectedMessage "*E_NATIVE_TOOL_LOCK_TIMEOUT*"
        }
        finally {
            $script:NativeQualityLockTimeoutSeconds = $originalLockTimeoutSeconds
            $script:NativeQualityLockRetryMilliseconds = $originalLockRetryMilliseconds
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "removes staging directories when hash verification fails before extraction" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("native-quality-hash-test-{0}" -f [guid]::NewGuid().ToString("N"))
        $installRoot = Join-Path -Path $tempRoot -ChildPath "stylua/2.5.2/linux-x64"
        $assetSpec = [pscustomobject]@{
            ToolName         = "stylua"
            Version          = "2.5.2"
            VersionPattern   = "stylua\\s+2\\.5\\.2"
            VersionArguments = @("--version")
            Repository       = "JohnnyMorganz/StyLua"
            ReleaseTag       = "v2.5.2"
            AssetKey         = "linux-x64"
            RequestedAssetKey = "linux-x64"
            AssetName        = "stylua-test.zip"
            Sha256           = "0000000000000000000000000000000000000000000000000000000000000000"
            Kind             = "zip"
            ExecutableName   = "stylua"
            DownloadUrl      = "https://example.invalid/stylua-test.zip"
            FallbackReason   = ""
        }

        try {
            Mock Invoke-NativeQualityDownload {
                param($AssetSpec, $DownloadPath)
                [System.IO.File]::WriteAllText($DownloadPath, "corrupted", [System.Text.UTF8Encoding]::new($false))
            }

            { Install-NativeQualityToolAsset -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $script:repoRoot } |
                Should -Throw -ExpectedMessage "*E_NATIVE_TOOL_HASH_MISMATCH*"

            $stagingDirectories = @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "staging-*" -Recurse -ErrorAction SilentlyContinue)
            $stagingDirectories.Count | Should -Be 0
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Invoke-NativeQualityChecks archive path safety" {
    It "rejects path traversal and absolute archive entries" {
        Test-NativeQualityArchiveEntryPath -EntryPath "stylua" | Should -BeTrue
        Test-NativeQualityArchiveEntryPath -EntryPath "../stylua" | Should -BeFalse
        Test-NativeQualityArchiveEntryPath -EntryPath "/tmp/stylua" | Should -BeFalse
        Test-NativeQualityArchiveEntryPath -EntryPath "stylua/../../bad" | Should -BeFalse
        Test-NativeQualityArchiveEntryPath -EntryPath "C:/tmp/stylua.exe" | Should -BeFalse
        Test-NativeQualityArchiveEntryPath -EntryPath "C:\tmp\stylua.exe" | Should -BeFalse
        Test-NativeQualityArchiveEntryPath -EntryPath "stylua/C:bad.exe" | Should -BeFalse
    }

    It "rejects tar symlink and hardlink metadata lines" {
        Test-NativeQualityTarMetadataLineSafe -MetadataLine '-rwxr-xr-x 0/0 1 2026-01-01 00:00 actionlint' | Should -BeTrue
        Test-NativeQualityTarMetadataLineSafe -MetadataLine 'drwxr-xr-x 0/0 0 2026-01-01 00:00 docs/' | Should -BeTrue
        Test-NativeQualityTarMetadataLineSafe -MetadataLine 'lrwxrwxrwx 0/0 0 2026-01-01 00:00 actionlint -> /tmp/actionlint' | Should -BeFalse
        Test-NativeQualityTarMetadataLineSafe -MetadataLine 'hrwxr-xr-x 0/0 0 2026-01-01 00:00 actionlint link to actionlint-real' | Should -BeFalse
    }
}
