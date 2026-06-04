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

        $styluaTargets = @(Select-NativeQualityToolTargetFiles -ToolName stylua -RepositoryRoot $script:repoRoot -Files @($styluaPath, $workflowPath))
        $actionlintTargets = @(Select-NativeQualityToolTargetFiles -ToolName actionlint -RepositoryRoot $script:repoRoot -Files @($styluaPath, $workflowPath))

        $styluaTargets.Count | Should -Be 1
        (ConvertTo-NativeQualityRelativePath -RepositoryRoot $script:repoRoot -Path $styluaTargets[0]) | Should -Be "Config/Wezterm/wezterm.lua"
        $actionlintTargets.Count | Should -Be 1
        (ConvertTo-NativeQualityRelativePath -RepositoryRoot $script:repoRoot -Path $actionlintTargets[0]) | Should -Be ".github/workflows/script-quality.yml"
    }

    It "skips zero selected targets before reading the manifest or resolving tools" {
        Mock Read-NativeQualityToolManifest { throw "manifest should not be read for zero-target checks" }
        Mock Resolve-NativeQualityToolExecutable { throw "tool resolution should not run for zero-target checks" }

        { Invoke-NativeQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @("does-not-exist.lua") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-NativeQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeQualityToolExecutable -Times 0 -Exactly
    }

    It "skips workflow-only targets in stylua mode before reading the manifest or resolving tools" {
        Mock Read-NativeQualityToolManifest { throw "manifest should not be read for non-stylua targets" }
        Mock Resolve-NativeQualityToolExecutable { throw "tool resolution should not run for non-stylua targets" }
        Mock Invoke-StyluaQualityCheck { throw "stylua should not run for workflow-only targets" }

        { Invoke-NativeQualityChecksMain -SelectedTool stylua -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @(".github/workflows/script-quality.yml") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-NativeQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeQualityToolExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Invoke-StyluaQualityCheck -Times 0 -Exactly
    }

    It "skips Lua-only targets in actionlint mode before reading the manifest or resolving tools" {
        Mock Read-NativeQualityToolManifest { throw "manifest should not be read for non-workflow targets" }
        Mock Resolve-NativeQualityToolExecutable { throw "tool resolution should not run for non-workflow targets" }
        Mock Invoke-ActionlintQualityCheck { throw "actionlint should not run for Lua-only targets" }

        { Invoke-NativeQualityChecksMain -SelectedTool actionlint -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @("Config/Wezterm/wezterm.lua") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-NativeQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeQualityToolExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Invoke-ActionlintQualityCheck -Times 0 -Exactly
    }

    It "passes only owned targets to a selected single native tool" {
        $script:resolvedNativeSingleTools = New-Object System.Collections.Generic.List[string]
        $script:styluaSingleToolTargets = @()

        Mock Read-NativeQualityToolManifest {
            return [pscustomobject]@{ tools = [pscustomobject]@{} }
        }
        Mock Resolve-NativeQualityToolExecutable {
            param($Manifest, $ToolName, $RepositoryRoot)
            $script:resolvedNativeSingleTools.Add($ToolName) | Out-Null
            return "/tmp/$ToolName"
        }
        Mock Invoke-StyluaQualityCheck {
            param($ExecutablePath, $RepositoryRoot, $Files, $ApplyFix)
            $script:styluaSingleToolTargets = @($Files)
        }
        Mock Invoke-ActionlintQualityCheck { throw "actionlint should not run in stylua mode" }

        Invoke-NativeQualityChecksMain -SelectedTool stylua -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @(
            ".github/workflows/script-quality.yml",
            "Config/Wezterm/wezterm.lua"
        )

        @($script:resolvedNativeSingleTools.ToArray()) | Should -Be @("stylua")
        $script:styluaSingleToolTargets.Count | Should -Be 1
        (ConvertTo-NativeQualityRelativePath -RepositoryRoot $script:repoRoot -Path $script:styluaSingleToolTargets[0]) |
            Should -Be "Config/Wezterm/wezterm.lua"
        Assert-MockCalled -CommandName Invoke-StyluaQualityCheck -Times 1 -Exactly
        Assert-MockCalled -CommandName Invoke-ActionlintQualityCheck -Times 0 -Exactly
    }

    It "resolves only tools with matching targets in All mode" {
        $script:resolvedNativeTools = New-Object System.Collections.Generic.List[string]
        $workflowPath = ".github/workflows/script-quality.yml"

        Mock Read-NativeQualityToolManifest {
            return [pscustomobject]@{ tools = [pscustomobject]@{} }
        }
        Mock Resolve-NativeQualityToolExecutable {
            param($Manifest, $ToolName, $RepositoryRoot)
            $script:resolvedNativeTools.Add($ToolName) | Out-Null
            return "/tmp/$ToolName"
        }
        Mock Invoke-ActionlintQualityCheck {}
        Mock Invoke-StyluaQualityCheck { throw "stylua should not run for workflow-only targets" }

        Invoke-NativeQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @($workflowPath)

        @($script:resolvedNativeTools.ToArray()) | Should -Be @("actionlint")
        Assert-MockCalled -CommandName Invoke-ActionlintQualityCheck -Times 1 -Exactly
        Assert-MockCalled -CommandName Invoke-StyluaQualityCheck -Times 0 -Exactly
    }

    It "still resolves all requested tools in EnsureOnly mode" {
        $script:resolvedNativeEnsureTools = New-Object System.Collections.Generic.List[string]

        Mock Read-NativeQualityToolManifest {
            return [pscustomobject]@{ tools = [pscustomobject]@{} }
        }
        Mock Resolve-NativeQualityToolExecutable {
            param($Manifest, $ToolName, $RepositoryRoot)
            $script:resolvedNativeEnsureTools.Add($ToolName) | Out-Null
            return "/tmp/$ToolName"
        }

        Invoke-NativeQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$true -InputFiles @()

        @($script:resolvedNativeEnsureTools.ToArray()) | Should -Be @("stylua", "actionlint")
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
    It "rechecks readiness under the install lock and invokes the install command without network access" {
        $script:nativeReadyCheckCount = 0
        $script:nativeInstallCommandCount = 0
        $manifest = Read-NativeQualityToolManifest
        $tempRepositoryRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("native-quality-install-callback-{0}" -f [guid]::NewGuid().ToString("N"))

        try {
            [System.IO.Directory]::CreateDirectory($tempRepositoryRoot) | Out-Null
            Mock Test-QualityToolingToolReady {
                $script:nativeReadyCheckCount += 1
                return ($script:nativeReadyCheckCount -ge 3)
            }
            Mock Install-NativeQualityToolAsset {
                param($InstallRoot, $AssetSpec, $RepositoryRoot)
                $script:nativeInstallCommandCount += 1
                $AssetSpec.ToolName | Should -Be "stylua"
                $RepositoryRoot | Should -Be $tempRepositoryRoot
            }

            $executablePath = Resolve-NativeQualityToolExecutable -Manifest $manifest -ToolName stylua -RepositoryRoot $tempRepositoryRoot

            $executablePath | Should -Match 'stylua'
            $script:nativeReadyCheckCount | Should -Be 3
            $script:nativeInstallCommandCount | Should -Be 1
        }
        finally {
            if (Test-Path -LiteralPath $tempRepositoryRoot) {
                Remove-Item -LiteralPath $tempRepositoryRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "passes explicit argument lists to install-lock callbacks" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("native-quality-argument-lock-{0}" -f [guid]::NewGuid().ToString("N"))
        $lockPath = Join-Path -Path $tempRoot -ChildPath "tool.lock"
        $script:nativeLockArgumentValue = ""

        try {
            [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
            Invoke-NativeQualityInstallLock -LockPath $lockPath -ArgumentList @("callback-value") -ScriptBlock {
                param($Value)
                $script:nativeLockArgumentValue = [string]$Value
            }

            $script:nativeLockArgumentValue | Should -Be "callback-value"
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

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
