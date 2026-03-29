Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:postCreatePath = Join-Path -Path $script:repoRoot -ChildPath ".devcontainer/post-create.sh"
    $script:postCreateContent = Get-Content -Path $script:postCreatePath -Raw

    $script:preCommitHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-commit"
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:preCommitHookContent = Get-Content -Path $script:preCommitHookPath -Raw
    $script:prePushHookContent = Get-Content -Path $script:prePushHookPath -Raw
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

    It "configures core.hooksPath to .githooks" {
        $script:postCreateContent | Should -Match 'core\.hooksPath'
        $script:postCreateContent | Should -Match '\.githooks'
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

Describe "post-create.sh PowerShell module bootstrap" {
    It "installs Pester" {
        $script:postCreateContent | Should -Match 'Install-Module\s+Pester'
    }

    It "installs PSScriptAnalyzer" {
        $script:postCreateContent | Should -Match 'Install-Module\s+PSScriptAnalyzer'
    }

    It "installs modules with Scope CurrentUser" {
        $script:postCreateContent | Should -Match 'Scope\s+CurrentUser'
    }

    It "wraps module installation in a try/catch so failures are non-fatal" {
        $script:postCreateContent | Should -Match '\}\s*catch\s*\{'
    }

    It "guards pwsh invocation against unexpected crashes (non-blocking)" {
        # pwsh call must be followed by || to prevent unexpected crashes from aborting the script.
        $script:postCreateContent | Should -Match "pwsh[^`n]+'[^']*'\s*\|\|"
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
