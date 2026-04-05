Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:removeBomScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Remove-BOM.ps1"
    $script:gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue

    . $script:removeBomScriptPath

    function Resolve-CanonicalTempRoot {
        param([string]$Path)
        # Use production canonicalization so test path derivation matches discovery behavior
        # under symlink aliases (for example, /var vs /private/var on macOS).
        return Resolve-CanonicalFileSystemPath -path $Path
    }

    function Get-CanonicalRelativePath {
        param(
            [string]$BasePath,
            [string]$TargetPath
        )

        $canonicalBasePath = Resolve-CanonicalFileSystemPath -path $BasePath
        $canonicalTargetPath = Resolve-CanonicalFileSystemPath -path $TargetPath
        return ([System.IO.Path]::GetRelativePath($canonicalBasePath, $canonicalTargetPath) -replace '\\', '/')
    }

    function Initialize-TestGitRepository {
        param(
            [string]$RepositoryRoot
        )

        & $script:gitCommand.Source -C $RepositoryRoot init | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "E_TEST_SETUP_FAILED: git init failed for '$RepositoryRoot'."
        }
    }
}

Describe "Remove-BOM file discovery" {
    BeforeEach {
        $script:topLevelAliasCache = @{}
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("remove-bom-tests-" + [System.Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($script:testRoot) | Out-Null
        $script:testRoot = Resolve-CanonicalTempRoot -Path $script:testRoot
        # Clear the alias cache again after Resolve-CanonicalTempRoot: on macOS,
        # the temp-root canonicalization probes /var which may cache an incorrect
        # identity mapping when .NET providers fail to resolve the symlink.
        # Mock-based tests need an empty cache so their mocks are exercised.
        $script:topLevelAliasCache = @{}
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot -PathType Container) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It "canonicalizes existing paths without segment traversal (<Scenario>)" -TestCases @(
        @{ Scenario = "uses item FullName when no link target is available"; UseResolveLinkTarget = $false },
        @{ Scenario = "uses ResolveLinkTarget for terminal symlink paths"; UseResolveLinkTarget = $true }
    ) {
        param(
            [string]$Scenario,
            [bool]$UseResolveLinkTarget
        )

        $resolvedPath = if ($IsWindows) {
            "C:\\runner\\_work\\_temp\\canonical-test-root"
        }
        else {
            "/private/var/folders/canonical-test-root"
        }

        $missingIntermediate = if ($IsWindows) {
            "C:\\runner"
        }
        else {
            "/var"
        }

        $resolvedItemPath = if ($UseResolveLinkTarget) {
            if ($IsWindows) {
                "C:\\runner\\alias\\canonical-test-root"
            }
            else {
                "/var/folders/canonical-test-root"
            }
        }
        else {
            $resolvedPath
        }

        $linkTargetPath = if ($IsWindows) {
            "C:\\runner\\target\\canonical-test-root"
        }
        else {
            "/private/var/folders/canonical-test-root"
        }

        $expectedCanonicalPath = if ($UseResolveLinkTarget) {
            [System.IO.Path]::GetFullPath($linkTargetPath)
        }
        else {
            [System.IO.Path]::GetFullPath($resolvedItemPath)
        }

        Mock -CommandName Resolve-Path -MockWith {
            [PSCustomObject]@{ Path = $resolvedPath }
        }

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $missingIntermediate
        } -MockWith {
            throw "Could not find item $LiteralPath."
        }

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $resolvedPath
        } -MockWith {
            $mockItem = [PSCustomObject]@{
                FullName       = $resolvedItemPath
                LinkTargetPath = $linkTargetPath
            }

            if ($UseResolveLinkTarget) {
                Add-Member -InputObject $mockItem -MemberType ScriptMethod -Name ResolveLinkTarget -Value {
                    param([bool]$returnFinalTarget)
                    return [PSCustomObject]@{ FullName = $this.LinkTargetPath }
                }
            }

            return $mockItem
        }

        $actualCanonicalPath = Resolve-CanonicalFileSystemPath -path "ignored-by-mocks"

        $actualCanonicalPath | Should -Be $expectedCanonicalPath -Because "Scenario '$Scenario' should canonicalize without traversing intermediate path segments."
        Assert-MockCalled -CommandName Get-Item -ParameterFilter { $LiteralPath -eq $resolvedPath } -Times 1 -Exactly
        Assert-MockCalled -CommandName Get-Item -ParameterFilter { $LiteralPath -eq $missingIntermediate } -Times 0 -Exactly
    }

    It "normalizes top-level symlink aliases during canonicalization (<Scenario>)" -TestCases @(
        @{
            Scenario                  = "ResolveLinkTarget method"
            AliasRootFullName         = "/var"
            ResolveLinkTargetFullName = "/private/var"
            LinkTargetPropertyName    = $null
            LinkTargetPropertyValue   = $null
        },
        @{
            Scenario                  = "LinkTarget property (absolute)"
            AliasRootFullName         = "/var"
            ResolveLinkTargetFullName = $null
            LinkTargetPropertyName    = "LinkTarget"
            LinkTargetPropertyValue   = "/private/var"
        },
        @{
            Scenario                  = "Target property (absolute)"
            AliasRootFullName         = "/var"
            ResolveLinkTargetFullName = $null
            LinkTargetPropertyName    = "Target"
            LinkTargetPropertyValue   = "/private/var"
        },
        @{
            Scenario                  = "LinkTarget property (relative)"
            AliasRootFullName         = "/var"
            ResolveLinkTargetFullName = $null
            LinkTargetPropertyName    = "LinkTarget"
            LinkTargetPropertyValue   = "private/var"
        },
        @{
            Scenario                  = "FullName fallback"
            AliasRootFullName         = "/private/var"
            ResolveLinkTargetFullName = $null
            LinkTargetPropertyName    = $null
            LinkTargetPropertyValue   = $null
            ResolvePathAliasPath      = $null
        },
        @{
            Scenario                  = "Resolve-Path fallback"
            AliasRootFullName         = "/var"
            ResolveLinkTargetFullName = $null
            LinkTargetPropertyName    = $null
            LinkTargetPropertyValue   = $null
            ResolvePathAliasPath      = "/private/var"
        }
    ) {
        param(
            [string]$Scenario,
            [string]$AliasRootFullName,
            [string]$ResolveLinkTargetFullName,
            [string]$LinkTargetPropertyName,
            [string]$LinkTargetPropertyValue,
            [string]$ResolvePathAliasPath
        )

        if ($IsWindows) {
            Set-ItResult -Skipped -Because "Unix-style root alias canonicalization does not apply on Windows"
            return
        }

        $aliasRoot = "/var"
        $aliasPath = "/var/folders/canonical-test-root"

        Mock -CommandName Resolve-Path -ParameterFilter {
            $LiteralPath -eq "ignored-by-mocks"
        } -MockWith {
            [PSCustomObject]@{ Path = $aliasPath }
        }

        Mock -CommandName Resolve-Path -ParameterFilter {
            $LiteralPath -eq $aliasRoot
        } -MockWith {
            $resolvedAliasPath = if (-not [string]::IsNullOrWhiteSpace($ResolvePathAliasPath)) {
                $ResolvePathAliasPath
            }
            else {
                $aliasRoot
            }

            [PSCustomObject]@{ Path = $resolvedAliasPath }
        }

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $aliasPath
        } -MockWith {
            [PSCustomObject]@{ FullName = $aliasPath }
        }

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $aliasRoot
        } -MockWith {
            $aliasRootItem = [PSCustomObject]@{ FullName = $AliasRootFullName }

            if (-not [string]::IsNullOrWhiteSpace($LinkTargetPropertyName)) {
                Add-Member -InputObject $aliasRootItem -MemberType NoteProperty -Name $LinkTargetPropertyName -Value $LinkTargetPropertyValue
            }

            if (-not [string]::IsNullOrWhiteSpace($ResolveLinkTargetFullName)) {
                Add-Member -InputObject $aliasRootItem -MemberType NoteProperty -Name ResolveTargetPath -Value $ResolveLinkTargetFullName
                Add-Member -InputObject $aliasRootItem -MemberType ScriptMethod -Name ResolveLinkTarget -Value {
                    param([bool]$returnFinalTarget)
                    return [PSCustomObject]@{ FullName = $this.ResolveTargetPath }
                }
            }

            return $aliasRootItem
        }

        $actualCanonicalPath = Resolve-CanonicalFileSystemPath -path "ignored-by-mocks"
        $actualCanonicalPath | Should -Be "/private/var/folders/canonical-test-root" -Because "Scenario '$Scenario' should normalize top-level aliases consistently."

        if (-not [string]::IsNullOrWhiteSpace($ResolvePathAliasPath)) {
            Assert-MockCalled -CommandName Resolve-Path -ParameterFilter { $LiteralPath -eq $aliasRoot } -Times 1 -Exactly
        }
    }

    It "falls back to readlink when .NET providers fail to resolve top-level alias" {
        if ($IsWindows) {
            Set-ItResult -Skipped -Because "Unix-style root alias canonicalization does not apply on Windows"
            return
        }

        $aliasRoot = "/var"
        $aliasPath = "/var/folders/canonical-test-root"

        Mock -CommandName Resolve-Path -ParameterFilter {
            $LiteralPath -eq "ignored-by-mocks"
        } -MockWith {
            [PSCustomObject]@{ Path = $aliasPath }
        }

        # Resolve-Path returns identity (no alias resolution)
        Mock -CommandName Resolve-Path -ParameterFilter {
            $LiteralPath -eq $aliasRoot
        } -MockWith {
            [PSCustomObject]@{ Path = $aliasRoot }
        }

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $aliasPath
        } -MockWith {
            [PSCustomObject]@{ FullName = $aliasPath }
        }

        # All .NET resolution methods return identity
        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $aliasRoot
        } -MockWith {
            [PSCustomObject]@{ FullName = $aliasRoot }
        }

        # readlink provides the only working resolution path.
        # Set $global:LASTEXITCODE because the production code checks it after
        # invoking the native command, and PowerShell functions do not set it.
        function readlink { $global:LASTEXITCODE = 0; "private/var" }

        $actualCanonicalPath = Resolve-CanonicalFileSystemPath -path "ignored-by-mocks"
        $actualCanonicalPath | Should -Be "/private/var/folders/canonical-test-root" -Because "readlink fallback should resolve top-level aliases when .NET providers fail."
    }

    It "treats top-level alias and canonical roots as equivalent for scope checks (<Scenario>)" -TestCases @(
        @{
            Scenario                  = "ResolveLinkTarget method"
            AliasRootFullName         = "/var"
            ResolveLinkTargetFullName = "/private/var"
            LinkTargetPropertyName    = $null
            LinkTargetPropertyValue   = $null
        },
        @{
            Scenario                  = "LinkTarget property"
            AliasRootFullName         = "/var"
            ResolveLinkTargetFullName = $null
            LinkTargetPropertyName    = "LinkTarget"
            LinkTargetPropertyValue   = "/private/var"
        },
        @{
            Scenario                  = "FullName fallback"
            AliasRootFullName         = "/private/var"
            ResolveLinkTargetFullName = $null
            LinkTargetPropertyName    = $null
            LinkTargetPropertyValue   = $null
        }
    ) {
        param(
            [string]$Scenario,
            [string]$AliasRootFullName,
            [string]$ResolveLinkTargetFullName,
            [string]$LinkTargetPropertyName,
            [string]$LinkTargetPropertyValue
        )

        if ($IsWindows) {
            Set-ItResult -Skipped -Because "Unix-style root alias canonicalization does not apply on Windows"
            return
        }

        $aliasRoot = "/var"

        Mock -CommandName Get-Item -ParameterFilter {
            $LiteralPath -eq $aliasRoot
        } -MockWith {
            $aliasRootItem = [PSCustomObject]@{ FullName = $AliasRootFullName }

            if (-not [string]::IsNullOrWhiteSpace($LinkTargetPropertyName)) {
                Add-Member -InputObject $aliasRootItem -MemberType NoteProperty -Name $LinkTargetPropertyName -Value $LinkTargetPropertyValue
            }

            if (-not [string]::IsNullOrWhiteSpace($ResolveLinkTargetFullName)) {
                Add-Member -InputObject $aliasRootItem -MemberType NoteProperty -Name ResolveTargetPath -Value $ResolveLinkTargetFullName
                Add-Member -InputObject $aliasRootItem -MemberType ScriptMethod -Name ResolveLinkTarget -Value {
                    param([bool]$returnFinalTarget)
                    return [PSCustomObject]@{ FullName = $this.ResolveTargetPath }
                }
            }

            return $aliasRootItem
        }

        $underRoot = Test-IsPathUnderRoot -path "/private/var/tmp/repo/file.txt" -root "/var/tmp/repo"
        $underRoot | Should -BeTrue -Because "Scenario '$Scenario' should treat alias and canonical roots as equivalent during scope checks."
    }

    It "emits stable diagnostics when canonical path resolution fails" {
        Mock -CommandName Resolve-Path -MockWith {
            throw "simulated canonicalization failure"
        }

        {
            Resolve-CanonicalFileSystemPath -path "missing-path"
        } | Should -Throw "E_REMOVE_BOM_CANONICAL_PATH_RESOLUTION_FAILED*"
    }

    It "uses git-native semantics to exclude dot-prefixed ignored directories" {
        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $script:testRoot

        @(
            ".venv/",
            ".tmp_logs/",
            "*.log"
        ) | Set-Content -LiteralPath (Join-Path -Path $script:testRoot -ChildPath ".gitignore") -Encoding utf8

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".venv")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".tmp_logs")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "src")) | Out-Null

        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".venv/ignored.txt"), "ignored")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".tmp_logs/ignored.txt"), "ignored")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "trace.log"), "ignored")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "keep.txt"), "keep")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "src/keep2.txt"), "keep")

        $scanPlan = Get-ScannableFiles -scanRoot $script:testRoot
        $relativeFiles = @(
            $scanPlan.Files |
                ForEach-Object { Get-CanonicalRelativePath -BasePath $script:testRoot -TargetPath $_.FullName } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $relativeFiles | Should -Contain "keep.txt"
        $relativeFiles | Should -Contain "src/keep2.txt"
        $relativeFiles | Should -Not -Contain ".venv/ignored.txt"
        $relativeFiles | Should -Not -Contain ".tmp_logs/ignored.txt"
        $relativeFiles | Should -Not -Contain "trace.log"
    }

    It "uses git-ls-files discovery mode for repository-backed scan roots (<Scenario>)" -TestCases @(
        @{ Scenario = "repo root"; RelativeScanRoot = "." },
        @{ Scenario = "nested directory"; RelativeScanRoot = "src" }
    ) {
        param(
            [string]$Scenario,
            [string]$RelativeScanRoot
        )

        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $script:testRoot
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "src")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "src/keep.txt"), "keep")

        $scanRoot = if ($RelativeScanRoot -eq ".") {
            $script:testRoot
        }
        else {
            Join-Path -Path $script:testRoot -ChildPath $RelativeScanRoot
        }

        $scanPlan = Resolve-ScannableFileDiscovery -scanRoot $scanRoot
        $scanPlan.Mode | Should -Be "git-ls-files" -Because "Scenario '$Scenario' should use git-native discovery"
    }

    It "handles symlink-alias scan roots with git-native discovery (<Scenario>)" -TestCases @(
        @{
            Scenario               = "repository root symlink"
            RelativeScanRoot       = "."
            ExpectedFileNames      = @("keep.txt", "keep2.txt")
            UseAliasChain          = $false
            UseRelativeChainTarget = $false
        },
        @{
            Scenario               = "nested symlink subdirectory"
            RelativeScanRoot       = "src"
            ExpectedFileNames      = @("keep2.txt")
            UseAliasChain          = $false
            UseRelativeChainTarget = $false
        },
        @{
            Scenario               = "repository root symlink chain"
            RelativeScanRoot       = "."
            ExpectedFileNames      = @("keep.txt", "keep2.txt")
            UseAliasChain          = $true
            UseRelativeChainTarget = $false
        },
        @{
            Scenario               = "nested symlink subdirectory via relative chain"
            RelativeScanRoot       = "src"
            ExpectedFileNames      = @("keep2.txt")
            UseAliasChain          = $true
            UseRelativeChainTarget = $true
        }
    ) {
        param(
            [string]$Scenario,
            [string]$RelativeScanRoot,
            [string[]]$ExpectedFileNames,
            [bool]$UseAliasChain,
            [bool]$UseRelativeChainTarget
        )

        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        $realRoot = Join-Path -Path $script:testRoot -ChildPath "real-root"
        $aliasRoot = Join-Path -Path $script:testRoot -ChildPath "alias-root"
        $aliasChainRoot = Join-Path -Path $script:testRoot -ChildPath "alias-chain-root"
        [System.IO.Directory]::CreateDirectory($realRoot) | Out-Null

        try {
            New-Item -ItemType SymbolicLink -Path $aliasRoot -Target $realRoot -ErrorAction Stop | Out-Null

            if ($UseAliasChain) {
                $chainTarget = if ($UseRelativeChainTarget) {
                    "alias-root"
                }
                else {
                    $aliasRoot
                }

                New-Item -ItemType SymbolicLink -Path $aliasChainRoot -Target $chainTarget -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Set-ItResult -Skipped -Because "symbolic links are unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $realRoot
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $realRoot -ChildPath "src")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $realRoot -ChildPath "keep.txt"), "keep")
        [System.IO.File]::WriteAllText((Join-Path -Path $realRoot -ChildPath "src/keep2.txt"), "keep")

        $scanBaseRoot = if ($UseAliasChain) {
            $aliasChainRoot
        }
        else {
            $aliasRoot
        }

        $scanRoot = if ($RelativeScanRoot -eq ".") {
            $scanBaseRoot
        }
        else {
            Join-Path -Path $scanBaseRoot -ChildPath $RelativeScanRoot
        }

        $scanPlan = Get-ScannableFiles -scanRoot $scanRoot
        $fileNames = @(
            $scanPlan.Files |
                ForEach-Object { $_.Name } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files" -Because "Scenario '$Scenario' should stay on git-native discovery"
        $scanPlan.Diagnostics | Should -Match 'scanRootInput=' -Because "Scenario '$Scenario' should expose discovery diagnostics for root-cause triage"
        $scanPlan.Diagnostics | Should -Match 'selectedFiles=' -Because "Scenario '$Scenario' should report selected file count"
        $fileNames | Should -Be $ExpectedFileNames -Because "Scenario '$Scenario' expected file set was not returned. Diagnostics: $($scanPlan.Diagnostics)"
    }

    It "limits git-discovered files to the requested scan root" {
        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $script:testRoot

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "left")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "right")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "left/a.txt"), "left")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "right/b.txt"), "right")

        $scanRoot = Join-Path -Path $script:testRoot -ChildPath "left"
        $scanPlan = Get-ScannableFiles -scanRoot $scanRoot
        $relativeFiles = @(
            $scanPlan.Files |
                ForEach-Object { Get-CanonicalRelativePath -BasePath $script:testRoot -TargetPath $_.FullName } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $relativeFiles | Should -Be @("left/a.txt")
    }

    It "preserves scope restriction when git rev-parse --show-prefix fails" {
        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $script:testRoot

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "left")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "right")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "left/a.txt"), "left")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "right/b.txt"), "right")

        # Mock Get-GitCommandDetails to succeed for --show-toplevel but fail for --show-prefix
        Mock -CommandName Get-GitCommandDetails -MockWith {
            param($gitExecutable, $workingDirectory, $arguments)
            if ($arguments -contains "--show-prefix") {
                return [PSCustomObject]@{
                    ExitCode  = 1
                    Output    = @()
                    FirstLine = $null
                    HasOutput = $false
                }
            }
            # Let --show-toplevel pass through to real git
            $realOutput = @(& $gitExecutable -C $workingDirectory @arguments 2>&1)
            $realExitCode = $LASTEXITCODE
            $firstLine = $null
            foreach ($line in $realOutput) {
                $normalized = [string]$line
                if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                    $firstLine = $normalized.Trim()
                    break
                }
            }
            return [PSCustomObject]@{
                ExitCode  = $realExitCode
                Output    = @($realOutput)
                FirstLine = $firstLine
                HasOutput = $null -ne $firstLine
            }
        }

        $scanRoot = Join-Path -Path $script:testRoot -ChildPath "left"
        $scanPlan = Get-ScannableFiles -scanRoot $scanRoot
        $relativeFiles = @(
            $scanPlan.Files |
                ForEach-Object { Get-CanonicalRelativePath -BasePath $script:testRoot -TargetPath $_.FullName } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $relativeFiles | Should -Be @("left/a.txt") -Because "files outside the requested scan root must not leak through even when --show-prefix fails"
    }

    It "preserves scope when git rev-parse --show-prefix returns out-of-root prefix (<PrefixOutput>)" -TestCases @(
        @{ PrefixOutput = ".." },
        @{ PrefixOutput = "../outside" }
    ) {
        param(
            [string]$PrefixOutput
        )

        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $script:testRoot

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "left")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "right")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "left/a.txt"), "left")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "right/b.txt"), "right")

        Mock -CommandName Get-GitCommandDetails -MockWith {
            param($gitExecutable, $workingDirectory, $arguments)
            if ($arguments -contains "--show-prefix") {
                return [PSCustomObject]@{
                    ExitCode  = 0
                    Output    = @($PrefixOutput)
                    FirstLine = $PrefixOutput
                    HasOutput = $true
                }
            }

            $realOutput = @(& $gitExecutable -C $workingDirectory @arguments 2>&1)
            $realExitCode = $LASTEXITCODE
            $firstLine = $null
            foreach ($line in $realOutput) {
                $normalized = [string]$line
                if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                    $firstLine = $normalized.Trim()
                    break
                }
            }

            return [PSCustomObject]@{
                ExitCode  = $realExitCode
                Output    = @($realOutput)
                FirstLine = $firstLine
                HasOutput = $null -ne $firstLine
            }
        }

        $scanRoot = Join-Path -Path $script:testRoot -ChildPath "left"
        $scanPlan = Get-ScannableFiles -scanRoot $scanRoot
        $relativeFiles = @(
            $scanPlan.Files |
                ForEach-Object { Get-CanonicalRelativePath -BasePath $script:testRoot -TargetPath $_.FullName } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $scanPlan.Diagnostics | Should -Match 'relativeScanRoot=\.' -Because "Out-of-root prefixes must degrade to git-root enumeration with post-filtering"
        $relativeFiles | Should -Be @("left/a.txt") -Because "Out-of-root prefixes must not allow files outside the requested scan root"
    }

    It "preserves scope when called from git root and --show-prefix fails" {
        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $script:testRoot

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "src")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "root.txt"), "root")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "src/nested.txt"), "nested")

        # Mock Get-GitCommandDetails to succeed for --show-toplevel but fail for --show-prefix
        Mock -CommandName Get-GitCommandDetails -MockWith {
            param($gitExecutable, $workingDirectory, $arguments)
            if ($arguments -contains "--show-prefix") {
                return [PSCustomObject]@{
                    ExitCode  = 1
                    Output    = @()
                    FirstLine = $null
                    HasOutput = $false
                }
            }
            $realOutput = @(& $gitExecutable -C $workingDirectory @arguments 2>&1)
            $realExitCode = $LASTEXITCODE
            $firstLine = $null
            foreach ($line in $realOutput) {
                $normalized = [string]$line
                if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                    $firstLine = $normalized.Trim()
                    break
                }
            }
            return [PSCustomObject]@{
                ExitCode  = $realExitCode
                Output    = @($realOutput)
                FirstLine = $firstLine
                HasOutput = $null -ne $firstLine
            }
        }

        # When called from git root with --show-prefix failing,
        # all repo files should be returned (root IS the scope).
        $scanPlan = Get-ScannableFiles -scanRoot $script:testRoot
        $relativeFiles = @(
            $scanPlan.Files |
                ForEach-Object { Get-CanonicalRelativePath -BasePath $script:testRoot -TargetPath $_.FullName } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $relativeFiles | Should -Contain "root.txt" -Because "files at git root must be included when scanning from root"
        $relativeFiles | Should -Contain "src/nested.txt" -Because "nested files must be included when scanning from root"
    }

    It "streams files from the discovery plan without materializing eager scan arrays" {
        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        Initialize-TestGitRepository -RepositoryRoot $script:testRoot

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "src")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "src/a.txt"), "a")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "src/b.txt"), "b")

        $scanPlan = Resolve-ScannableFileDiscovery -scanRoot $script:testRoot
        $relativeFiles = @(
            Get-ScannableFileStream -scanPlan $scanPlan |
                ForEach-Object { Get-CanonicalRelativePath -BasePath $script:testRoot -TargetPath $_.FullName } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $scanPlan.Diagnostics | Should -Match 'listedPaths=deferred'
        $relativeFiles | Should -Contain "src/a.txt"
        $relativeFiles | Should -Contain "src/b.txt"
    }

    It "fails safely when .gitignore exists but git discovery is unavailable (<Scenario>)" -TestCases @(
        @{
            Scenario            = "scan root"
            ScanRootRelative    = "."
            GitIgnoreRelative   = ".gitignore"
            CreateGitRepoMarker = $false
        },
        @{
            Scenario            = "ancestor within repository boundary"
            ScanRootRelative    = "src"
            GitIgnoreRelative   = ".gitignore"
            CreateGitRepoMarker = $true
        }
    ) {
        param(
            [string]$Scenario,
            [string]$ScanRootRelative,
            [string]$GitIgnoreRelative,
            [bool]$CreateGitRepoMarker
        )

        if ($CreateGitRepoMarker) {
            [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".git")) | Out-Null
        }

        if ($ScanRootRelative -ne ".") {
            [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath $ScanRootRelative)) | Out-Null
        }

        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath $GitIgnoreRelative), ".venv/`n")
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".venv")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".venv/ignored.txt"), "ignored")

        $scanRoot = if ($ScanRootRelative -eq ".") {
            $script:testRoot
        }
        else {
            Join-Path -Path $script:testRoot -ChildPath $ScanRootRelative
        }

        Mock -CommandName Get-Command -MockWith { $null }

        {
            Get-ScannableFiles -scanRoot $scanRoot
        } | Should -Throw "E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED*" -Because "Scenario '$Scenario' must refuse fallback when repository ignore semantics would be unsafe."

        try {
            Get-ScannableFiles -scanRoot $scanRoot | Out-Null
            throw "E_TEST_EXPECTED_FAILURE: Scenario '$Scenario' should have thrown E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED."
        }
        catch {
            $_.Exception.Message | Should -Match 'fallbackScope=' -Because "Scenario '$Scenario' should include fallback scope diagnostics in failure paths."
            $_.Exception.Message | Should -Match 'checkedAncestors=' -Because "Scenario '$Scenario' should include ancestor-check diagnostics in failure paths."
        }
    }

    It "keeps non-repository fallback scoped to the requested scan root" {
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "parent/child")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "parent/.gitignore"), "*.tmp`n")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "parent/child/keep.txt"), "keep")

        $scanRoot = Join-Path -Path $script:testRoot -ChildPath "parent/child"

        Mock -CommandName Get-Command -MockWith { $null }

        $scanPlan = Get-ScannableFiles -scanRoot $scanRoot

        $scanPlan.Mode | Should -Be "filesystem-fallback"
        $scanPlan.Diagnostics | Should -Match 'fallbackScope=scan-root-only'
        $scanPlan.Diagnostics | Should -Match 'checkedAncestors=1'
        $scanPlan.Files.Count | Should -Be 1
        $scanPlan.Files[0].Name | Should -Be "keep.txt"
    }

    It "reports repository ancestor fallback diagnostics when .git boundary is detected" {
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".git")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "src/leaf")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "src/leaf/keep.txt"), "keep")

        $scanRoot = Join-Path -Path $script:testRoot -ChildPath "src/leaf"

        Mock -CommandName Get-Command -MockWith { $null }

        $scanPlan = Get-ScannableFiles -scanRoot $scanRoot

        $scanPlan.Mode | Should -Be "filesystem-fallback"
        $scanPlan.Diagnostics | Should -Match 'fallbackScope=repository-ancestors'
        $scanPlan.Diagnostics | Should -Match 'checkedAncestors=3'
        $scanPlan.Diagnostics | Should -Match 'gitBoundary='
    }
}

Describe "Remove-BOM core behavior" {
    BeforeEach {
        $script:topLevelAliasCache = @{}
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("remove-bom-core-tests-" + [System.Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($script:testRoot) | Out-Null
        $script:testRoot = Resolve-CanonicalTempRoot -Path $script:testRoot
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot -PathType Container) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It "removes a UTF-8 BOM and writes back as UTF-8 without BOM" {
        $filePath = Join-Path -Path $script:testRoot -ChildPath "bom.txt"
        [System.IO.File]::WriteAllText($filePath, "hello world", [System.Text.UTF8Encoding]::new($true))

        $changed = Remove-BOMFromFile -filePath $filePath
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)

        $changed | Should -BeTrue
        $bytes.Length | Should -BeGreaterThan 0
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $content | Should -Be "hello world"
    }

    It "does not modify files that do not have a UTF-8 BOM" {
        $filePath = Join-Path -Path $script:testRoot -ChildPath "no-bom.txt"
        [System.IO.File]::WriteAllText($filePath, "plain text", [System.Text.UTF8Encoding]::new($false))
        $bytesBefore = [System.IO.File]::ReadAllBytes($filePath)

        $changed = Remove-BOMFromFile -filePath $filePath
        $bytesAfter = [System.IO.File]::ReadAllBytes($filePath)

        $changed | Should -BeFalse
        $bytesAfter | Should -Be $bytesBefore
    }

    It "treats files with null bytes as binary and skips BOM removal" {
        $filePath = Join-Path -Path $script:testRoot -ChildPath "binary.bin"
        [System.IO.File]::WriteAllBytes($filePath, [byte[]](0x00, 0x01, 0x02, 0x03, 0x00))

        $isBinary = Test-IsBinaryFile -filePath $filePath
        $changed = Remove-BOMFromFile -filePath $filePath

        $isBinary | Should -BeTrue
        $changed | Should -BeFalse
    }
}
