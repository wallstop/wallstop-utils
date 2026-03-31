Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:removeBomScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Remove-BOM.ps1"
    $script:gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue

    . $script:removeBomScriptPath

    function Resolve-CanonicalTempRoot {
        param([string]$Path)
        # On macOS, GetTempPath() returns /var/folders/... (symlink) but FileInfo.FullName
        # resolves to /private/var/folders/... (canonical). Get-Item.FullName matches this
        # platform-specific resolution, ensuring GetRelativePath produces correct results.
        # On Linux/Windows this is a no-op (no symlink aliasing in standard temp paths).
        return (Get-Item -LiteralPath $Path).FullName
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
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("remove-bom-tests-" + [System.Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($script:testRoot) | Out-Null
        $script:testRoot = Resolve-CanonicalTempRoot -Path $script:testRoot
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot -PathType Container) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
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
                ForEach-Object { [System.IO.Path]::GetRelativePath($script:testRoot, $_.FullName) -replace '\\', '/' } |
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
                ForEach-Object { [System.IO.Path]::GetRelativePath($script:testRoot, $_.FullName) -replace '\\', '/' } |
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
                ForEach-Object { [System.IO.Path]::GetRelativePath($script:testRoot, $_.FullName) -replace '\\', '/' } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $relativeFiles | Should -Be @("left/a.txt") -Because "files outside the requested scan root must not leak through even when --show-prefix fails"
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
                ForEach-Object { [System.IO.Path]::GetRelativePath($script:testRoot, $_.FullName) -replace '\\', '/' } |
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
                ForEach-Object { [System.IO.Path]::GetRelativePath($script:testRoot, $_.FullName) -replace '\\', '/' } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $scanPlan.Diagnostics | Should -Match 'listedPaths=deferred'
        $relativeFiles | Should -Contain "src/a.txt"
        $relativeFiles | Should -Contain "src/b.txt"
    }

    It "fails safely when .gitignore exists but git discovery is unavailable" {
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".gitignore"), ".venv/`n")
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".venv")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".venv/ignored.txt"), "ignored")

        Mock -CommandName Get-Command -MockWith { $null }

        {
            Get-ScannableFiles -scanRoot $script:testRoot
        } | Should -Throw "E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED*"
    }
}

Describe "Remove-BOM core behavior" {
    BeforeEach {
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
