Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:hookTimeoutHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/HookTimeout.sh"
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1")
}

Describe "HookTimeout shell watchdog behavior" {
    It "terminates descendants when the fallback watchdog times out" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "POSIX process-group watchdog behavior is validated on Linux/macOS hosts."
            return
        }

        $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable on this runner."
            return
        }

        $sessionToolAvailable = $false
        foreach ($commandName in @("setsid", "python3", "perl")) {
            if ($null -ne (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                $sessionToolAvailable = $true
                break
            }
        }

        if (-not $sessionToolAvailable) {
            Set-ItResult -Skipped -Because "setsid/python3/perl are unavailable; process-group fallback cannot be exercised."
            return
        }

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-hook-timeout-test-{0}" -f [guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $driverPath = Join-Path -Path $tempRoot -ChildPath "driver.sh"
        $childPidPath = Join-Path -Path $tempRoot -ChildPath "child.pid"
        $timeoutFlagPath = Join-Path -Path $tempRoot -ChildPath "timeout.flag"

        $driverContent = @'
#!/usr/bin/env bash
set -euo pipefail

helper_path="$1"
child_pid_file="$2"
timeout_flag_file="$3"

# shellcheck source=Scripts/Utils/Common/HookTimeout.sh
. "$helper_path"

rm -f "$child_pid_file" "$timeout_flag_file"

set +e
WALLSTOP_TIMEOUT_COMMAND_PID=""
WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE=""
wallstop_start_timeout_command "descendant cleanup behavioral test" bash -c 'sleep 30 & echo "$!" > "$1"; wait' -- "$child_pid_file"
command_pid="$WALLSTOP_TIMEOUT_COMMAND_PID"
command_process_group_mode="$WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE"

(
  sleep 1
  if wallstop_is_timeout_command_alive "$command_pid" "$command_process_group_mode"; then
    : > "$timeout_flag_file"
    wallstop_terminate_timeout_command "$command_pid" "$command_process_group_mode"
  fi
) &
watchdog_pid=$!

wait "$command_pid"
command_exit=$?
kill "$watchdog_pid" > /dev/null 2>&1 || true
wait "$watchdog_pid" > /dev/null 2>&1 || true
wallstop_cleanup_timeout_command_processes "$command_pid" "$command_process_group_mode" "descendant cleanup behavioral test"
set -e

if [[ ! -f "$timeout_flag_file" ]]; then
  echo "timeout flag was not created" >&2
  exit 6
fi

if [[ ! -s "$child_pid_file" ]]; then
  echo "child pid was not captured" >&2
  exit 7
fi

child_pid="$(cat "$child_pid_file")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$child_pid" > /dev/null 2>&1; then
    exit 0
  fi
  sleep 0.2
done

echo "descendant process still alive pid=${child_pid} commandExit=${command_exit}" >&2
kill -KILL "$child_pid" > /dev/null 2>&1 || true
exit 8
'@

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($driverPath, $driverContent, $utf8NoBom)

        $process = $null
        try {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $bashCommand.Source
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @(
                $driverPath,
                $script:hookTimeoutHelperPath,
                $childPidPath,
                $timeoutFlagPath
            )

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            $process.Start() | Should -BeTrue

            if (-not $process.WaitForExit(20000)) {
                Stop-ProcessTreePortably -Process $process
                throw "Hook timeout behavioral test driver exceeded 20s."
            }

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $stdout,$stderr)
        }
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }

            if (Test-Path -LiteralPath $childPidPath -PathType Leaf) {
                $childPid = [System.IO.File]::ReadAllText($childPidPath, [System.Text.Encoding]::UTF8).Trim()
                if ($childPid -match '^\d+$') {
                    $killCommand = Get-Command -Name kill -ErrorAction SilentlyContinue
                    if ($null -ne $killCommand) {
                        & $killCommand.Source -KILL $childPid 2> $null
                    }
                }
            }

            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "cleans up descendants left behind after the command exits" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "POSIX process-group watchdog behavior is validated on Linux/macOS hosts."
            return
        }

        $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable on this runner."
            return
        }

        $sessionToolAvailable = $false
        foreach ($commandName in @("setsid", "python3", "perl")) {
            if ($null -ne (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                $sessionToolAvailable = $true
                break
            }
        }

        if (-not $sessionToolAvailable) {
            Set-ItResult -Skipped -Because "setsid/python3/perl are unavailable; process-group fallback cannot be exercised."
            return
        }

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-hook-cleanup-test-{0}" -f [guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $driverPath = Join-Path -Path $tempRoot -ChildPath "driver.sh"
        $childPidPath = Join-Path -Path $tempRoot -ChildPath "child.pid"

        $driverContent = @'
#!/usr/bin/env bash
set -euo pipefail

helper_path="$1"
child_pid_file="$2"

# shellcheck source=Scripts/Utils/Common/HookTimeout.sh
. "$helper_path"

rm -f "$child_pid_file"

set +e
WALLSTOP_TIMEOUT_COMMAND_PID=""
WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE=""
wallstop_start_timeout_command "descendant cleanup after normal exit behavioral test" bash -c 'sleep 30 & echo "$!" > "$1"; exit 0' -- "$child_pid_file"
command_pid="$WALLSTOP_TIMEOUT_COMMAND_PID"
command_process_group_mode="$WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE"
wait "$command_pid"
command_exit=$?
wallstop_cleanup_timeout_command_processes "$command_pid" "$command_process_group_mode" "descendant cleanup after normal exit behavioral test"
set -e

if [[ "$command_exit" -ne 0 ]]; then
  echo "command exited unexpectedly: ${command_exit}" >&2
  exit 6
fi

if [[ ! -s "$child_pid_file" ]]; then
  echo "child pid was not captured" >&2
  exit 7
fi

child_pid="$(cat "$child_pid_file")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$child_pid" > /dev/null 2>&1; then
    exit 0
  fi
  sleep 0.2
done

echo "descendant process still alive pid=${child_pid}" >&2
kill -KILL "$child_pid" > /dev/null 2>&1 || true
exit 8
'@

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($driverPath, $driverContent, $utf8NoBom)

        $process = $null
        try {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $bashCommand.Source
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @(
                $driverPath,
                $script:hookTimeoutHelperPath,
                $childPidPath
            )

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            $process.Start() | Should -BeTrue

            if (-not $process.WaitForExit(20000)) {
                Stop-ProcessTreePortably -Process $process
                throw "Hook timeout cleanup behavioral test driver exceeded 20s."
            }

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $stdout,$stderr)
        }
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }

            if (Test-Path -LiteralPath $childPidPath -PathType Leaf) {
                $childPid = [System.IO.File]::ReadAllText($childPidPath, [System.Text.Encoding]::UTF8).Trim()
                if ($childPid -match '^\d+$') {
                    $killCommand = Get-Command -Name kill -ErrorAction SilentlyContinue
                    if ($null -ne $killCommand) {
                        & $killCommand.Source -KILL $childPid 2> $null
                    }
                }
            }

            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects a shadowed setsid that does not create an isolated process group" {
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because "POSIX process-group watchdog behavior is validated on Linux/macOS hosts."
            return
        }

        $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable on this runner."
            return
        }

        if ($null -eq (Get-Command -Name python3 -ErrorAction SilentlyContinue) -and $null -eq (Get-Command -Name perl -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "python3/perl fallback is unavailable on this runner."
            return
        }

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-hook-shadowed-setsid-test-{0}" -f [guid]::NewGuid().ToString("N"))
        $fakeBin = Join-Path -Path $tempRoot -ChildPath "bin"
        [void][System.IO.Directory]::CreateDirectory($fakeBin)
        $fakeSetsidPath = Join-Path -Path $fakeBin -ChildPath "setsid"
        $driverPath = Join-Path -Path $tempRoot -ChildPath "driver.sh"

        $fakeSetsidContent = @'
#!/usr/bin/env bash
exec "$@"
'@

        $driverContent = @'
#!/usr/bin/env bash
set -euo pipefail

fake_bin="$1"
helper_path="$2"

export PATH="${fake_bin}:${PATH}"

# shellcheck source=Scripts/Utils/Common/HookTimeout.sh
. "$helper_path"

if wallstop_can_start_session_with_setsid; then
  echo "fake setsid unexpectedly passed session probe" >&2
  exit 7
fi

set +e
WALLSTOP_TIMEOUT_COMMAND_PID=""
WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE=""
wallstop_start_timeout_command "shadowed setsid behavioral test" sh -c 'sleep 0.1'
command_pid="$WALLSTOP_TIMEOUT_COMMAND_PID"
command_process_group_mode="$WALLSTOP_TIMEOUT_COMMAND_PROCESS_GROUP_MODE"
wait "$command_pid"
set -e

if [[ "$command_process_group_mode" != "isolated" ]]; then
  echo "expected python3/perl fallback to provide isolation, got mode=${command_process_group_mode}" >&2
  exit 8
fi
'@

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($fakeSetsidPath, $fakeSetsidContent, $utf8NoBom)
        [System.IO.File]::WriteAllText($driverPath, $driverContent, $utf8NoBom)
        $chmodCommand = Get-Command -Name chmod -ErrorAction SilentlyContinue
        if ($null -ne $chmodCommand) {
            & $chmodCommand.Source +x $fakeSetsidPath
        }

        $process = $null
        try {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $bashCommand.Source
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @(
                $driverPath,
                $fakeBin,
                $script:hookTimeoutHelperPath
            )

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            $process.Start() | Should -BeTrue

            if (-not $process.WaitForExit(20000)) {
                Stop-ProcessTreePortably -Process $process
                throw "Hook timeout shadowed setsid test driver exceeded 20s."
            }

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because ("stdout={0}; stderr={1}" -f $stdout,$stderr)
        }
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }

            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
