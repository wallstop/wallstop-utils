Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
    . (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/CompatibilityHelpers.ps1')

    $script:agentNotifyDir = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/AgentNotify'
    $script:bashToolingAvailable = $true
    foreach ($tool in @('bash', 'jq')) {
        if (-not (Get-Command -Name $tool -ErrorAction SilentlyContinue)) {
            $script:bashToolingAvailable = $false
            Write-Verbose "AgentNotify Pester gate: '$tool' unavailable on this host; skipping runtime lane."
        }
    }
}

Describe 'AgentNotify repository layout contract' {
    It 'ships every adapter that install.sh references' {
        $installScript = Join-Path -Path $script:agentNotifyDir -ChildPath 'install.sh'
        $content = (Get-Content -Path $installScript -Raw) -replace "`r", ''
        foreach ($relative in @(
                'adapters/claude/settings-hooks.json',
                'adapters/codex/hooks.json',
                'adapters/copilot/agent-notify.json',
                'adapters/opencode/agent-notify.js',
                'adapters/nanocoder/notify-send'
            )) {
            $path = Join-Path -Path $script:agentNotifyDir -ChildPath ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $path | Should -Exist
            $escaped = [regex]::Escape($relative)
            $content | Should -Match $escaped
        }
    }

    It 'keeps the offline suite hermetic (no network publish paths committed)' {
        $fixtures = @(Get-ChildItem -Path (Join-Path -Path $script:agentNotifyDir -ChildPath 'tests/fixtures') -Filter '*.json' -File -Recurse)
        $fixtures.Count | Should -BeGreaterThan 0
        foreach ($fixture in $fixtures) {
            $raw = (Get-Content -Path $fixture.FullName -Raw) -replace "`r", ''
            $raw | Should -Not -Match 'https://ntfy\.sh/[A-Za-z0-9_-]{16,}'
            $raw | Should -Not -Match 'tk_[A-Za-z0-9]{16,}'
        }
    }
}

Describe 'AgentNotify bash offline suite' -Skip:(-not $script:bashToolingAvailable) {
    It 'passes the full data-driven assertion run' {
        $suitePath = Join-Path -Path $script:agentNotifyDir -ChildPath 'tests/run.sh'

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command -Name 'bash' -ErrorAction Stop).Source
        Set-PortableProcessArguments -StartInfo $psi -ArgumentList @($suitePath)
        $psi.WorkingDirectory = $script:repoRoot
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $timeoutMs = 600000
        $exitedCleanly = $process.WaitForExit($timeoutMs)
        if (-not $exitedCleanly) {
            try {
                $process.Kill()
            } catch {
                Write-Verbose "AgentNotify suite kill after timeout failed: $_"
            }
        }
        $null = $stderrTask.GetAwaiter().GetResult()

        if (-not $exitedCleanly) {
            throw "E_AGENT_NOTIFY_SUITE_TIMEOUT: tests/run.sh exceeded ${timeoutMs}ms."
        }

        $stdoutTask.GetAwaiter().GetResult() | Should -Match 'FAIL:\s*0\b'
        $process.ExitCode | Should -Be 0
    }
}
