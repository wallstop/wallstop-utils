Set-StrictMode -Version Latest

BeforeDiscovery {
    $bashToolingAvailableForDiscovery = $true
    foreach ($tool in @('bash', 'jq')) {
        if (-not (Get-Command -Name $tool -ErrorAction SilentlyContinue)) {
            $bashToolingAvailableForDiscovery = $false
            Write-Verbose "AgentNotify Pester gate: '$tool' unavailable on this host; skipping runtime lane."
        }
    }
}

BeforeAll {
    function Read-AgentNotifySuiteCaptureTaskBounded {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Task,

            [Parameter(Mandatory = $true)]
            [ValidateSet('stdout', 'stderr')]
            [string]$StreamName,

            [Parameter(Mandatory = $true)]
            [ValidateRange(1, [int]::MaxValue)]
            [int]$TimeoutMilliseconds
        )

        try {
            if (-not $Task.Wait($TimeoutMilliseconds)) {
                return [pscustomobject]@{
                    Text       = ''
                    Diagnostic = "E_AGENT_NOTIFY_SUITE_CAPTURE_TIMEOUT: stream=$StreamName timeoutMilliseconds=$TimeoutMilliseconds"
                }
            }
        }
        catch {
            return [pscustomobject]@{
                Text       = ''
                Diagnostic = "E_AGENT_NOTIFY_SUITE_CAPTURE_FAILED: stream=$StreamName error=$($_.Exception.Message)"
            }
        }

        try {
            return [pscustomobject]@{
                # GetResult cannot block after the bounded Wait above reports completion.
                Text       = $Task.GetAwaiter().GetResult()
                Diagnostic = ''
            }
        }
        catch {
            return [pscustomobject]@{
                Text       = ''
                Diagnostic = "E_AGENT_NOTIFY_SUITE_CAPTURE_FAILED: stream=$StreamName error=$($_.Exception.Message)"
            }
        }
    }

    $testsRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $testsRoot -ChildPath '..')).Path
    . (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/CompatibilityHelpers.ps1')

    $script:agentNotifyDir = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/AgentNotify'
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

Describe 'AgentNotify bash offline suite' -Skip:(-not $bashToolingAvailableForDiscovery) {
    It 'passes the full data-driven assertion run' {
        $suitePath = Join-Path -Path $script:agentNotifyDir -ChildPath 'tests/run.sh'

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command -Name 'bash' -ErrorAction Stop).Source
        Set-PortableProcessArguments -StartInfo $psi -ArgumentList @($suitePath)
        $psi.WorkingDirectory = $script:repoRoot
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        try {
            if (-not $process.Start()) {
                throw 'E_AGENT_NOTIFY_SUITE_START_FAILED: unable to start tests/run.sh.'
            }

            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            $timeoutMs = 600000
            $captureTimeoutMs = 5000
            $exitedCleanly = $process.WaitForExit($timeoutMs)
            $cleanupDiagnostics = New-Object System.Collections.Generic.List[string]
            if (-not $exitedCleanly) {
                try {
                    Stop-ProcessTreePortably -Process $process
                }
                catch {
                    $cleanupDiagnostics.Add(
                        "E_AGENT_NOTIFY_SUITE_CAPTURE_FAILED: process tree cleanup failed: $($_.Exception.Message)"
                    ) | Out-Null
                }

                try {
                    if (-not $process.WaitForExit($captureTimeoutMs)) {
                        $cleanupDiagnostics.Add(
                            "E_AGENT_NOTIFY_SUITE_CAPTURE_TIMEOUT: process did not exit within ${captureTimeoutMs}ms after timeout cleanup."
                        ) | Out-Null
                    }
                }
                catch {
                    $cleanupDiagnostics.Add(
                        "E_AGENT_NOTIFY_SUITE_CAPTURE_FAILED: process exit observation failed: $($_.Exception.Message)"
                    ) | Out-Null
                }
            }

            # Observe both tasks even if one times out or faults so neither exception is left unobserved.
            $stdoutCapture = Read-AgentNotifySuiteCaptureTaskBounded `
                -Task $stdoutTask `
                -StreamName 'stdout' `
                -TimeoutMilliseconds $captureTimeoutMs
            $stderrCapture = Read-AgentNotifySuiteCaptureTaskBounded `
                -Task $stderrTask `
                -StreamName 'stderr' `
                -TimeoutMilliseconds $captureTimeoutMs

            $captureDiagnostics = @(
                @($cleanupDiagnostics)
                $stdoutCapture.Diagnostic
                $stderrCapture.Diagnostic
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

            if (-not $exitedCleanly) {
                $detail = if (@($captureDiagnostics).Count -gt 0) {
                    ' ' + ($captureDiagnostics -join ' ')
                }
                else {
                    ''
                }
                throw "E_AGENT_NOTIFY_SUITE_TIMEOUT: tests/run.sh exceeded ${timeoutMs}ms.$detail"
            }

            if (@($captureDiagnostics).Count -gt 0) {
                throw ($captureDiagnostics -join ' ')
            }

            $stdoutCapture.Text | Should -Match 'FAIL:\s*0\b'
            $process.ExitCode | Should -Be 0
        }
        finally {
            $process.Dispose()
        }
    }
}
