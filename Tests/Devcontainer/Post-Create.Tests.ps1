Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1")

    $script:postCreatePath = Join-Path -Path $script:repoRoot -ChildPath ".devcontainer/post-create.sh"
    $script:postCreateContent = Get-Content -Path $script:postCreatePath -Raw
    $script:devcontainerWorkflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/devcontainer-validate.yml"
    $script:devcontainerWorkflowContent = Get-Content -Path $script:devcontainerWorkflowPath -Raw

    $script:preCommitHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-commit"
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:preCommitHookContent = Get-Content -Path $script:preCommitHookPath -Raw
    $script:prePushHookContent = Get-Content -Path $script:prePushHookPath -Raw
    $script:getBashFunctionBlock = {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Content,

            [Parameter(Mandatory = $true)]
            [string]$FunctionName
        )

        $lines = $Content -split "`n"
        $escapedName = [Regex]::Escape($FunctionName)
        $startLine = -1

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*${escapedName}\(\)\s*\{") {
                $startLine = $i
                break
            }
        }

        if ($startLine -lt 0) {
            throw "Function '${FunctionName}' was not found."
        }

        $endLine = $lines.Count - 1
        for ($i = $startLine + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{') {
                $endLine = $i - 1
                break
            }
        }

        return ($lines[$startLine..$endLine] -join "`n")
    }

    $script:getWorkflowStepBlock = {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Content,

            [Parameter(Mandatory = $true)]
            [string]$StepName
        )

        $lines = $Content -split "`n"
        $escapedName = [Regex]::Escape($StepName)
        $startLine = -1

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*-\s+name:\s+${escapedName}\s*$") {
                $startLine = $i
                break
            }
        }

        if ($startLine -lt 0) {
            throw "Workflow step '${StepName}' was not found."
        }

        $endLine = $lines.Count - 1
        for ($i = $startLine + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*-\s+name:\s+') {
                $endLine = $i - 1
                break
            }
        }

        return ($lines[$startLine..$endLine] -join "`n")
    }
}

Describe "post-create.sh file structure" {
    It "exists at .devcontainer/post-create.sh" {
        $script:postCreatePath | Should -Exist
    }

    It "has a bash shebang as the first line" {
        $firstLine = ($script:postCreateContent -split "`n")[0]
        $firstLine | Should -Match '^#!/usr/bin/env bash'
    }

    It "enables strict error handling with set -euo pipefail" {
        $script:postCreateContent | Should -Match 'set\s+-euo\s+pipefail'
    }

    It "uses [devcontainer] log prefix conventions throughout" {
        $script:postCreateContent | Should -Match '\[devcontainer\]'
    }
}

Describe "post-create.sh pip safety anti-regression" {
    It "does not use the original unsafe pip install --user --upgrade pattern" {
        # Regression guard: the original script used raw pip install --user which fails
        # on Ubuntu 24.04 due to PEP 668 (externally-managed-environment).
        $script:postCreateContent | Should -Not -Match 'pip\s+install\s+--user\s+--upgrade\s+pip\s+pre-commit'
    }

    It "uses pipx as a primary pre-commit installation strategy" {
        $script:postCreateContent | Should -Match 'pipx'
    }

    It "uses a dedicated Python venv as a fallback installation strategy" {
        $script:postCreateContent | Should -Match 'venv'
    }

    It "marks --break-system-packages only as a nuclear or last-resort fallback (proximity check)" {
        # Regression guard: --break-system-packages must appear ADJACENT to a nuclear/fallback label,
        # not as an unlabelled occurrence somewhere in the file. We check that a comment line
        # containing a nuclear/fallback keyword appears within 5 lines of the flag.
        $lines = $script:postCreateContent -split "`n"
        $breakLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '--break-system-packages') {
                $breakLine = $i
                break
            }
        }
        $breakLine | Should -Not -Be -1 -Because "--break-system-packages must be present in the script"

        # Check within a 5-line window before/after the flag for a nuclear/fallback label.
        $windowStart = [Math]::Max(0, $breakLine - 5)
        $windowEnd = [Math]::Min($lines.Count - 1, $breakLine + 5)
        $window = $lines[$windowStart..$windowEnd] -join "`n"
        $window | Should -Match '(?i)(nuclear|fallback|last.resort)' `
            -Because "--break-system-packages must be clearly labelled as a nuclear/last-resort fallback in a nearby comment"
    }
}

Describe "post-create.sh PATH persistence" {
    It "persists ~/.local/bin to ~/.bashrc" {
        $script:postCreateContent | Should -Match '\.bashrc'
    }

    It "persists ~/.local/bin to ~/.profile" {
        $script:postCreateContent | Should -Match '\.profile'
    }

    It "guards PATH persistence against duplicate entries" {
        # Must check whether the entry already exists before appending.
        $script:postCreateContent | Should -Match 'grep\s+.*HOME/.local/bin'
    }
}

Describe "post-create.sh pre-commit integration" {
    It "calls pre-commit install" {
        $script:postCreateContent | Should -Match 'pre-commit\s+install'
    }

    It "pre-warms pre-commit hook environments during install" {
        # Accept either the combined `install --install-hooks` form or the dedicated
        # `install-hooks` subcommand; the bootstrap uses the latter to pre-warm environments.
        $script:postCreateContent | Should -Match 'pre-commit\s+install(\s+--install-hooks\b|-hooks\b)'
        $script:postCreateContent | Should -Match 'WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS'
        $script:postCreateContent | Should -Match 'precommit_prewarm_shutdown_buffer_seconds=15'
        $script:postCreateContent | Should -Match '_run_with_timeout\s+"\$\{precommit_prewarm_timeout_seconds\}"\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Quality/Invoke-PreCommitWithRecovery\.ps1\s+-InstallHooksOnly\s+-TimeoutSeconds\s+"\$\{precommit_prewarm_inner_timeout_seconds\}"'
        $script:postCreateContent | Should -Match '_run_with_timeout\s+"\$\{precommit_prewarm_timeout_seconds\}"\s+pre-commit\s+install-hooks'
    }

    It "configures core.hooksPath to .githooks" {
        $script:postCreateContent | Should -Match 'core\.hooksPath'
        $script:postCreateContent | Should -Match '\.githooks'
    }

    It "uses the shared hook registration preflight when PowerShell is available" {
        $script:postCreateContent | Should -Match 'GitHookRegistrationHelpers\.ps1'
        $script:postCreateContent | Should -Match 'Assert-GitHookRegistration\s+-RepositoryRoot\s+''\.''\s+-Repair'
        $script:postCreateContent | Should -Match 'falling back to direct core\.hooksPath repair'
        $script:postCreateContent | Should -Match 'git\s+-C\s+"\$\{ROOT_DIR\}"\s+config\s+--local\s+core\.hooksPath\s+\.githooks'
    }

    It "installs the pinned pre-commit CLI from requirements.txt" {
        $script:postCreateContent | Should -Match '_required_precommit_version\(\)'
        $script:postCreateContent | Should -Match '_precommit_version_matches_pin\(\)'
        $script:postCreateContent | Should -Match '_ensure_precommit_cli_ready\(\)'
        $script:postCreateContent | Should -Match 'pre-commit==\$\{required_version\}'
        $script:postCreateContent | Should -Match '--requirement\s+"\$\{ROOT_DIR\}/requirements\.txt"'
    }

    It "rechecks the pinned pre-commit CLI after reinstall before registering hooks" {
        $ensurePreCommitBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_ensure_precommit_cli_ready"
        $installIndex = $ensurePreCommitBody.IndexOf('_install_precommit "${required_version}"', [System.StringComparison]::Ordinal)
        $recheckIndex = $ensurePreCommitBody.IndexOf('_precommit_version_matches_pin "${required_version}"', [Math]::Max($installIndex, 0) + 1, [System.StringComparison]::Ordinal)
        $registrationIndex = $script:postCreateContent.IndexOf('if [[ "${precommit_cli_ready}" -eq 1 ]]; then', [System.StringComparison]::Ordinal)
        $ensureCallIndex = $script:postCreateContent.IndexOf('if _ensure_precommit_cli_ready "${required_precommit_version}"; then', [System.StringComparison]::Ordinal)

        $installIndex | Should -BeGreaterOrEqual 0 -Because "pre-commit install must run through the readiness helper"
        $recheckIndex | Should -BeGreaterThan $installIndex -Because "bootstrap must verify the CLI on PATH after reinstall"
        $ensurePreCommitBody | Should -Match 'E_DEVCONTAINER_PRECOMMIT_VERSION_DRIFT'
        $script:postCreateContent | Should -Match 'precommit_cli_ready=0'
        $ensureCallIndex | Should -BeGreaterOrEqual 0 -Because "main flow must set readiness from the helper result"
        $registrationIndex | Should -BeGreaterThan $ensureCallIndex -Because "hook registration must wait for pinned CLI verification"
    }

    It "registers both pre-commit and pre-push hook types" {
        $script:postCreateContent | Should -Match '--hook-type\s+pre-commit'
        $script:postCreateContent | Should -Match '--hook-type\s+pre-push'
    }

    It "does not unconditionally print 'hooks installed' when pre-commit install may have failed" {
        # The success message must be conditional (inside an if block), not printed after || true.
        $script:postCreateContent | Should -Not -Match 'pre-commit\s+install.*\|\|\s*true'
    }
}

Describe "post-create.sh validation preflight integration" {
    It "runs Invoke-FullValidation preflight after bootstrap" {
        $script:postCreateContent | Should -Match 'Invoke-FullValidation\.ps1\s+-PreflightOnly'
    }

    It "keeps validation preflight non-blocking with a warning path" {
        $script:postCreateContent | Should -Match 'Validation preflight failed'
    }

    It "keeps timeout execution bounded even when timeout/gtimeout is unavailable" {
        $runWithTimeoutBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_run_with_timeout"
        $validateTimeoutBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_validate_timeout_seconds"

        $script:postCreateContent | Should -Match '_validate_timeout_seconds\(\)'
        $validateTimeoutBody | Should -Match 'E_HOOK_TIMEOUT_CONFIG'
        $runWithTimeoutBody | Should -Match 'using shell watchdog timeout'
        $runWithTimeoutBody | Should -Match 'sleep\s+"\$\{timeout_seconds\}"'
        $script:postCreateContent | Should -Match 'HookTimeout\.sh'
        $runWithTimeoutBody | Should -Match 'wallstop_start_timeout_command'
        $runWithTimeoutBody | Should -Match 'wallstop_terminate_timeout_command'
        $runWithTimeoutBody | Should -Match 'wallstop_cleanup_timeout_command_processes'
        $runWithTimeoutBody | Should -Not -Match 'kill\s+-TERM\s+"\$\{command_pid\}"'
        $runWithTimeoutBody | Should -Not -Match 'kill\s+-KILL\s+"\$\{command_pid\}"'
        $runWithTimeoutBody | Should -Match 'E_HOOK_TIMEOUT'
        $runWithTimeoutBody | Should -Not -Match 'running command without timeout guard'
    }
}

Describe "post-create.sh ripgrep installation" {
    It "defines a dedicated ripgrep install function" {
        $script:postCreateContent | Should -Match '_install_ripgrep\(\)\s*\{'
    }

    It "checks whether ripgrep is already available before installation" {
        $script:postCreateContent | Should -Match 'command\s+-v\s+rg'
    }

    It "guards ripgrep install with apt-get and sudo checks" {
        $script:postCreateContent | Should -Match 'apt-get\s+not\s+available;\s+cannot\s+install\s+ripgrep'
        $script:postCreateContent | Should -Match '_can_use_sudo_non_interactive'
    }

    It "verifies ripgrep is available after installation" {
        $script:postCreateContent | Should -Match 'ripgrep\s+not\s+found\s+after\s+installation'
    }

    It "invokes ripgrep install before pre-commit install block" {
        $lines = $script:postCreateContent -split "`n"
        $ripgrepCallLine = -1
        $preCommitCheckLine = -1

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '_install_ripgrep\s*\|\|\s*_warn' -and $ripgrepCallLine -eq -1) {
                $ripgrepCallLine = $i
            }
            if ($lines[$i] -match '^required_precommit_version=' -and $preCommitCheckLine -eq -1) {
                $preCommitCheckLine = $i
            }
        }

        $ripgrepCallLine | Should -Not -Be -1 -Because "Main flow must call _install_ripgrep"
        $preCommitCheckLine | Should -Not -Be -1 -Because "Main flow must check pre-commit availability"
        $ripgrepCallLine | Should -BeLessThan $preCommitCheckLine `
            -Because "ripgrep bootstrap should run before pre-commit install decision"
    }
}

Describe "post-create.sh Codex CLI bootstrap" {
    BeforeAll {
        $script:ensureNpmOnPathBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_ensure_npm_on_path"
        $script:testCodexPathIsLocalBinEntryBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_test_codex_path_is_local_bin_entry"
        $script:resolveCodexNpmPackageBinBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_resolve_codex_npm_package_bin"
        $script:testCodexLocalBinIsNpmManagedBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_test_codex_local_bin_is_npm_managed"
        $script:resolveCodexNpmGlobalBinBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_resolve_codex_npm_global_bin"
        $script:resolveCodexPathWithoutLocalBinBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_resolve_codex_path_without_local_bin"
        $script:installCodexCliBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_install_codex_cli"
        $script:linkCodexBody = & $script:getBashFunctionBlock -Content $script:postCreateContent -FunctionName "_link_codex_into_local_bin"
    }

    It "defines a dedicated Codex install function" {
        $script:postCreateContent | Should -Match '_install_codex_cli\(\)\s*\{'
        $script:postCreateContent | Should -Match '_resolve_codex_npm_package_bin\(\)\s*\{'
        $script:postCreateContent | Should -Match '_test_codex_local_bin_is_npm_managed\(\)\s*\{'
        $script:postCreateContent | Should -Match '_resolve_codex_npm_global_bin\(\)\s*\{'
        $script:postCreateContent | Should -Match '_resolve_codex_path_without_local_bin\(\)\s*\{'
        $script:postCreateContent | Should -Match '_link_codex_into_local_bin\(\)\s*\{'
    }

    It "installs @openai/codex using npm latest tag" {
        $script:installCodexCliBody | Should -Match '@openai/codex@latest'
        $script:installCodexCliBody | Should -Match 'npm\s+install\s+--global'
    }

    It "attempts npm PATH recovery from current node and standard nvm layouts when npm is missing" {
        $script:ensureNpmOnPathBody | Should -Match 'command\s+-v\s+node'
        $script:ensureNpmOnPathBody | Should -Match 'readlink\s+-f'
        $script:ensureNpmOnPathBody | Should -Match 'NVM_DIR'
        $script:ensureNpmOnPathBody | Should -Match '\$\{HOME\}/\.nvm'
        $script:ensureNpmOnPathBody | Should -Match '/usr/local/share/nvm'
        $script:ensureNpmOnPathBody | Should -Match 'nvm_roots\[@\]'
    }

    It "uses version-aware nvm fallback selection to avoid oldest npm path picks" {
        $script:ensureNpmOnPathBody | Should -Match 'best_npm_version'
        $script:ensureNpmOnPathBody | Should -Match 'best_npm_path'
        $script:ensureNpmOnPathBody | Should -Match 'sort\s+-V'
    }

    It "uses timeout-guarded bounded retries for npm Codex install" {
        $script:installCodexCliBody | Should -Match 'WALLSTOP_DEVCONTAINER_CODEX_NPM_TIMEOUT_SECONDS'
        $script:installCodexCliBody | Should -Match '_run_with_timeout\s+"\$\{npm_install_timeout_seconds\}"\s+npm\s+install\s+--global'
        $script:installCodexCliBody | Should -Match 'max_attempts=3'
        $script:installCodexCliBody | Should -Match 'attempt\s*<=\s*max_attempts'
        $script:installCodexCliBody | Should -Match 'Retrying Codex CLI npm install in'
    }

    It "guards against self-referential ~/.local/bin/codex symlink loops" {
        $script:linkCodexBody | Should -Match 'codex_source_path.*codex_link_path'
        $script:linkCodexBody | Should -Match 'readlink\s+"\$\{codex_link_path\}"'
        $script:linkCodexBody | Should -Match 'E_DEVCONTAINER_CODEX_LINK_FAILED'
        $script:linkCodexBody | Should -Match 'refusing to use \${codex_link_path} as its own link source'
        $script:linkCodexBody | Should -Match 'ln\s+-sfn\s+"\$\{codex_source_path\}"\s+"\$\{codex_link_path\}"'
        $script:linkCodexBody | Should -Match 'points to.*after link.*expected'
        $script:linkCodexBody | Should -Match 'not executable after linking'
    }

    It "accepts local npm-prefix Codex only when package metadata proves npm ownership" {
        $script:linkCodexBody | Should -Match 'refusing to use \${codex_link_path} as its own link source'
        $script:installCodexCliBody | Should -Not -Match '_link_codex_into_local_bin\s+"\$\{codex_path\}"\s+1'
        $script:resolveCodexNpmPackageBinBody | Should -Match 'npm root --global'
        $script:resolveCodexNpmPackageBinBody | Should -Match '@openai/codex'
        $script:resolveCodexNpmGlobalBinBody | Should -Match '_test_codex_local_bin_is_npm_managed'
        $script:installCodexCliBody | Should -Match '_test_codex_path_is_local_bin_entry'
    }

    It "prefers npm global binary resolution before PATH fallback without ~/.local/bin" {
        $prefixIndex = ($script:installCodexCliBody | Select-String '_resolve_codex_npm_global_bin' -AllMatches).Matches[0].Index
        $pathFallbackIndex = ($script:installCodexCliBody | Select-String '_resolve_codex_path_without_local_bin' -AllMatches).Matches[0].Index
        $prefixIndex | Should -BeLessThan $pathFallbackIndex `
            -Because "npm global resolution should run before PATH fallback to avoid stale ~/.local/bin/codex links"
        $pathFallbackIndex | Should -BeGreaterThan $prefixIndex
        $script:resolveCodexPathWithoutLocalBinBody | Should -Match 'command\s+-v\s+codex'
        $script:resolveCodexPathWithoutLocalBinBody | Should -Match 'local_bin_path="\$\{HOME\}/\.local/bin"'
        $script:installCodexCliBody | Should -Not -Match 'command\s+-v\s+codex'
    }

    It "does not report success from a local-bin npm prefix or symlinked local-bin PATH fallback" {
        $bash = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bash) {
            Set-ItResult -Skipped -Because "bash is unavailable on this runner."
            return
        }
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "Bash-level devcontainer bootstrap regression uses POSIX paths."
            return
        }

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("codex-link-regression-{0}" -f [guid]::NewGuid().ToString("N"))
        $homeRoot = Join-Path -Path $tempRoot -ChildPath "home"
        $localBin = Join-Path -Path $homeRoot -ChildPath ".local/bin"
        $localBinAlias = Join-Path -Path $tempRoot -ChildPath "local-bin-alias"
        $fakeBin = Join-Path -Path $tempRoot -ChildPath "fake-bin"
        $oldBin = Join-Path -Path $tempRoot -ChildPath "old/bin"
        $localPrefix = Join-Path -Path $homeRoot -ChildPath ".local"
        $runnerPath = Join-Path -Path $tempRoot -ChildPath "run-codex-install.sh"
        $fakeNpmPath = Join-Path -Path $fakeBin -ChildPath "npm"
        $nodeCommand = Get-Command -Name node -ErrorAction SilentlyContinue
        $oldCodexPath = Join-Path -Path $oldBin -ChildPath "codex"
        $codexLinkPath = Join-Path -Path $localBin -ChildPath "codex"

        if ($null -eq $nodeCommand) {
            Set-ItResult -Skipped -Because "node is unavailable on this runner."
            return
        }

        try {
            foreach ($directory in @($localBin, $fakeBin, $oldBin)) {
                [System.IO.Directory]::CreateDirectory($directory) | Out-Null
            }

            [System.IO.File]::WriteAllText($oldCodexPath, "#!/usr/bin/env bash`necho old-codex`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText(
                $fakeNpmPath,
                @'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "install --global @openai/codex@latest")
    exit 0
    ;;
  "prefix --global"|"config get prefix")
    printf '%s\n' "${TEST_NPM_PREFIX}"
    exit 0
    ;;
esac
exit 1
'@,
                [System.Text.UTF8Encoding]::new($false)
            )
            & chmod +x $oldCodexPath
            & chmod +x $fakeNpmPath
            & ln -s $nodeCommand.Source (Join-Path -Path $fakeBin -ChildPath "node")
            & ln -s $oldCodexPath $codexLinkPath
            & ln -s $localBin $localBinAlias

            $runnerContent = @(
                '#!/usr/bin/env bash'
                'set -euo pipefail'
                '_log() { echo "[test] $*"; }'
                '_warn() { echo "[test] WARNING: $*" >&2; }'
                '_ensure_npm_on_path() { return 0; }'
                '_run_with_timeout() { shift; "$@"; }'
                $script:testCodexPathIsLocalBinEntryBody
                $script:resolveCodexNpmPackageBinBody
                $script:testCodexLocalBinIsNpmManagedBody
                $script:resolveCodexNpmGlobalBinBody
                $script:resolveCodexPathWithoutLocalBinBody
                $script:linkCodexBody
                $script:installCodexCliBody
                'if _install_codex_cli; then'
                '  install_status=0'
                'else'
                '  install_status=$?'
                'fi'
                'echo "install_status=${install_status}"'
                'exit 0'
            ) -join "`n"
            [System.IO.File]::WriteAllText($runnerPath, $runnerContent, [System.Text.UTF8Encoding]::new($false))
            & chmod +x $runnerPath

            $originalHome = $env:HOME
            $originalPath = $env:PATH
            $originalPrefix = $env:TEST_NPM_PREFIX
            try {
                $env:HOME = $homeRoot
                $env:PATH = "${fakeBin}:${localBinAlias}:/usr/bin:/bin"
                $env:TEST_NPM_PREFIX = $localPrefix
                $output = @(& $bash.Source $runnerPath 2>&1)
            }
            finally {
                $env:HOME = $originalHome
                $env:PATH = $originalPath
                if ($null -eq $originalPrefix) {
                    Remove-Item Env:TEST_NPM_PREFIX -ErrorAction SilentlyContinue
                }
                else {
                    $env:TEST_NPM_PREFIX = $originalPrefix
                }
            }

            $outputText = $output -join "`n"
            $outputText | Should -Match 'install_status=1'
            $outputText | Should -Match 'E_DEVCONTAINER_CODEX_BINARY_UNRESOLVED'
            (& readlink $codexLinkPath) | Should -Be $oldCodexPath
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It "reports success for a local npm prefix only when ~/.local/bin/codex resolves to the installed package bin" {
        $bash = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bash) {
            Set-ItResult -Skipped -Because "bash is unavailable on this runner."
            return
        }
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "Bash-level devcontainer bootstrap regression uses POSIX paths."
            return
        }
        $nodeCommand = Get-Command -Name node -ErrorAction SilentlyContinue
        if ($null -eq $nodeCommand) {
            Set-ItResult -Skipped -Because "node is unavailable on this runner."
            return
        }

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("codex-local-prefix-valid-{0}" -f [guid]::NewGuid().ToString("N"))
        $homeRoot = Join-Path -Path $tempRoot -ChildPath "home"
        $localPrefix = Join-Path -Path $homeRoot -ChildPath ".local"
        $localBin = Join-Path -Path $localPrefix -ChildPath "bin"
        $fakeBin = Join-Path -Path $tempRoot -ChildPath "fake-bin"
        $npmRoot = Join-Path -Path $localPrefix -ChildPath "lib/node_modules"
        $packageDir = Join-Path -Path $npmRoot -ChildPath "@openai/codex"
        $packageBinDir = Join-Path -Path $packageDir -ChildPath "bin"
        $packageBinPath = Join-Path -Path $packageBinDir -ChildPath "codex.js"
        $packageManifestPath = Join-Path -Path $packageDir -ChildPath "package.json"
        $runnerPath = Join-Path -Path $tempRoot -ChildPath "run-codex-install.sh"
        $fakeNpmPath = Join-Path -Path $fakeBin -ChildPath "npm"
        $codexLinkPath = Join-Path -Path $localBin -ChildPath "codex"

        try {
            foreach ($directory in @($localBin, $fakeBin, $packageBinDir)) {
                [System.IO.Directory]::CreateDirectory($directory) | Out-Null
            }

            [System.IO.File]::WriteAllText($packageBinPath, "#!/usr/bin/env bash`necho package-codex`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($packageManifestPath, '{"bin":{"codex":"bin/codex.js"}}', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText(
                $fakeNpmPath,
                @'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "install --global @openai/codex@latest")
    exit 0
    ;;
  "prefix --global"|"config get prefix")
    printf '%s\n' "${TEST_NPM_PREFIX}"
    exit 0
    ;;
  "root --global")
    printf '%s\n' "${TEST_NPM_ROOT}"
    exit 0
    ;;
esac
exit 1
'@,
                [System.Text.UTF8Encoding]::new($false)
            )
            & chmod +x $packageBinPath
            & chmod +x $fakeNpmPath
            & ln -s $nodeCommand.Source (Join-Path -Path $fakeBin -ChildPath "node")
            & ln -s $packageBinPath $codexLinkPath

            $runnerContent = @(
                '#!/usr/bin/env bash'
                'set -euo pipefail'
                '_log() { echo "[test] $*"; }'
                '_warn() { echo "[test] WARNING: $*" >&2; }'
                '_ensure_npm_on_path() { return 0; }'
                '_run_with_timeout() { shift; "$@"; }'
                $script:testCodexPathIsLocalBinEntryBody
                $script:resolveCodexNpmPackageBinBody
                $script:testCodexLocalBinIsNpmManagedBody
                $script:resolveCodexNpmGlobalBinBody
                $script:resolveCodexPathWithoutLocalBinBody
                $script:linkCodexBody
                $script:installCodexCliBody
                'if _install_codex_cli; then'
                '  install_status=0'
                'else'
                '  install_status=$?'
                'fi'
                'echo "install_status=${install_status}"'
                'exit 0'
            ) -join "`n"
            [System.IO.File]::WriteAllText($runnerPath, $runnerContent, [System.Text.UTF8Encoding]::new($false))
            & chmod +x $runnerPath

            $originalHome = $env:HOME
            $originalPath = $env:PATH
            $originalPrefix = $env:TEST_NPM_PREFIX
            $originalRoot = $env:TEST_NPM_ROOT
            try {
                $env:HOME = $homeRoot
                $env:PATH = "${fakeBin}:${localBin}:/usr/bin:/bin"
                $env:TEST_NPM_PREFIX = $localPrefix
                $env:TEST_NPM_ROOT = $npmRoot
                $output = @(& $bash.Source $runnerPath 2>&1)
            }
            finally {
                $env:HOME = $originalHome
                $env:PATH = $originalPath
                if ($null -eq $originalPrefix) {
                    Remove-Item Env:TEST_NPM_PREFIX -ErrorAction SilentlyContinue
                }
                else {
                    $env:TEST_NPM_PREFIX = $originalPrefix
                }
                if ($null -eq $originalRoot) {
                    Remove-Item Env:TEST_NPM_ROOT -ErrorAction SilentlyContinue
                }
                else {
                    $env:TEST_NPM_ROOT = $originalRoot
                }
            }

            $outputText = $output -join "`n"
            $outputText | Should -Match 'install_status=0'
            $outputText | Should -Match 'Codex CLI available at '
            (& readlink $codexLinkPath) | Should -Be $packageBinPath
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It "invokes Codex install/update as non-blocking in the main flow" {
        $script:postCreateContent | Should -Match '_install_codex_cli\s*\|\|\s*_warn\s+"Codex CLI install/update failed \(non-blocking\)\."'
    }
}

Describe "devcontainer-validate.yml Codex verification contract" {
    BeforeAll {
        $script:runPostCreateStep = & $script:getWorkflowStepBlock -Content $script:devcontainerWorkflowContent -StepName "Run post-create.sh"
        $script:ensureShellQualityStep = & $script:getWorkflowStepBlock -Content $script:devcontainerWorkflowContent -StepName "Ensure repo-managed shell quality tools"
        $script:lintShellQualityStep = & $script:getWorkflowStepBlock -Content $script:devcontainerWorkflowContent -StepName "Lint post-create.sh and githook scripts"
        $script:verifyFirstCodexStep = & $script:getWorkflowStepBlock -Content $script:devcontainerWorkflowContent -StepName "Verify Codex CLI is discoverable now and in fresh shells"
        $script:confirmIdempotenceStep = & $script:getWorkflowStepBlock -Content $script:devcontainerWorkflowContent -StepName "Confirm idempotence (run post-create.sh a second time)"
        $script:verifySecondCodexStep = & $script:getWorkflowStepBlock -Content $script:devcontainerWorkflowContent -StepName "Verify Codex CLI after second post-create run"
    }

    It "uses repo-managed pinned shell quality tooling for shell linting" {
        $script:ensureShellQualityStep | Should -Match 'shell:\s+pwsh'
        $script:ensureShellQualityStep | Should -Match 'Invoke-ShellQualityChecks\.ps1\s+-Tool\s+All\s+-EnsureOnly'
        $script:lintShellQualityStep | Should -Match 'shell:\s+pwsh'
        $script:lintShellQualityStep | Should -Match 'Invoke-ShellQualityChecks\.ps1\s+-Tool\s+All\s+\.devcontainer/post-create\.sh\s+\.githooks/pre-commit\s+\.githooks/pre-push'
        $script:devcontainerWorkflowContent | Should -Not -Match 'apt-get\s+install[\s\S]*shellcheck'
        $script:devcontainerWorkflowContent | Should -Not -Match 'shellcheck\s+--severity'
    }

    It "captures first-run post-create output for Codex-aware assertions" {
        $script:runPostCreateStep | Should -Match 'post-create-first\.log'
        $script:runPostCreateStep | Should -Match 'tee'
    }

    It "keeps first-run Codex checks strict even when post-create reports non-blocking failure" {
        $script:verifyFirstCodexStep | Should -Match 'Codex CLI available at '
        $script:verifyFirstCodexStep | Should -Match 'Codex CLI install/update failed \(non-blocking\)\.'
        $script:verifyFirstCodexStep | Should -Match 'reported Codex availability but codex is missing on PATH'
        $script:verifyFirstCodexStep | Should -Match 'post-create\.sh reported a non-blocking install failure, but CI requires codex availability'
        $script:verifyFirstCodexStep | Should -Match 'self-referential'
        $script:verifyFirstCodexStep | Should -Match '\[\[\s+-L\s+"\$\{codex_path\}"\s+\]\]'
        $script:verifyFirstCodexStep | Should -Match 'exists but is not executable'
        $script:verifyFirstCodexStep | Should -Not -Match '::warning::Codex CLI unavailable after first run due explicit non-blocking install failure'
    }

    It "captures second-run output and validates Codex after the second post-create run" {
        $script:confirmIdempotenceStep | Should -Match 'post-create-second\.log'
        $script:verifySecondCodexStep | Should -Match 'post-create\.sh reported a non-blocking install failure, but CI requires codex availability'
        $script:verifySecondCodexStep | Should -Match 'self-referential after second run'
        $script:verifySecondCodexStep | Should -Match '\[\[\s+-L\s+"\$\{codex_path\}"\s+\]\]'
        $script:verifySecondCodexStep | Should -Match 'exists but is not executable after second run'
        $script:verifySecondCodexStep | Should -Not -Match '::warning::Codex CLI unavailable after second run due explicit non-blocking install failure'
        $script:verifySecondCodexStep | Should -Match 'fresh shell after second run'
    }

    It "runs Codex second-run validation after the idempotence rerun step" {
        $lines = $script:devcontainerWorkflowContent -split "`n"
        $idempotenceStepLine = -1
        $secondCodexStepLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*-\s+name:\s+Confirm idempotence \(run post-create\.sh a second time\)\s*$' -and $idempotenceStepLine -eq -1) {
                $idempotenceStepLine = $i
            }
            if ($lines[$i] -match '^\s*-\s+name:\s+Verify Codex CLI after second post-create run\s*$' -and $secondCodexStepLine -eq -1) {
                $secondCodexStepLine = $i
            }
        }

        $idempotenceStepLine | Should -Not -Be -1 -Because "Workflow must rerun post-create.sh for idempotence checks"
        $secondCodexStepLine | Should -Not -Be -1 -Because "Workflow must validate Codex after the second run"
        $idempotenceStepLine | Should -BeLessThan $secondCodexStepLine `
            -Because "Codex idempotence validation must run after the second post-create execution"
    }
}

Describe "post-create.sh PowerShell module bootstrap" {
    It "routes module installation through the shared bootstrap script" {
        $script:postCreateContent | Should -Match 'Install-PowerShellQualityModules\.ps1'
    }

    It "requests both Pester and PSScriptAnalyzer via the shared bootstrap script" {
        $script:postCreateContent | Should -Match 'Install-PowerShellQualityModules\.ps1\s+-Modules\s+Pester,PSScriptAnalyzer'
    }

    It "does not inline gallery module installation in the bootstrap script" {
        $normalized = ($script:postCreateContent) -replace "`r", ''
        $normalized | Should -Not -Match '(?m)^\s*Install-Module\s+Pester'
        $normalized | Should -Not -Match '(?m)^\s*Install-Module\s+PSScriptAnalyzer'
    }

    It "delegates module install error handling to the shared bootstrap script (no inline Set-PSRepository)" {
        $normalized = ($script:postCreateContent) -replace "`r", ''
        $normalized | Should -Not -Match '(?m)^\s*Set-PSRepository\b'
    }

    It "guards pwsh invocation against unexpected crashes (non-blocking)" {
        # pwsh call must be followed by || to prevent unexpected crashes from aborting the script.
        $normalized = ($script:postCreateContent) -replace "`r", ''
        $normalized | Should -Match "(?m)^\s*pwsh\b[^`n]+Install-PowerShellQualityModules\.ps1[^`n]+\|\|"
    }
}

Describe "post-create.sh idempotence and resilience" {
    It "checks if pre-commit is already installed before attempting install" {
        $script:postCreateContent | Should -Match 'command\s+-v\s+pre-commit'
    }

    It "uses || true to prevent non-critical failures from aborting the script" {
        $script:postCreateContent | Should -Match '\|\|\s*true'
    }

    It "guards each installation strategy with an availability check (pipx)" {
        $script:postCreateContent | Should -Match 'command\s+-v\s+pipx'
    }

    It "guards each installation strategy with an availability check (python3)" {
        $script:postCreateContent | Should -Match 'command\s+-v\s+python3'
    }

    It "guards apt-get pipx strategy with command -v apt-get check" {
        # Critical for non-Debian portability: the apt-get strategy must be gated.
        $script:postCreateContent | Should -Match 'command\s+-v\s+apt-get'
    }

    It "guards venv apt fallback with a sudo availability check" {
        $lines = $script:postCreateContent -split "`n"
        $venvStart = -1
        $venvEnd = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '_install_via_venv\(\)\s*\{' -and $venvStart -eq -1) {
                $venvStart = $i
            }
            if ($venvStart -ne -1 -and $i -gt $venvStart -and $lines[$i] -match '^\}') {
                $venvEnd = $i
                break
            }
        }

        $venvStart | Should -Not -Be -1 -Because "_install_via_venv function must exist"
        $venvEnd | Should -Not -Be -1 -Because "_install_via_venv must have a closing brace"

        $venvBody = $lines[$venvStart..$venvEnd] -join "`n"
        $venvBody | Should -Match '_can_use_sudo_non_interactive' `
            -Because "venv apt fallback must verify sudo availability before sudo apt-get"
        $venvBody | Should -Match '_ensure_apt_index_updated' `
            -Because "venv apt fallback must refresh apt package index before apt-get install"
        $venvBody | Should -Match 'sudo\s+apt-get\s+install.*python3-venv'
    }

    It "calls apt-get update before apt-get install pipx in Strategy 2" {
        # Stale package indexes cause apt-get install to fail silently on fresh environments.
        $lines = $script:postCreateContent -split "`n"
        $aptGetUpdateLine = -1
        $aptGetInstallPipxLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'apt-get\s+update' -and $aptGetUpdateLine -eq -1) {
                $aptGetUpdateLine = $i
            }
            if ($lines[$i] -match 'apt-get\s+install.*pipx' -and $aptGetInstallPipxLine -eq -1) {
                $aptGetInstallPipxLine = $i
            }
        }
        $aptGetUpdateLine | Should -Not -Be -1 -Because "apt-get update must precede apt-get install pipx"
        $aptGetInstallPipxLine | Should -Not -Be -1 -Because "apt-get install pipx must exist"
        $aptGetUpdateLine | Should -BeLessThan $aptGetInstallPipxLine `
            -Because "apt-get update must appear before apt-get install pipx"
    }
}

Describe "post-create.sh strategy ordering (structural behavior)" {
    It "defines the pipx-check strategy before the apt-get strategy" {
        # Guards against reordering that would skip the lightweight strategy.
        $lines = $script:postCreateContent -split "`n"
        $pipxStrategyLine = -1
        $aptStrategyLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '_install_via_existing_pipx\(\)' -and $pipxStrategyLine -eq -1) {
                $pipxStrategyLine = $i
            }
            if ($lines[$i] -match '_install_via_apt_pipx\(\)' -and $aptStrategyLine -eq -1) {
                $aptStrategyLine = $i
            }
        }
        $pipxStrategyLine | Should -Not -Be -1 -Because "_install_via_existing_pipx function must exist"
        $aptStrategyLine | Should -Not -Be -1 -Because "_install_via_apt_pipx function must exist"
        $pipxStrategyLine | Should -BeLessThan $aptStrategyLine `
            -Because "Strategy 1 (existing pipx) must be defined before Strategy 2 (apt-get pipx)"
    }

    It "defines the apt-get strategy before the venv strategy" {
        $lines = $script:postCreateContent -split "`n"
        $aptStrategyLine = -1
        $venvStrategyLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '_install_via_apt_pipx\(\)' -and $aptStrategyLine -eq -1) {
                $aptStrategyLine = $i
            }
            if ($lines[$i] -match '_install_via_venv\(\)' -and $venvStrategyLine -eq -1) {
                $venvStrategyLine = $i
            }
        }
        $aptStrategyLine | Should -Not -Be -1 -Because "_install_via_apt_pipx function must exist"
        $venvStrategyLine | Should -Not -Be -1 -Because "_install_via_venv function must exist"
        $aptStrategyLine | Should -BeLessThan $venvStrategyLine `
            -Because "Strategy 2 (apt-get pipx) must be defined before Strategy 3 (venv)"
    }

    It "defines the venv strategy before the nuclear fallback strategy" {
        $lines = $script:postCreateContent -split "`n"
        $venvStrategyLine = -1
        $nuclearStrategyLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '_install_via_venv\(\)' -and $venvStrategyLine -eq -1) {
                $venvStrategyLine = $i
            }
            if ($lines[$i] -match '_install_via_break_system_packages\(\)' -and $nuclearStrategyLine -eq -1) {
                $nuclearStrategyLine = $i
            }
        }
        $venvStrategyLine | Should -Not -Be -1 -Because "_install_via_venv function must exist"
        $nuclearStrategyLine | Should -Not -Be -1 -Because "_install_via_break_system_packages function must exist"
        $venvStrategyLine | Should -BeLessThan $nuclearStrategyLine `
            -Because "Strategy 3 (venv) must be defined before Strategy 4 (nuclear fallback)"
    }

    It "invokes strategies in the correct order inside _install_precommit" {
        # Verify the dispatcher calls strategies 1 → 2 → 3 → 4 in order.
        $lines = $script:postCreateContent -split "`n"
        $dispatcherStart = -1
        $dispatcherEnd = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '_install_precommit\(\)\s*\{' -and $dispatcherStart -eq -1) {
                $dispatcherStart = $i
            }
            if ($dispatcherStart -ne -1 -and $i -gt $dispatcherStart -and $lines[$i] -match '^\}') {
                $dispatcherEnd = $i
                break
            }
        }
        $dispatcherStart | Should -Not -Be -1 -Because "_install_precommit dispatcher function must exist"
        $dispatcherEnd | Should -Not -Be -1 -Because "_install_precommit must have a closing brace"

        $dispatcherBody = $lines[$dispatcherStart..$dispatcherEnd] -join "`n"

        # Find positions of each strategy call within the dispatcher body
        $s1 = ($dispatcherBody | Select-String '_install_via_existing_pipx').Matches[0].Index
        $s2 = ($dispatcherBody | Select-String '_install_via_apt_pipx[^(]').Matches[0].Index
        $s3 = ($dispatcherBody | Select-String '_install_via_venv[^(]').Matches[0].Index
        $s4 = ($dispatcherBody | Select-String '_install_via_break_system_packages[^(]').Matches[0].Index

        $s1 | Should -BeLessThan $s2 -Because "Strategy 1 must be called before Strategy 2 in dispatcher"
        $s2 | Should -BeLessThan $s3 -Because "Strategy 2 must be called before Strategy 3 in dispatcher"
        $s3 | Should -BeLessThan $s4 -Because "Strategy 3 must be called before Strategy 4 in dispatcher"
    }
}

Describe ".githooks install-guidance anti-regression (PEP 668)" {
    It "pre-commit hook does not recommend the broken 'pip install --user pre-commit' command" {
        # Regression guard: on Ubuntu 24.04, pip install --user fails with PEP 668.
        # Both hook files must recommend pipx or venv instead.
        $script:preCommitHookContent | Should -Not -Match 'pip\s+install\s+--user\s+pre-commit'
    }

    It "pre-push hook does not recommend the broken 'pip install --user pre-commit' command" {
        $script:prePushHookContent | Should -Not -Match 'pip\s+install\s+--user\s+pre-commit'
    }

    It "pre-commit hook recommends pipx as the install method" {
        $script:preCommitHookContent | Should -Match 'pipx\s+install\s+pre-commit'
    }

    It "pre-push hook recommends pipx as the install method" {
        $script:prePushHookContent | Should -Match 'pipx\s+install\s+pre-commit'
    }
}
