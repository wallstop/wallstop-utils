Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..") -ErrorAction Stop).Path
    $script:helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/PreCommitCliHelpers.ps1"
    $script:helperContent = [System.IO.File]::ReadAllText($script:helperPath, [System.Text.Encoding]::UTF8)
    . $script:helperPath

    function Get-TestManagedPreCommitExecutable {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ToolBinDirectory
        )

        $preCommitExecutableName = if (Test-IsWindowsPlatform) { "pre-commit.exe" } else { "pre-commit" }
        return (Join-Path -Path $ToolBinDirectory -ChildPath $preCommitExecutableName)
    }
}

Describe "PreCommitCliHelpers" {
    It "reads an exact pre-commit pin with comments and CRLF line endings" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $requirementsPath = Join-Path -Path $repoRoot -ChildPath "requirements.txt"
        [System.IO.File]::WriteAllText($requirementsPath, "pre-commit==4.6.0 # pinned`r`n", [System.Text.UTF8Encoding]::new($false))

        Get-RequiredPreCommitVersion -RepositoryRoot $repoRoot | Should -Be "4.6.0"
    }

    It "throws a stable diagnostic when requirements.txt is missing" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        { Get-RequiredPreCommitVersion -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_REQUIREMENTS_MISSING*"
    }

    It "throws a stable diagnostic when requirements.txt lacks an exact pre-commit pin" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $requirementsPath = Join-Path -Path $repoRoot -ChildPath "requirements.txt"
        [System.IO.File]::WriteAllText($requirementsPath, "pre-commit>=4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        { Get-RequiredPreCommitVersion -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_REQUIREMENTS_INVALID*"
    }

    It "returns fallback bootstrap guidance when the pre-commit pin cannot be resolved" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        $guidance = Get-PreCommitBootstrapVersionGuidance -RepositoryRoot $repoRoot

        $guidance.Version | Should -Be "<pinned-version-from-requirements.txt>"
        $guidance.IsFallback | Should -BeTrue
        $guidance.RequirementsDiagnostic | Should -Match "E_VALIDATION_PRECOMMIT_REQUIREMENTS_MISSING"
    }

    It "returns exact bootstrap guidance when the pre-commit pin can be resolved" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $requirementsPath = Join-Path -Path $repoRoot -ChildPath "requirements.txt"
        [System.IO.File]::WriteAllText($requirementsPath, "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        $guidance = Get-PreCommitBootstrapVersionGuidance -RepositoryRoot $repoRoot

        $guidance.Version | Should -Be "4.6.0"
        $guidance.IsFallback | Should -BeFalse
        $guidance.RequirementsDiagnostic | Should -Be ""
    }

    It "joins command stdout and stderr as scalar text for diagnostic previews" {
        $joinedOutput = Join-PreCommitCommandOutput -Stdout "first line" -Stderr "second line"

        $joinedOutput | Should -Be ("first line{0}second line" -f [Environment]::NewLine)
        Get-PreCommitFailureOutputPreview -Output $joinedOutput | Should -Be "first line second line"
    }

    It "does not pass array literals directly to pre-commit output preview diagnostics" {
        $script:helperContent | Should -Not -Match 'Get-PreCommitFailureOutputPreview\s+-Output\s+\(@\('
        $script:helperContent | Should -Match 'Join-PreCommitCommandOutput'
    }

    It "pins the pre-commit pyz fallback hash for the repo-required version" {
        Get-PreCommitPyzSha256 -Version "4.6.0" | Should -Be "ea8a0c84902e48c1875558f2f362ed8476773aa5fc8c16c5d8f2acc2a2830a65"
    }

    It "skips pyz fallback when no hash is pinned for the requested version" {
        $result = Install-PreCommitPyzFallback -RepositoryRoot $script:repoRoot -ExpectedVersion "0.0.0" -DeadlineUtc ([datetime]::UtcNow.AddSeconds(30))

        $result.Succeeded | Should -BeFalse
        $expectedDiagnosticPattern = if (Test-IsWindowsPlatform) {
            "direct \.pyz execution is not portable"
        }
        else {
            "no pinned SHA256"
        }
        @($result.Diagnostics) -join "`n" | Should -Match $expectedDiagnosticPattern
    }

    It "verifies cached pre-commit pyz hashes before adding them as executable candidates" {
        $script:helperContent | Should -Match 'Get-PreCommitPyzSha256'
        $script:helperContent | Should -Match 'Get-FileHash\s+-LiteralPath\s+\$pyzCandidate\.FullName\s+-Algorithm\s+SHA256'
        $script:helperContent | Should -Match '\$actualPyzHash\s+-eq\s+\$expectedPyzHash'
    }

    It "pins repo-managed uv native assets for pre-commit CLI auto-repair" {
        $manifest = Read-PreCommitCliToolManifest

        $manifest.tools.uv.version | Should -Be "0.11.21"

        $actualAssetKeys = @($manifest.tools.uv.assets.PSObject.Properties.Name | Sort-Object)
        $actualAssetKeys | Should -Be @("darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-arm64", "windows-x64")
        foreach ($assetProperty in @($manifest.tools.uv.assets.PSObject.Properties)) {
            $asset = $assetProperty.Value
            $asset.assetName | Should -Not -BeNullOrEmpty
            $asset.kind | Should -Match '^(zip|tar\.gz)$'
            $asset.sha256 | Should -Match '^[a-f0-9]{64}$'
        }
    }

    It "uses repo-managed uv when uv is missing from PATH during auto-repair" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $script:resolvedUvPath = Join-Path -Path $repoRoot -ChildPath "uv"
        $script:uvInstallExecutable = ""
        $script:uvInstallArguments = @()
        $script:uvInstallEnvironment = @{}
        $script:uvProbeExecutable = ""

        Mock Get-Command {
            return $null
        } -ParameterFilter { $Name -eq "uv" }

        Mock Resolve-PreCommitCliUvExecutable {
            param($RepositoryRoot)

            $RepositoryRoot | Should -Be $repoRoot
            return $script:resolvedUvPath
        }

        Mock Invoke-PreCommitExternalCommand {
            param($Executable, $Arguments, $RepositoryRoot, $TimeoutSeconds, $ContextLabel, $Environment)

            $script:uvInstallExecutable = $Executable
            $script:uvInstallArguments = @($Arguments)
            $script:uvInstallEnvironment = $Environment
            $RepositoryRoot | Should -Be $repoRoot
            $TimeoutSeconds | Should -BeGreaterThan 0
            $ContextLabel | Should -Match '^uv tool install pre-commit==4\.6\.0$'
            $expectedUvStateSuffix = Join-Path -Path (Join-Path -Path ".tools" -ChildPath "precommit-cli") -ChildPath "uv-state"
            ([string]$Environment.UV_CACHE_DIR).EndsWith((Join-Path -Path $expectedUvStateSuffix -ChildPath "cache"), [System.StringComparison]::Ordinal) | Should -BeTrue
            ([string]$Environment.UV_TOOL_DIR).EndsWith((Join-Path -Path $expectedUvStateSuffix -ChildPath "tools"), [System.StringComparison]::Ordinal) | Should -BeTrue
            ([string]$Environment.UV_TOOL_BIN_DIR).EndsWith((Join-Path -Path $expectedUvStateSuffix -ChildPath "bin"), [System.StringComparison]::Ordinal) | Should -BeTrue
            $Environment.UV_NO_MODIFY_PATH | Should -Be "1"

            $preCommitExecutable = Get-TestManagedPreCommitExecutable -ToolBinDirectory ([string]$Environment.UV_TOOL_BIN_DIR)
            [System.IO.File]::WriteAllText($preCommitExecutable, "shim", [System.Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
            }
        } -ParameterFilter { $ContextLabel -like "uv tool install pre-commit==*" }

        Mock Get-PreCommitVersionProbeClassification {
            param($PreCommitExecutable, $RepositoryRoot, $ExpectedVersion, $TimeoutSeconds)

            $script:uvProbeExecutable = $PreCommitExecutable
            $RepositoryRoot | Should -Be $repoRoot
            $ExpectedVersion | Should -Be "4.6.0"
            $TimeoutSeconds | Should -BeGreaterThan 0
            return [pscustomobject]@{
                Status        = "ok"
                ActualVersion = "4.6.0"
                Diagnostic    = ""
            }
        }

        $result = Invoke-PreCommitCliAutoRepair -RepositoryRoot $repoRoot -ExpectedVersion "4.6.0" -TimeoutSeconds 30

        $result.Succeeded | Should -BeTrue
        $result.Strategy | Should -Be "uv-tool-install"
        $script:uvInstallExecutable | Should -Be $script:resolvedUvPath
        $script:uvInstallArguments | Should -Be @("tool", "install", "--force", "pre-commit==4.6.0")
        $result.RepairedExecutable | Should -Be (Get-TestManagedPreCommitExecutable -ToolBinDirectory ([string]$script:uvInstallEnvironment.UV_TOOL_BIN_DIR))
        $script:uvProbeExecutable | Should -Be $result.RepairedExecutable
    }

    It "tries repo-managed uv when ambient uv exists but fails during auto-repair" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $script:ambientUvPath = Join-Path -Path $repoRoot -ChildPath "ambient-uv"
        $script:managedUvPath = Join-Path -Path $repoRoot -ChildPath "managed-uv"
        $script:uvAttempts = New-Object System.Collections.Generic.List[string]
        $script:uvProbeExecutable = ""

        Mock Get-Command {
            return [pscustomobject]@{
                Source = $script:ambientUvPath
            }
        } -ParameterFilter { $Name -eq "uv" }

        Mock Resolve-PreCommitCliUvExecutable {
            param($RepositoryRoot)

            $RepositoryRoot | Should -Be $repoRoot
            return $script:managedUvPath
        }

        Mock Invoke-PreCommitExternalCommand {
            param($Executable, $Arguments, $RepositoryRoot, $TimeoutSeconds, $ContextLabel, $Environment)

            $script:uvAttempts.Add($Executable) | Out-Null
            $ContextLabel | Should -Match '^uv tool install pre-commit==4\.6\.0$'
            if ($Executable -eq $script:ambientUvPath) {
                return [pscustomobject]@{
                    ExitCode = 2
                    Stdout   = ""
                    Stderr   = "ambient uv broken"
                }
            }

            $preCommitExecutable = Get-TestManagedPreCommitExecutable -ToolBinDirectory ([string]$Environment.UV_TOOL_BIN_DIR)
            [System.IO.File]::WriteAllText($preCommitExecutable, "shim", [System.Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
            }
        } -ParameterFilter { $ContextLabel -like "uv tool install pre-commit==*" }

        Mock Get-PreCommitVersionProbeClassification {
            param($PreCommitExecutable, $RepositoryRoot, $ExpectedVersion, $TimeoutSeconds)

            $script:uvProbeExecutable = $PreCommitExecutable
            $RepositoryRoot | Should -Be $repoRoot
            $ExpectedVersion | Should -Be "4.6.0"
            $TimeoutSeconds | Should -BeGreaterThan 0
            return [pscustomobject]@{
                Status        = "ok"
                ActualVersion = "4.6.0"
                Diagnostic    = ""
            }
        }

        $result = Invoke-PreCommitCliAutoRepair -RepositoryRoot $repoRoot -ExpectedVersion "4.6.0" -TimeoutSeconds 30

        $result.Succeeded | Should -BeTrue
        $result.Strategy | Should -Be "uv-tool-install"
        @($script:uvAttempts) | Should -Be @($script:ambientUvPath, $script:managedUvPath)
        $script:uvProbeExecutable | Should -Be $result.RepairedExecutable
    }

    It "does not report uv auto-repair success until the repaired executable passes a version probe" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $script:resolvedUvPath = Join-Path -Path $repoRoot -ChildPath "uv"

        Mock Get-Command {
            return $null
        }

        Mock Resolve-PreCommitCliUvExecutable {
            return $script:resolvedUvPath
        }

        Mock Invoke-PreCommitExternalCommand {
            param($Executable, $Arguments, $RepositoryRoot, $TimeoutSeconds, $ContextLabel, $Environment)

            $preCommitExecutable = Get-TestManagedPreCommitExecutable -ToolBinDirectory ([string]$Environment.UV_TOOL_BIN_DIR)
            [System.IO.File]::WriteAllText($preCommitExecutable, "shim", [System.Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = ""
                Stderr   = ""
            }
        } -ParameterFilter { $ContextLabel -like "uv tool install pre-commit==*" }

        Mock Get-PreCommitVersionProbeClassification {
            return [pscustomobject]@{
                Status        = "parse_failed"
                ActualVersion = ""
                Diagnostic    = "E_VALIDATION_PRECOMMIT_VERSION_PARSE_FAILED: simulated bad shim"
            }
        }

        $result = Invoke-PreCommitCliAutoRepair -RepositoryRoot $repoRoot -ExpectedVersion "4.6.0" -TimeoutSeconds 30

        $result.Succeeded | Should -BeFalse
        @($result.Diagnostics) -join "`n" | Should -Match "version probe did not pass"
        @($result.Diagnostics) -join "`n" | Should -Match "simulated bad shim"
    }

    It "uses bounded subprocess stream capture helpers for pre-commit CLI subprocesses" {
        $script:helperContent | Should -Match 'Read-PreCommitProcessOutputTaskBounded'
        $script:helperContent | Should -Match 'Join-PreCommitCaptureDiagnostics'
        $script:helperContent | Should -Match 'function Invoke-PreCommitExternalCommand \{[\s\S]*Read-PreCommitProcessOutputTaskBounded[\s\S]*function Get-PreCommitCandidateExecutablePaths'
        $script:helperContent | Should -Match 'function Invoke-PreCommitVersionProbe \{[\s\S]*Read-PreCommitProcessOutputTaskBounded[\s\S]*function Assert-PreCommitCliVersion'
    }

    It "uses a repo-managed pre-commit home for host-cache-independent subprocesses" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null

        $environment = Get-PreCommitManagedEnvironment -RepositoryRoot $repoRoot

        $expectedHome = Join-Path -Path $repoRoot -ChildPath ".tools/precommit-cli/pre-commit-home"
        $environment.PRE_COMMIT_HOME | Should -Be $expectedHome
        Test-Path -LiteralPath $expectedHome -PathType Container | Should -BeTrue
    }

    It "discovers the repo-managed uv-installed pre-commit candidate after auto-repair" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        $managedPreCommitName = if (Test-IsWindowsPlatform) { "pre-commit.exe" } else { "pre-commit" }
        $managedPreCommitPath = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath ".tools/precommit-cli/uv-state/bin") -ChildPath $managedPreCommitName

        $candidates = @(Get-PreCommitCandidateExecutablePaths -RepositoryRoot $repoRoot)

        $candidates | Should -Contain $managedPreCommitPath
    }

    It "accepts a matching pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "pre-commit 4.6.0"
                Stderr   = ""
            }
        }

        $result = Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot

        $result.ExpectedVersion | Should -Be "4.6.0"
        $result.ActualVersion | Should -Be "4.6.0"
    }

    It "passes explicit timeout to the pre-commit version probe" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))
        $script:capturedVersionProbeTimeout = 0

        Mock Invoke-PreCommitVersionProbe {
            param($PreCommitExecutable, $RepositoryRoot, $TimeoutSeconds)

            $script:capturedVersionProbeTimeout = [int]$TimeoutSeconds
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "pre-commit 4.6.0"
                Stderr   = ""
            }
        }

        [void](Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot -TimeoutSeconds 17)

        $script:capturedVersionProbeTimeout | Should -Be 17
    }

    It "rejects a mismatching pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "pre-commit 4.5.0"
                Stderr   = ""
            }
        }

        { Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_VERSION_MISMATCH*"
    }

    It "rejects an unparseable pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 0
                Stdout   = "unexpected version output"
                Stderr   = ""
            }
        }

        { Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_VERSION_PARSE_FAILED*"
    }

    It "rejects a nonzero pre-commit --version result" {
        $repoRoot = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "requirements.txt"), "pre-commit==4.6.0`n", [System.Text.UTF8Encoding]::new($false))

        Mock Invoke-PreCommitVersionProbe {
            return [pscustomobject]@{
                ExitCode = 2
                Stdout   = ""
                Stderr   = "failed"
            }
        }

        { Assert-PreCommitCliVersion -PreCommitExecutable "pre-commit" -RepositoryRoot $repoRoot } |
            Should -Throw -ExpectedMessage "*E_VALIDATION_PRECOMMIT_VERSION_FAILED*"
    }
}
