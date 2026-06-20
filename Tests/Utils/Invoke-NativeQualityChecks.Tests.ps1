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
        Mock Resolve-NativeEmbeddedShellCheckExecutable { throw "embedded shellcheck resolution should not run for zero-target checks" }

        { Invoke-NativeQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @("does-not-exist.lua") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-NativeQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeQualityToolExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeEmbeddedShellCheckExecutable -Times 0 -Exactly
    }

    It "skips workflow-only targets in stylua mode before reading the manifest or resolving tools" {
        Mock Read-NativeQualityToolManifest { throw "manifest should not be read for non-stylua targets" }
        Mock Resolve-NativeQualityToolExecutable { throw "tool resolution should not run for non-stylua targets" }
        Mock Resolve-NativeEmbeddedShellCheckExecutable { throw "embedded shellcheck resolution should not run for non-stylua targets" }
        Mock Invoke-StyluaQualityCheck { throw "stylua should not run for workflow-only targets" }

        { Invoke-NativeQualityChecksMain -SelectedTool stylua -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @(".github/workflows/script-quality.yml") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-NativeQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeQualityToolExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeEmbeddedShellCheckExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Invoke-StyluaQualityCheck -Times 0 -Exactly
    }

    It "skips Lua-only targets in actionlint mode before reading the manifest or resolving tools" {
        Mock Read-NativeQualityToolManifest { throw "manifest should not be read for non-workflow targets" }
        Mock Resolve-NativeQualityToolExecutable { throw "tool resolution should not run for non-workflow targets" }
        Mock Resolve-NativeEmbeddedShellCheckExecutable { throw "embedded shellcheck resolution should not run for non-workflow targets" }
        Mock Invoke-ActionlintQualityCheck { throw "actionlint should not run for Lua-only targets" }

        { Invoke-NativeQualityChecksMain -SelectedTool actionlint -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @("Config/Wezterm/wezterm.lua") } |
            Should -Not -Throw

        Assert-MockCalled -CommandName Read-NativeQualityToolManifest -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeQualityToolExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Resolve-NativeEmbeddedShellCheckExecutable -Times 0 -Exactly
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
        Mock Resolve-NativeEmbeddedShellCheckExecutable { throw "embedded shellcheck should not resolve in stylua mode" }
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
        Assert-MockCalled -CommandName Resolve-NativeEmbeddedShellCheckExecutable -Times 0 -Exactly
        Assert-MockCalled -CommandName Invoke-ActionlintQualityCheck -Times 0 -Exactly
    }

    It "resolves only tools with matching targets and keeps embedded analyzers when supported in All mode" {
        $script:resolvedNativeTools = New-Object System.Collections.Generic.List[string]
        $script:actionlintTargetPaths = @()
        $script:actionlintShellCheckPath = ""
        $workflowPath = ".github/workflows/script-quality.yml"

        Mock Read-NativeQualityToolManifest {
            return [pscustomobject]@{ tools = [pscustomobject]@{} }
        }
        Mock Resolve-NativeQualityToolExecutable {
            param($Manifest, $ToolName, $RepositoryRoot)
            $script:resolvedNativeTools.Add($ToolName) | Out-Null
            return "/tmp/$ToolName"
        }
        Mock Test-UseActionlintEmbeddedAnalyzers { return $true }
        Mock Resolve-NativeEmbeddedShellCheckExecutable { return "/tmp/shellcheck" }
        Mock Invoke-ActionlintQualityCheck {
            param($ExecutablePath, $ShellCheckExecutablePath, $RepositoryRoot, $Files)
            $script:actionlintShellCheckPath = $ShellCheckExecutablePath
            $script:actionlintTargetPaths = @($Files)
        }
        Mock Invoke-StyluaQualityCheck { throw "stylua should not run for workflow-only targets" }

        Invoke-NativeQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @($workflowPath)

        @($script:resolvedNativeTools.ToArray()) | Should -Be @("actionlint")
        $script:actionlintShellCheckPath | Should -Be "/tmp/shellcheck"
        $script:actionlintTargetPaths.Count | Should -Be 1
        (ConvertTo-NativeQualityRelativePath -RepositoryRoot $script:repoRoot -Path $script:actionlintTargetPaths[0]) |
            Should -Be ".github/workflows/script-quality.yml"
        Assert-MockCalled -CommandName Resolve-NativeEmbeddedShellCheckExecutable -Times 1 -Exactly
        Assert-MockCalled -CommandName Invoke-ActionlintQualityCheck -Times 1 -Exactly
        Assert-MockCalled -CommandName Invoke-StyluaQualityCheck -Times 0 -Exactly
    }

    It "disables embedded analyzers with a diagnostic when the host cannot run them reliably" {
        $script:actionlintShellCheckPath = "unset"
        $script:nativeQualityWarnings = New-Object System.Collections.Generic.List[string]

        Mock Read-NativeQualityToolManifest {
            return [pscustomobject]@{ tools = [pscustomobject]@{} }
        }
        Mock Resolve-NativeQualityToolExecutable {
            return "/tmp/$ToolName"
        }
        Mock Test-UseActionlintEmbeddedAnalyzers { return $false }
        Mock Resolve-NativeEmbeddedShellCheckExecutable { throw "embedded shellcheck should be skipped on unsupported hosts" }
        Mock Invoke-ActionlintQualityCheck {
            param($ExecutablePath, $ShellCheckExecutablePath, $RepositoryRoot, $Files)
            $script:actionlintShellCheckPath = $ShellCheckExecutablePath
        }
        Mock Write-Warning {
            param($Message)
            $script:nativeQualityWarnings.Add($Message) | Out-Null
        }

        Invoke-NativeQualityChecksMain -SelectedTool actionlint -ApplyFix:$false -OnlyEnsureTools:$false -InputFiles @(".github/workflows/script-quality.yml")

        $script:actionlintShellCheckPath | Should -Be ""
        @($script:nativeQualityWarnings.ToArray()) | Should -Contain "W_NATIVE_QUALITY_ACTIONLINT_EMBEDDED_ANALYZERS_DISABLED_WINDOWS: actionlint shellcheck/pyflakes subprocess integration is disabled on Windows to avoid native subprocess hangs; Linux CI keeps blocking workflow embedded analyzer coverage."
        Assert-MockCalled -CommandName Resolve-NativeEmbeddedShellCheckExecutable -Times 0 -Exactly
    }

    It "still resolves all requested tools in EnsureOnly mode" {
        $script:resolvedNativeEnsureTools = New-Object System.Collections.Generic.List[string]
        $script:resolvedNativeEnsureShellCheck = $false

        Mock Read-NativeQualityToolManifest {
            return [pscustomobject]@{ tools = [pscustomobject]@{} }
        }
        Mock Resolve-NativeQualityToolExecutable {
            param($Manifest, $ToolName, $RepositoryRoot)
            $script:resolvedNativeEnsureTools.Add($ToolName) | Out-Null
            return "/tmp/$ToolName"
        }
        Mock Test-UseActionlintEmbeddedAnalyzers { return $true }
        Mock Resolve-NativeEmbeddedShellCheckExecutable {
            $script:resolvedNativeEnsureShellCheck = $true
            return "/tmp/shellcheck"
        }

        Invoke-NativeQualityChecksMain -SelectedTool All -ApplyFix:$false -OnlyEnsureTools:$true -InputFiles @()

        @($script:resolvedNativeEnsureTools.ToArray()) | Should -Be @("stylua", "actionlint")
        $script:resolvedNativeEnsureShellCheck | Should -BeTrue
    }
}

Describe "Invoke-NativeQualityChecks actionlint optional analyzers" {
    It "passes repo-managed shellcheck explicitly to actionlint when embedded analyzers are enabled" {
        $script:capturedActionlintArguments = @()

        Mock Invoke-QualityToolingProcess {
            param($Context, $FilePath, $ArgumentList, $WorkingDirectory)
            $script:capturedActionlintArguments = @($ArgumentList)
            return 0
        }

        Invoke-ActionlintQualityCheck -ExecutablePath "/tmp/actionlint" -ShellCheckExecutablePath "/tmp/shellcheck" -RepositoryRoot $script:repoRoot -Files @(".github/workflows/script-quality.yml")

        $script:capturedActionlintArguments[0..1] | Should -Be @("-shellcheck", "/tmp/shellcheck")
        $script:capturedActionlintArguments | Should -Not -Contain "-pyflakes"
        $script:capturedActionlintArguments | Should -Contain ".github/workflows/script-quality.yml"
    }

    It "disables shellcheck and pyflakes subprocesses when embedded analyzers are unsupported" {
        $script:capturedActionlintArguments = @()

        Mock Invoke-QualityToolingProcess {
            param($Context, $FilePath, $ArgumentList, $WorkingDirectory)
            $script:capturedActionlintArguments = @($ArgumentList)
            return 0
        }

        Invoke-ActionlintQualityCheck -ExecutablePath "/tmp/actionlint" -RepositoryRoot $script:repoRoot -Files @(".github/workflows/script-quality.yml")

        $script:capturedActionlintArguments[0..3] | Should -Be @("-shellcheck", "", "-pyflakes", "")
        $script:capturedActionlintArguments | Should -Contain ".github/workflows/script-quality.yml"
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
    It "requires executable integrity markers before treating cached native tools as ready" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("native-quality-ready-marker-{0}" -f [guid]::NewGuid().ToString("N"))
        $installRoot = Join-Path -Path $tempRoot -ChildPath "actionlint/1.7.12/linux-x64"
        $binRoot = Join-Path -Path $installRoot -ChildPath "bin"
        $executablePath = Join-Path -Path $binRoot -ChildPath "actionlint"
        $markerPath = Join-Path -Path $installRoot -ChildPath "asset.json"
        $assetSpec = [pscustomobject]@{
            ToolName         = "actionlint"
            Version          = "1.7.12"
            VersionPattern   = "1\\.7\\.12"
            VersionArguments = @("-version")
            Repository       = "rhysd/actionlint"
            ReleaseTag       = "v1.7.12"
            AssetKey         = "linux-x64"
            RequestedAssetKey = "linux-x64"
            AssetName        = "actionlint_1.7.12_linux_amd64.tar.gz"
            Sha256           = "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
            Kind             = "tar.gz"
            ExecutableName   = "actionlint"
            DownloadUrl      = "https://example.invalid/actionlint.tar.gz"
            FallbackReason   = ""
        }

        try {
            [System.IO.Directory]::CreateDirectory($binRoot) | Out-Null
            [System.IO.File]::WriteAllText($executablePath, "test executable", [System.Text.UTF8Encoding]::new($false))

            $writeMarker = {
                param(
                    [AllowNull()]
                    [string]$ExecutableSha256,

                    [Parameter(Mandatory = $false)]
                    [switch]$IncludeMetadata,

                    [Parameter(Mandatory = $false)]
                    [switch]$IncludeFastFingerprint,

                    [Parameter(Mandatory = $false)]
                    [string]$FastFingerprint = ""
                )

                $marker = [ordered]@{
                    tool              = $assetSpec.ToolName
                    version           = $assetSpec.Version
                    repository        = $assetSpec.Repository
                    releaseTag        = $assetSpec.ReleaseTag
                    assetKey          = $assetSpec.AssetKey
                    requestedAssetKey = $assetSpec.RequestedAssetKey
                    assetName         = $assetSpec.AssetName
                    sha256            = $assetSpec.Sha256
                    downloadUrl       = $assetSpec.DownloadUrl
                }
                if ($null -ne $ExecutableSha256) {
                    $marker["executableSha256"] = $ExecutableSha256
                }
                if ($IncludeMetadata.IsPresent) {
                    $executableItem = Get-Item -LiteralPath $executablePath -ErrorAction Stop
                    $marker["executableSize"] = [string]$executableItem.Length
                    $marker["executableMtime"] = [string](Get-QualityToolingFileModifiedUnixSeconds -Path $executablePath)
                }
                if ($IncludeFastFingerprint.IsPresent) {
                    $marker["executableFastFingerprintVersion"] = Get-QualityToolingExecutableFastFingerprintVersion
                    $marker["executableFastFingerprint"] = if ([string]::IsNullOrWhiteSpace($FastFingerprint)) {
                        Get-QualityToolingExecutableFastFingerprint -Path $executablePath
                    }
                    else {
                        $FastFingerprint
                    }
                }

                [System.IO.File]::WriteAllText($markerPath, (($marker | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            }

            & $writeMarker $null
            Test-QualityToolingToolReady -Context $script:NativeQualityContext -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $script:repoRoot |
                Should -BeFalse

            & $writeMarker ("0" * 64)
            Test-QualityToolingToolReady -Context $script:NativeQualityContext -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $script:repoRoot |
                Should -BeFalse

            $actualExecutableSha256 = Get-QualityToolingFileSha256 -Path $executablePath
            & $writeMarker $actualExecutableSha256 -IncludeMetadata
            Test-QualityToolingToolReady -Context $script:NativeQualityContext -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $script:repoRoot |
                Should -BeFalse

            & $writeMarker $actualExecutableSha256 -IncludeMetadata -IncludeFastFingerprint -FastFingerprint ("1" * 64)
            Test-QualityToolingToolReady -Context $script:NativeQualityContext -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $script:repoRoot |
                Should -BeFalse

            & $writeMarker $actualExecutableSha256 -IncludeMetadata -IncludeFastFingerprint
            Mock Assert-QualityToolingToolVersion { }

            Test-QualityToolingToolReady -Context $script:NativeQualityContext -InstallRoot $installRoot -AssetSpec $assetSpec -RepositoryRoot $script:repoRoot |
                Should -BeTrue
            Assert-MockCalled -CommandName Assert-QualityToolingToolVersion -Times 1 -Exactly
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "changes the executable fast fingerprint for sampled-byte tampering with restored size and mtime" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("native-quality-fast-fingerprint-{0}" -f [guid]::NewGuid().ToString("N"))
        $executablePath = Join-Path -Path $tempRoot -ChildPath "sample-tool"

        try {
            [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
            $bytes = New-Object byte[] (256 * 1024)
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                $bytes[$index] = [byte]($index % 251)
            }

            [System.IO.File]::WriteAllBytes($executablePath, $bytes)
            $originalItem = Get-Item -LiteralPath $executablePath -ErrorAction Stop
            $originalMtime = $originalItem.LastWriteTimeUtc
            $originalUnixMtime = Get-QualityToolingFileModifiedUnixSeconds -Path $executablePath
            $originalFingerprint = Get-QualityToolingExecutableFastFingerprint -Path $executablePath

            $stream = [System.IO.File]::Open($executablePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
            try {
                [void]$stream.Seek(65536, [System.IO.SeekOrigin]::Begin)
                $stream.WriteByte(42)
            }
            finally {
                $stream.Dispose()
            }

            (Get-Item -LiteralPath $executablePath -ErrorAction Stop).LastWriteTimeUtc = $originalMtime

            (Get-Item -LiteralPath $executablePath -ErrorAction Stop).Length | Should -Be $originalItem.Length
            Get-QualityToolingFileModifiedUnixSeconds -Path $executablePath | Should -Be $originalUnixMtime
            Get-QualityToolingExecutableFastFingerprint -Path $executablePath | Should -Not -Be $originalFingerprint
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

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
