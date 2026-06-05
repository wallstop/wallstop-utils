Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:hookTimeoutHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/HookTimeout.sh"
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1")

    $script:requiresBashPathConversion = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:bashResolutionDiagnostics = ""
    $script:bashHelperRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-prepush-bash-helpers-{0}" -f [guid]::NewGuid().ToString("N"))
    $script:bashHelperScripts = @{}
    $script:bashHostPathMode = "identity"
    $script:bashCommand = Resolve-TestBashCommand
    if ($null -ne $script:bashCommand) {
        [void][System.IO.Directory]::CreateDirectory($script:bashHelperRoot)
        Initialize-BashHostPathMode
    }
}

AfterAll {
    if (-not [string]::IsNullOrWhiteSpace($script:bashHelperRoot) -and (Test-Path -LiteralPath $script:bashHelperRoot)) {
        Remove-Item -LiteralPath $script:bashHelperRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function script:Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function script:Test-IsCiRunner {
    return ($env:CI -eq "true" -or $env:GITHUB_ACTIONS -eq "true")
}

function script:Get-PreviewText {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [int]$MaximumLength = 240
    )

    if ($null -eq $Text) {
        return "<null>"
    }

    $normalized = ($Text -replace "`r", "\r") -replace "`n", "\n"
    if ($normalized.Length -le $MaximumLength) {
        return $normalized
    }

    return $normalized.Substring(0, $MaximumLength) + "...<truncated>"
}

function script:Wait-ProcessExitBounded {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMilliseconds = 2000
    )

    try {
        if ($Process.HasExited) {
            return $true
        }

        return $Process.WaitForExit($TimeoutMilliseconds)
    }
    catch {
        return $false
    }
}

function script:Read-ProcessStreamTaskBounded {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Task,

        [Parameter(Mandatory = $true)]
        [string]$StreamName,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMilliseconds = 2000
    )

    try {
        if (-not $Task.Wait($TimeoutMilliseconds)) {
            return [pscustomobject]@{
                Text       = ""
                Diagnostic = "E_TEST_CAPTURE_TIMEOUT: stream=$StreamName timeoutMilliseconds=$TimeoutMilliseconds"
                TimedOut   = $true
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Text       = ""
            Diagnostic = "E_TEST_CAPTURE_FAILED: stream=$StreamName error=$($_.Exception.Message)"
            TimedOut   = $false
        }
    }

    try {
        return [pscustomobject]@{
            Text       = $Task.GetAwaiter().GetResult()
            Diagnostic = ""
            TimedOut   = $false
        }
    }
    catch {
        return [pscustomobject]@{
            Text       = ""
            Diagnostic = "E_TEST_CAPTURE_FAILED: stream=$StreamName error=$($_.Exception.Message)"
            TimedOut   = $false
        }
    }
}

function script:Join-CapturedProcessDiagnostics {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Diagnostics = @()
    )

    return (@($Diagnostics) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
}

function script:Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory = "",

        [Parameter(Mandatory = $false)]
        [hashtable]$Environment = @{},

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMilliseconds = 10000
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    foreach ($key in @($Environment.Keys)) {
        Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name ([string]$key) -Value ([string]$Environment[$key])
    }

    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList $ArgumentList
    return Invoke-CapturedProcessStartInfo -StartInfo $startInfo -TimeoutMilliseconds $TimeoutMilliseconds
}

function script:Add-BashCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Candidates,

        [Parameter(Mandatory = $true)]
        [string]$Origin,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $Candidates.Add([pscustomobject]@{
            Origin = $Origin
            Path   = $Path.Trim()
        }) | Out-Null
}

function script:Resolve-TestBashCommand {
    $candidates = [System.Collections.Generic.List[object]]::new()
    Add-BashCandidate -Candidates $candidates -Origin "WALLSTOP_TEST_BASH" -Path $env:WALLSTOP_TEST_BASH

    if ($script:requiresBashPathConversion) {
        $gitBashRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $gitBashRoots += (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Programs")
        }
        $gitBashRoots = @($gitBashRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        foreach ($gitBashRoot in $gitBashRoots) {
            Add-BashCandidate -Candidates $candidates -Origin "Git for Windows" -Path (Join-Path -Path $gitBashRoot -ChildPath "Git/bin/bash.exe")
            Add-BashCandidate -Candidates $candidates -Origin "Git for Windows" -Path (Join-Path -Path $gitBashRoot -ChildPath "Git/usr/bin/bash.exe")
        }
    }

    $pathBashCommand = Get-Command -Name "bash" -ErrorAction SilentlyContinue
    if ($null -ne $pathBashCommand) {
        Add-BashCandidate -Candidates $candidates -Origin "PATH" -Path $pathBashCommand.Source
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $diagnostics = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $candidatePath = [string]$candidate.Path
        if (-not $seen.Add($candidatePath)) {
            continue
        }

        $resolvedPath = $candidatePath
        $exists = Test-Path -LiteralPath $candidatePath -PathType Leaf
        if ($exists) {
            $resolvedPath = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
        }
        else {
            $candidateCommand = Get-Command -Name $candidatePath -ErrorAction SilentlyContinue
            if ($null -ne $candidateCommand) {
                $resolvedPath = $candidateCommand.Source
                $exists = $true
            }
        }

        if (-not $exists) {
            $diagnostics.Add("origin=$($candidate.Origin); candidate='$candidatePath'; exists=false") | Out-Null
            continue
        }

        try {
            $versionResult = Invoke-CapturedProcess -FileName $resolvedPath -ArgumentList @("--version") -TimeoutMilliseconds 5000
            $versionPreview = Get-PreviewText -Text $versionResult.Stdout
            $stderrPreview = Get-PreviewText -Text $versionResult.Stderr
            $diagnostics.Add("origin=$($candidate.Origin); candidate='$candidatePath'; resolved='$resolvedPath'; exists=true; exitCode=$($versionResult.ExitCode); stdout=$versionPreview; stderr=$stderrPreview") | Out-Null

            if (-not $versionResult.TimedOut -and $versionResult.ExitCode -eq 0) {
                return [pscustomobject]@{
                    Source  = $resolvedPath
                    Origin  = [string]$candidate.Origin
                    Version = (($versionResult.Stdout -split "`r?`n") | Select-Object -First 1)
                }
            }
        }
        catch {
            $diagnostics.Add("origin=$($candidate.Origin); candidate='$candidatePath'; resolved='$resolvedPath'; exists=true; error=$($_.Exception.Message)") | Out-Null
        }
    }

    $script:bashResolutionDiagnostics = $diagnostics -join "; "
    if (Test-IsCiRunner) {
        throw "E_TEST_BASH_UNAVAILABLE: no usable Bash runtime found for pre-push hook tests. Candidates: $script:bashResolutionDiagnostics"
    }

    return $null
}

function script:Get-BashVisiblePathCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet("identity", "forward-drive", "git-drive", "wsl-drive")]
        [string]$Mode
    )

    if (-not $script:requiresBashPathConversion) {
        return $Path
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $forwardPath = $fullPath -replace '\\', '/'
    if ($forwardPath -notmatch '^([A-Za-z]):/(.*)$') {
        return $forwardPath
    }

    $driveLetter = $matches[1].ToLowerInvariant()
    $rest = $matches[2]

    switch ($Mode) {
        "identity" { return $Path }
        "forward-drive" { return $forwardPath }
        "git-drive" { return "/$driveLetter/$rest" }
        "wsl-drive" { return "/mnt/$driveLetter/$rest" }
    }
}

function script:Initialize-BashHostPathMode {
    if ($null -eq $script:bashCommand) {
        return
    }

    [void][System.IO.Directory]::CreateDirectory($script:bashHelperRoot)
    $probePath = Join-Path -Path $script:bashHelperRoot -ChildPath "probe.sh"
    Write-Utf8NoBomFile -Path $probePath -Content @'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "__wallstop_bash_probe_ok__"
'@

    foreach ($mode in @("identity", "forward-drive", "git-drive", "wsl-drive")) {
        $bashProbePath = Get-BashVisiblePathCandidate -Path $probePath -Mode $mode
        $probeResult = Invoke-CapturedProcess -FileName $script:bashCommand.Source -ArgumentList @($bashProbePath) -TimeoutMilliseconds 5000
        if ($probeResult.ExitCode -eq 0 -and $probeResult.Stdout -match '__wallstop_bash_probe_ok__') {
            $script:bashHostPathMode = $mode
            return
        }
    }

    throw "E_TEST_BASH_PATH_MODE_FAILED: selected Bash runtime '$($script:bashCommand.Source)' could not execute helper scripts from '$script:bashHelperRoot'."
}

function script:ConvertTo-BashHelperScriptPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Get-BashVisiblePathCandidate -Path $Path -Mode $script:bashHostPathMode
}

function script:Get-BashHelperScriptPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    if ($null -eq $script:bashHelperScripts) {
        $script:bashHelperScripts = @{}
    }

    if ($script:bashHelperScripts.ContainsKey($Name)) {
        return [string]$script:bashHelperScripts[$Name]
    }

    [void][System.IO.Directory]::CreateDirectory($script:bashHelperRoot)
    $scriptPath = Join-Path -Path $script:bashHelperRoot -ChildPath "$Name.sh"
    Write-Utf8NoBomFile -Path $scriptPath -Content $Content
    $script:bashHelperScripts[$Name] = $scriptPath
    return $scriptPath
}

function script:Invoke-BashHelperScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMilliseconds = 10000
    )

    if ($null -eq $script:bashCommand) {
        throw "E_TEST_BASH_UNAVAILABLE: bash is unavailable. $script:bashResolutionDiagnostics"
    }

    $scriptPath = Get-BashHelperScriptPath -Name $Name -Content $Content
    $bashScriptPath = ConvertTo-BashHelperScriptPath -Path $scriptPath
    return Invoke-CapturedProcess -FileName $script:bashCommand.Source -ArgumentList (@($bashScriptPath) + @($ArgumentList)) -TimeoutMilliseconds $TimeoutMilliseconds
}

function script:Invoke-BashCommandWithPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory = "",

        [Parameter(Mandatory = $false)]
        [hashtable]$Environment = @{},

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMilliseconds = 10000
    )

    if ($null -eq $script:bashCommand) {
        throw "E_TEST_BASH_UNAVAILABLE: bash is unavailable. $script:bashResolutionDiagnostics"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:bashCommand.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("-lc", $Command)
    Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "PATH" -Value $PathValue
    foreach ($key in @($Environment.Keys)) {
        Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name ([string]$key) -Value ([string]$Environment[$key])
    }

    return Invoke-CapturedProcessStartInfo -StartInfo $startInfo -TimeoutMilliseconds $TimeoutMilliseconds
}

function script:ConvertTo-BashPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $script:requiresBashPathConversion) {
        return $Path
    }

    if ($null -eq $script:bashCommand) {
        throw "E_TEST_BASH_PATH_CONVERSION_FAILED: bash is unavailable while converting '$Path'."
    }

    $conversionScript = @'
#!/usr/bin/env bash
set -euo pipefail
path_value="$1"
convert_with_tool() {
  local tool_name="$1"
  local converted_path=""

  if ! command -v "$tool_name" > /dev/null 2>&1; then
    return 1
  fi

  if converted_path="$("$tool_name" -u "$path_value" 2> /dev/null)" && [[ -n "$converted_path" ]]; then
    printf '%s\n' "$converted_path"
    exit 0
  fi

  return 1
}

convert_with_tool cygpath || true
convert_with_tool wslpath || true

if [[ "$path_value" =~ ^([A-Za-z]):(.*)$ ]]; then
  drive_letter="${BASH_REMATCH[1]}"
  drive_letter="$(printf '%s' "$drive_letter" | tr '[:upper:]' '[:lower:]')"
  rest="${BASH_REMATCH[2]}"
  while [[ "$rest" == [\\/]* ]]; do
    rest="${rest:1}"
  done
  rest="${rest//\\//}"

  printf '/%s' "$drive_letter"
  if [[ -n "$rest" ]]; then
    printf '/%s' "$rest"
  fi
  printf '\n'
  exit 0
fi

exit 127
'@

    $conversionResult = Invoke-BashHelperScript -Name "convert-path" -Content $conversionScript -ArgumentList @($Path)
    $convertedPath = @(($conversionResult.Stdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($conversionResult.ExitCode -eq 0 -and $convertedPath.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($convertedPath[0])) {
        return [string]$convertedPath[0]
    }

    $diagnostics = Get-BashPathConversionDiagnostics -Path $Path -ConversionResult $conversionResult
    throw "E_TEST_BASH_PATH_CONVERSION_FAILED: selected Bash runtime could not convert '$Path' with cygpath, wslpath, or drive-letter fallback ($diagnostics)."
}

function script:Get-BashPathConversionDiagnostics {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ConvertedPath,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [pscustomobject]$ConversionResult
    )

    if ($null -eq $script:bashCommand) {
        return "bashCommand=<missing>; resolutionDiagnostics=$script:bashResolutionDiagnostics"
    }

    $probeScript = @'
#!/usr/bin/env bash
set -euo pipefail
printf 'bashVersion=%s\n' "${BASH_VERSION:-unknown}"
if command -v uname > /dev/null 2>&1; then
  printf 'uname=%s\n' "$(uname -a 2>&1)"
else
  printf 'uname=<missing>\n'
fi
for command_name in cygpath wslpath tr; do
  if command -v "$command_name" > /dev/null 2>&1; then
    printf '%s=%s\n' "$command_name" "$(command -v "$command_name")"
  else
    printf '%s=<missing>\n' "$command_name"
  fi
done
if pwd -W > /dev/null 2>&1; then
  printf 'pwdW=%s\n' "$(pwd -W)"
else
  printf 'pwdW=<unavailable>\n'
fi
'@
    $probeResult = Invoke-BashHelperScript -Name "path-diagnostics" -Content $probeScript

    $probeOutput = @($probeResult.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $probePreview = if ($probeOutput.Count -gt 0) {
        ($probeOutput | ForEach-Object { [string]$_ }) -join "; "
    }
    else {
        "<empty>"
    }

    $conversionPreview = ""
    if ($null -ne $ConversionResult) {
        $conversionPreview = "; conversionExitCode=$($ConversionResult.ExitCode); conversionStdout=$(Get-PreviewText -Text $ConversionResult.Stdout); conversionStderr=$(Get-PreviewText -Text $ConversionResult.Stderr)"
    }

    $existencePreview = ""
    if (-not [string]::IsNullOrWhiteSpace($ConvertedPath)) {
        $exists = Test-BashPathExists -Path $ConvertedPath
        $existencePreview = "; convertedPath='$ConvertedPath'; convertedPathExists=$exists"
    }

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $conversionPreview = "; originalPath='$Path'" + $conversionPreview
    }

    return "bashCommand='$($script:bashCommand.Source)'; bashOrigin='$($script:bashCommand.Origin)'; bashHostPathMode='$script:bashHostPathMode'; probeExitCode=$($probeResult.ExitCode); $probePreview$conversionPreview$existencePreview"
}

function script:Resolve-BashCommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    $resolveScript = @'
#!/usr/bin/env bash
set -euo pipefail
command -v "$1"
'@
    $resolveResult = Invoke-BashHelperScript -Name "resolve-command" -Content $resolveScript -ArgumentList @($CommandName)
    $resolvedCommand = @(($resolveResult.Stdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($resolveResult.ExitCode -ne 0 -or $resolvedCommand.Count -eq 0 -or [string]::IsNullOrWhiteSpace($resolvedCommand[0])) {
        return $null
    }

    return [string]$resolvedCommand[0]
}

function script:Set-BashExecutableBit {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    $bashPaths = @($Path | ForEach-Object { ConvertTo-BashPath -Path $_ })
    $chmodScript = @'
#!/usr/bin/env bash
set -euo pipefail
chmod +x "$@"
'@
    $chmodResult = Invoke-BashHelperScript -Name "chmod" -Content $chmodScript -ArgumentList $bashPaths
    if ($chmodResult.ExitCode -ne 0) {
        throw "E_TEST_BASH_CHMOD_FAILED: selected Bash runtime could not mark harness script(s) executable."
    }
}

function script:Test-BashFileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $testFileScript = @'
#!/usr/bin/env bash
set -euo pipefail
test -f "$1"
'@
    $testResult = Invoke-BashHelperScript -Name "test-file" -Content $testFileScript -ArgumentList @($Path)
    return ($testResult.ExitCode -eq 0)
}

function script:Test-BashPathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $testPathScript = @'
#!/usr/bin/env bash
set -euo pipefail
test -e "$1"
'@
    $testResult = Invoke-BashHelperScript -Name "test-path" -Content $testPathScript -ArgumentList @($Path)
    return ($testResult.ExitCode -eq 0)
}

function script:Assert-PrePushHarnessCommandResolution {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Harness,

        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    $preflightScript = @'
for command_name in git pre-commit pwsh; do
  if resolved="$(command -v "$command_name" 2> /dev/null)" && [[ -n "$resolved" ]]; then
    printf '%s=%s\n' "$command_name" "$resolved"
  else
    printf '%s=<missing>\n' "$command_name"
  fi
done
printf 'PATH=%s\n' "$PATH"
printf 'PWD=%s\n' "$(pwd)"
'@

    $preflight = Invoke-BashCommandWithPath -PathValue $PathValue -Command $preflightScript -WorkingDirectory $Harness.RepoRoot
    if ($preflight.ExitCode -ne 0) {
        throw (
            "E_TEST_PREPUSH_COMMAND_PREFLIGHT_FAILED: harness command preflight failed (exitCode={0}; stdout={1}; stderr={2}; path={3}; binRoot={4})." -f @(
                $preflight.ExitCode,
                (Get-PreviewText -Text $preflight.Stdout),
                (Get-PreviewText -Text $preflight.Stderr),
                $PathValue,
                (ConvertTo-BashPath -Path $Harness.BinRoot)
            )
        )
    }

    $resolvedCommands = @{}
    foreach ($line in @($preflight.Stdout -split "`r?`n")) {
        $match = [regex]::Match([string]$line, '^(?<Name>git|pre-commit|pwsh)=(?<Path>.*)$')
        if ($match.Success) {
            $resolvedCommands[$match.Groups["Name"].Value] = $match.Groups["Path"].Value
        }
    }

    foreach ($commandName in @("git", "pwsh")) {
        $expectedPath = (ConvertTo-BashPath -Path (Join-Path -Path $Harness.BinRoot -ChildPath $commandName))
        if (-not $resolvedCommands.ContainsKey($commandName) -or $resolvedCommands[$commandName] -ne $expectedPath) {
            $actualCommandPath = if ($resolvedCommands.ContainsKey($commandName)) {
                $resolvedCommands[$commandName]
            }
            else {
                "<missing>"
            }

            throw (
                "E_TEST_PREPUSH_FAKE_COMMAND_NOT_SELECTED: expected '{0}' to resolve to harness shim '{1}', but got '{2}'. Diagnostics: stdout={3}; stderr={4}; path={5}; bash={6}; mode={7}." -f @(
                    $commandName,
                    $expectedPath,
                    $actualCommandPath,
                    (Get-PreviewText -Text $preflight.Stdout),
                    (Get-PreviewText -Text $preflight.Stderr),
                    $PathValue,
                    $script:bashCommand.Source,
                    $script:bashHostPathMode
                )
            )
        }
    }

    $preCommitShimPath = Join-Path -Path $Harness.BinRoot -ChildPath "pre-commit"
    $expectedPreCommitPath = if (Test-Path -LiteralPath $preCommitShimPath -PathType Leaf) {
        ConvertTo-BashPath -Path $preCommitShimPath
    }
    else {
        "<missing>"
    }
    $actualPreCommitPath = if ($resolvedCommands.ContainsKey("pre-commit")) {
        $resolvedCommands["pre-commit"]
    }
    else {
        "<missing>"
    }

    if ($actualPreCommitPath -ne $expectedPreCommitPath) {
        throw (
            "E_TEST_PREPUSH_PRECOMMIT_RESOLUTION_UNEXPECTED: expected pre-commit resolution '{0}', but got '{1}'. Diagnostics: stdout={2}; stderr={3}; path={4}; bash={5}; mode={6}." -f @(
                $expectedPreCommitPath,
                $actualPreCommitPath,
                (Get-PreviewText -Text $preflight.Stdout),
                (Get-PreviewText -Text $preflight.Stderr),
                $PathValue,
                $script:bashCommand.Source,
                $script:bashHostPathMode
            )
        )
    }
}

function script:Invoke-CapturedProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMilliseconds = 10000
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    try {
        if (-not $process.Start()) {
            return [pscustomobject]@{
                ExitCode        = -1
                Stdout          = ""
                Stderr          = "process failed to start"
                TimedOut        = $false
                CaptureTimedOut = $false
            }
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $stopDiagnostic = ""
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                $stopDiagnostic = "E_TEST_CAPTURE_FAILED: process tree cleanup failed: $($_.Exception.Message)"
            }

            $postKillExited = Wait-ProcessExitBounded -Process $process -TimeoutMilliseconds 2000
            $stdoutCapture = Read-ProcessStreamTaskBounded -Task $stdoutTask -StreamName "stdout" -TimeoutMilliseconds 2000
            $stderrCapture = Read-ProcessStreamTaskBounded -Task $stderrTask -StreamName "stderr" -TimeoutMilliseconds 2000
            $diagnostics = @(
                $(if (-not $postKillExited) { "E_TEST_CAPTURE_TIMEOUT: process did not exit after timeout cleanup within 2000 ms." }),
                $stopDiagnostic,
                $stdoutCapture.Diagnostic,
                $stderrCapture.Diagnostic
            )
            $captureDiagnostics = Join-CapturedProcessDiagnostics -Diagnostics $diagnostics
            $stderrText = $stderrCapture.Text
            if (-not [string]::IsNullOrWhiteSpace($captureDiagnostics)) {
                $stderrText = (@($stderrText, $captureDiagnostics) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
            }

            return [pscustomobject]@{
                ExitCode        = 124
                Stdout          = $stdoutCapture.Text
                Stderr          = $stderrText
                TimedOut        = $true
                CaptureTimedOut = (-not $postKillExited) -or $stdoutCapture.TimedOut -or $stderrCapture.TimedOut
            }
        }

        $stdoutCapture = Read-ProcessStreamTaskBounded -Task $stdoutTask -StreamName "stdout" -TimeoutMilliseconds 2000
        $stderrCapture = Read-ProcessStreamTaskBounded -Task $stderrTask -StreamName "stderr" -TimeoutMilliseconds 2000
        $captureDiagnostics = Join-CapturedProcessDiagnostics -Diagnostics @($stdoutCapture.Diagnostic, $stderrCapture.Diagnostic)
        $stderrText = $stderrCapture.Text
        if (-not [string]::IsNullOrWhiteSpace($captureDiagnostics)) {
            $stderrText = (@($stderrText, $captureDiagnostics) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }

        return [pscustomobject]@{
            ExitCode        = $process.ExitCode
            Stdout          = $stdoutCapture.Text
            Stderr          = $stderrText
            TimedOut        = $false
            CaptureTimedOut = $stdoutCapture.TimedOut -or $stderrCapture.TimedOut
        }
    }
    finally {
        $process.Dispose()
    }
}

function script:Remove-BashFiles {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Path = @()
    )

    $pathsToRemove = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pathsToRemove.Count -eq 0) {
        return
    }

    $removeScript = @'
#!/usr/bin/env bash
set -euo pipefail
rm -f -- "$@"
'@
    $removeResult = Invoke-BashHelperScript -Name "remove-files" -Content $removeScript -ArgumentList $pathsToRemove
    if ($removeResult.ExitCode -ne 0) {
        throw "E_TEST_BASH_RM_FAILED: selected Bash runtime could not remove harness temp file(s)."
    }
}

function script:New-PrePushHookHarness {
    param(
        [Parameter(Mandatory = $false)]
        [string]$RootLeafName = ([guid]::NewGuid().ToString("N"))
    )

    $harnessRoot = Join-Path -Path $TestDrive -ChildPath $RootLeafName
    $repoRoot = Join-Path -Path $harnessRoot -ChildPath "repo"
    $binRoot = Join-Path -Path $harnessRoot -ChildPath "bin"
    [void][System.IO.Directory]::CreateDirectory($repoRoot)
    [void][System.IO.Directory]::CreateDirectory($binRoot)

    $hookTimeoutTarget = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Common/HookTimeout.sh"
    [void][System.IO.Directory]::CreateDirectory(([System.IO.Path]::GetDirectoryName($hookTimeoutTarget)))
    Copy-Item -LiteralPath $script:hookTimeoutHelperPath -Destination $hookTimeoutTarget -Force

    $commandLogPath = Join-Path -Path $harnessRoot -ChildPath "commands.log"
    $gitScriptPath = Join-Path -Path $binRoot -ChildPath "git"
    $preCommitScriptPath = Join-Path -Path $binRoot -ChildPath "pre-commit"
    $pwshScriptPath = Join-Path -Path $binRoot -ChildPath "pwsh"

    $fakeGit = @'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'git'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$WALLSTOP_TEST_COMMAND_LOG"

if [[ "$#" -ge 2 && "$1" == "rev-parse" && "$2" == "--show-toplevel" ]]; then
  if [[ -n "${WALLSTOP_TEST_REPO_ROOT_STDERR:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_REPO_ROOT_STDERR" >&2
  fi
  if [[ "${WALLSTOP_TEST_REPO_ROOT_EXIT:-0}" != "0" ]]; then
    printf '%s\n' "${WALLSTOP_TEST_REPO_ROOT_OUTPUT:-fatal: not a git repository}"
    exit "$WALLSTOP_TEST_REPO_ROOT_EXIT"
  fi
  printf '%s\n' "$WALLSTOP_TEST_REPO_ROOT"
  exit 0
fi

if [[ "$#" -ge 4 && "$1" == "rev-parse" && "$2" == "--abbrev-ref" && "$3" == "--symbolic-full-name" ]]; then
  if [[ -n "${WALLSTOP_TEST_UPSTREAM_REF:-}" ]]; then
    printf '%s\n' "$WALLSTOP_TEST_UPSTREAM_REF"
    exit 0
  fi
  exit 1
fi

if [[ "$#" -ge 4 && "$1" == "rev-parse" && "$2" == "--verify" && "$3" == "--quiet" ]]; then
  if [[ "$4" == "origin/HEAD^{commit}" ]]; then
    if [[ "${WALLSTOP_TEST_ORIGIN_HEAD_AVAILABLE:-0}" == "1" ]]; then
      exit 0
    fi
    exit 1
  fi

  if [[ "$4" == *"^" && "${WALLSTOP_TEST_HEAD_PARENT_AVAILABLE:-0}" == "1" ]]; then
    exit 0
  fi

  exit 1
fi

if [[ "$1" == "merge-base" ]]; then
  if [[ "$3" == "origin/HEAD" && -n "${WALLSTOP_TEST_ORIGIN_MERGE_BASE:-}" ]]; then
    printf '%s\n' "$WALLSTOP_TEST_ORIGIN_MERGE_BASE"
    exit 0
  fi

  if [[ -n "${WALLSTOP_TEST_MERGE_BASE:-}" ]]; then
    printf '%s\n' "$WALLSTOP_TEST_MERGE_BASE"
    exit 0
  fi

  exit 1
fi

if [[ "$1" == "diff" ]]; then
  if [[ -n "${WALLSTOP_TEST_DIFF_STDERR:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_DIFF_STDERR" >&2
  fi
  if [[ -n "${WALLSTOP_TEST_DIFF_OUTPUT:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_DIFF_OUTPUT"
  fi
  exit "${WALLSTOP_TEST_DIFF_EXIT:-0}"
fi

if [[ "$1" == "ls-files" ]]; then
  if [[ -n "${WALLSTOP_TEST_LS_FILES_STDERR:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_LS_FILES_STDERR" >&2
  fi
  if [[ -n "${WALLSTOP_TEST_LS_FILES_OUTPUT:-}" ]]; then
    printf '%b' "$WALLSTOP_TEST_LS_FILES_OUTPUT"
  fi
  exit "${WALLSTOP_TEST_LS_FILES_EXIT:-0}"
fi

exit 0
'@

    $fakePreCommit = @'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'pre-commit'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$WALLSTOP_TEST_COMMAND_LOG"
exit 0
'@

    $fakePwsh = @'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'pwsh'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$WALLSTOP_TEST_COMMAND_LOG"

previous_arg=""
for arg in "$@"; do
  if [[ "$previous_arg" == "-FileListPath" || "$previous_arg" == "-TargetFileListPath" ]]; then
    while IFS= read -r listed_file; do
      if [[ -n "$listed_file" ]]; then
        printf 'pwsh-file\t%s\n' "$listed_file" >> "$WALLSTOP_TEST_COMMAND_LOG"
      fi
    done < "$arg"
  fi
  previous_arg="$arg"
done

exit 0
'@

    Write-Utf8NoBomFile -Path $gitScriptPath -Content $fakeGit
    Write-Utf8NoBomFile -Path $preCommitScriptPath -Content $fakePreCommit
    Write-Utf8NoBomFile -Path $pwshScriptPath -Content $fakePwsh

    Set-BashExecutableBit -Path @($gitScriptPath, $preCommitScriptPath, $pwshScriptPath)

    foreach ($utilityName in @("bash", "rm", "sort", "sleep", "timeout", "gtimeout", "awk")) {
        $wrapperPath = Join-Path -Path $binRoot -ChildPath $utilityName
        if (Test-Path -LiteralPath $wrapperPath -PathType Leaf) {
            continue
        }

        $utilityPath = Resolve-BashCommandPath -CommandName $utilityName
        if ([string]::IsNullOrWhiteSpace($utilityPath)) {
            continue
        }

        $escapedUtilityPath = $utilityPath.Replace("'", "'\''")
        Write-Utf8NoBomFile -Path $wrapperPath -Content @"
#!/bin/sh
exec '$escapedUtilityPath' "`$@"
"@
        Set-BashExecutableBit -Path @($wrapperPath)
    }

    $mktempUtilityPath = Resolve-BashCommandPath -CommandName "mktemp"
    if (-not [string]::IsNullOrWhiteSpace($mktempUtilityPath)) {
        $escapedMktempUtilityPath = $mktempUtilityPath.Replace("'", "'\''")
        $mktempWrapperPath = Join-Path -Path $binRoot -ChildPath "mktemp"
        $mktempWrapper = @'
#!/usr/bin/env bash
set -euo pipefail
real_mktemp='__WALLSTOP_REAL_MKTEMP__'

if [[ -n "${WALLSTOP_TEST_MKTEMP_COUNTER_PATH:-}" ]]; then
  count=0
  if [[ -f "$WALLSTOP_TEST_MKTEMP_COUNTER_PATH" ]]; then
    count="$(< "$WALLSTOP_TEST_MKTEMP_COUNTER_PATH")"
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
      count=0
    fi
  fi

  count=$((count + 1))
  printf '%s\n' "$count" > "$WALLSTOP_TEST_MKTEMP_COUNTER_PATH"

  if [[ "$count" == "${WALLSTOP_TEST_MKTEMP_DELAY_CALL:-}" ]]; then
    delay_seconds="${WALLSTOP_TEST_MKTEMP_DELAY_SECONDS:-0}"
    if [[ "$delay_seconds" =~ ^[0-9]+$ && "$delay_seconds" -gt 0 ]]; then
      sleep "$delay_seconds"
    fi
  fi
fi

if [[ "$#" -eq 0 && -n "${WALLSTOP_TEST_MKTEMP_DIRECTORY:-}" ]]; then
  exec "$real_mktemp" "${WALLSTOP_TEST_MKTEMP_DIRECTORY%/}/wallstop-prepush.XXXXXX"
fi

exec "$real_mktemp" "$@"
'@.Replace("__WALLSTOP_REAL_MKTEMP__", $escapedMktempUtilityPath)
        Write-Utf8NoBomFile -Path $mktempWrapperPath -Content $mktempWrapper
        Set-BashExecutableBit -Path @($mktempWrapperPath)
    }

    return [pscustomobject]@{
        Root           = $harnessRoot
        RepoRoot       = $repoRoot
        BinRoot        = $binRoot
        CommandLogPath = $commandLogPath
    }
}

function script:Invoke-PrePushHookHarness {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Harness,

        [Parameter(Mandatory = $false)]
        [string]$Stdin = "",

        [Parameter(Mandatory = $false)]
        [hashtable]$Environment = @{},

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMilliseconds = 10000
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:bashCommand.Source
    $bashHookPath = ConvertTo-BashPath -Path $script:prePushHookPath
    $startInfo.WorkingDirectory = $Harness.RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @($bashHookPath)
    $harnessPath = ConvertTo-BashPath -Path $Harness.BinRoot
    Assert-PrePushHarnessCommandResolution -Harness $Harness -PathValue $harnessPath
    Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "PATH" -Value $harnessPath
    Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "WALLSTOP_TEST_REPO_ROOT" -Value (ConvertTo-BashPath -Path $Harness.RepoRoot)
    Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "WALLSTOP_TEST_COMMAND_LOG" -Value (ConvertTo-BashPath -Path $Harness.CommandLogPath)
    Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "WALLSTOP_PREPUSH_TIMEOUT_SECONDS" -Value "90"

    foreach ($key in $Environment.Keys) {
        Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name ([string]$key) -Value ([string]$Environment[$key])
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "E_CONFIG_ERROR: failed to start pre-push hook harness."
    }

    try {
        $process.StandardInput.Write($Stdin)
        $process.StandardInput.Close()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $stopDiagnostic = ""
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                $stopDiagnostic = "E_TEST_CAPTURE_FAILED: process tree cleanup failed: $($_.Exception.Message)"
            }

            $postKillExited = Wait-ProcessExitBounded -Process $process -TimeoutMilliseconds 2000
            $stdoutCapture = Read-ProcessStreamTaskBounded -Task $stdoutTask -StreamName "stdout" -TimeoutMilliseconds 2000
            $stderrCapture = Read-ProcessStreamTaskBounded -Task $stderrTask -StreamName "stderr" -TimeoutMilliseconds 2000
            $diagnostics = @(
                $(if (-not $postKillExited) { "E_TEST_CAPTURE_TIMEOUT: process did not exit after timeout cleanup within 2000 ms." }),
                $stopDiagnostic,
                $stdoutCapture.Diagnostic,
                $stderrCapture.Diagnostic
            )
            $captureDiagnostics = Join-CapturedProcessDiagnostics -Diagnostics $diagnostics
            $commandLog = if (Test-Path -LiteralPath $Harness.CommandLogPath -PathType Leaf) {
                [System.IO.File]::ReadAllText($Harness.CommandLogPath, [System.Text.Encoding]::UTF8)
            }
            else {
                ""
            }

            throw (
                "E_TEST_TIMEOUT: pre-push hook harness did not exit within {0} ms. postKillExited={1}; stdout={2}; stderr={3}; diagnostics={4}; commandLog={5}" -f
                $TimeoutMilliseconds,
                $postKillExited,
                (Get-PreviewText -Text $stdoutCapture.Text),
                (Get-PreviewText -Text $stderrCapture.Text),
                (Get-PreviewText -Text $captureDiagnostics),
                (Get-PreviewText -Text $commandLog)
            )
        }

        $stdoutCapture = Read-ProcessStreamTaskBounded -Task $stdoutTask -StreamName "stdout" -TimeoutMilliseconds 2000
        $stderrCapture = Read-ProcessStreamTaskBounded -Task $stderrTask -StreamName "stderr" -TimeoutMilliseconds 2000
        $captureDiagnostics = Join-CapturedProcessDiagnostics -Diagnostics @($stdoutCapture.Diagnostic, $stderrCapture.Diagnostic)
        $stderrText = $stderrCapture.Text
        if (-not [string]::IsNullOrWhiteSpace($captureDiagnostics)) {
            $stderrText = (@($stderrText, $captureDiagnostics) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }

        return [pscustomobject]@{
            ExitCode        = $process.ExitCode
            Stdout          = $stdoutCapture.Text
            Stderr          = $stderrText
            CaptureTimedOut = $stdoutCapture.TimedOut -or $stderrCapture.TimedOut
            Log             = if (Test-Path -LiteralPath $Harness.CommandLogPath -PathType Leaf) {
                [System.IO.File]::ReadAllText($Harness.CommandLogPath, [System.Text.Encoding]::UTF8)
            }
            else {
                ""
            }
        }
    }
    finally {
        $process.Dispose()
    }
}

function script:Assert-NoDeepPrePushCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLog
    )

    $CommandLog | Should -Not -Match 'Invoke-FullValidation\.ps1'
    $CommandLog | Should -Not -Match '(?m)(^|\s)-All(\s|$)'
    $CommandLog | Should -Not -Match '--all-files'
}

function script:Assert-PrePushHarnessSucceeded {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    $Result.ExitCode | Should -Be 0 -Because (
        "stdout={0}; stderr={1}; commandLog={2}" -f $Result.Stdout, $Result.Stderr, $Result.Log
    )
}

function script:Assert-LoggedFileListPathsWereRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLog
    )

    $paths = @(
        [regex]::Matches($CommandLog, '(?:-FileListPath|-TargetFileListPath)\t(?<Path>[^\t\r\n]+)') |
            ForEach-Object { $_.Groups["Path"].Value }
    )

    try {
        $paths.Count | Should -BeGreaterThan 0 -Because "pre-push hook should pass changed files through a temp file list."

        $leakedPaths = @($paths | Where-Object { Test-BashFileExists -Path $_ })
        $leakedPaths.Count | Should -Be 0 -Because (
            "pre-push hook EXIT trap must remove temp file lists. Leaked paths: {0}" -f ($leakedPaths -join ", ")
        )
    }
    finally {
        Remove-BashFiles -Path $paths
    }
}

Describe "pre-push Bash harness path conversion" {
    BeforeEach {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }
    }

    It "converts test-drive paths to paths visible from the selected Bash runtime" {
        $pathWithSpaces = Join-Path -Path $TestDrive -ChildPath "path conversion {target}.txt"
        Write-Utf8NoBomFile -Path $pathWithSpaces -Content "path conversion target"

        $bashPath = ConvertTo-BashPath -Path $pathWithSpaces

        $bashPath | Should -Not -BeNullOrEmpty
        Test-BashPathExists -Path $bashPath | Should -BeTrue -Because (Get-BashPathConversionDiagnostics -Path $pathWithSpaces -ConvertedPath $bashPath)
        if (-not $script:requiresBashPathConversion) {
            $bashPath | Should -Be $pathWithSpaces
        }
    }

    It "uses a converted test bin directory as the complete Bash PATH" {
        $binRoot = Join-Path -Path $TestDrive -ChildPath "path command bin {target}"
        [void][System.IO.Directory]::CreateDirectory($binRoot)
        $fakeGitPath = Join-Path -Path $binRoot -ChildPath "git"
        Write-Utf8NoBomFile -Path $fakeGitPath -Content "#!/usr/bin/env bash`nprintf 'fake git selected`n'`n"
        Set-BashExecutableBit -Path @($fakeGitPath)

        $bashBinRoot = ConvertTo-BashPath -Path $binRoot
        $expectedGitPath = ConvertTo-BashPath -Path $fakeGitPath
        $result = Invoke-BashCommandWithPath -PathValue $bashBinRoot -Command "command -v git"

        $result.ExitCode | Should -Be 0 -Because (
            "Bash must accept the converted directory as PATH. Diagnostics: {0}" -f @(
                Get-BashPathConversionDiagnostics -Path $binRoot -ConvertedPath $bashBinRoot
            )
        )
        ($result.Stdout.Trim()) | Should -BeExactly $expectedGitPath -Because (
            "PATH replacement must not leave a Windows Path/PATH duplicate that resolves real Git first. stdout={0}; stderr={1}; path={2}" -f @(
                (Get-PreviewText -Text $result.Stdout),
                (Get-PreviewText -Text $result.Stderr),
                $bashBinRoot
            )
        )
    }
}

Describe "pre-push changed-file hook behavior" {
    BeforeEach {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }
    }

    It "<Name>" -ForEach @(
        @{
            Name                  = "validates files changed against an existing remote ref"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_DIFF_OUTPUT = "Scripts/Utils/Run-PreCommitValidation.ps1`nREADME.md`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = ""
            ExpectedLogPatterns   = @(
                'git\tdiff\t--name-only\t--diff-filter=ACMR\tremote123\.\.local456\t--',
                'pwsh[\s\S]*Invoke-PreCommitWithRecovery\.ps1[\s\S]*-HookStage[\s\S]*pre-push[\s\S]*-FileListPath',
                'pwsh-file\tScripts/Utils/Run-PreCommitValidation\.ps1',
                'pwsh-file\tREADME\.md'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "ignores successful diff stderr output"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_DIFF_OUTPUT = "Scripts/Utils/Run-PreCommitValidation.ps1`nREADME.md`n"
                WALLSTOP_TEST_DIFF_STDERR = "trace: diff probe`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = ""
            ExpectedLogPatterns   = @(
                'git\tdiff\t--name-only\t--diff-filter=ACMR\tremote123\.\.local456\t--',
                'pwsh-file\tScripts/Utils/Run-PreCommitValidation\.ps1',
                'pwsh-file\tREADME\.md'
            )
            UnexpectedLogPattern  = 'trace: diff probe|pwsh-file\ttrace:'
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "uses a resolved upstream merge-base for new branches"
            Stdin                 = "refs/heads/feature local456 refs/heads/feature 0000000000000000000000000000000000000000`n"
            Environment           = @{
                WALLSTOP_TEST_UPSTREAM_REF = "origin/main"
                WALLSTOP_TEST_MERGE_BASE   = "base111"
                WALLSTOP_TEST_DIFF_OUTPUT  = "Scripts/Utils/New-Thing.ps1`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = ""
            ExpectedLogPatterns   = @(
                'git\trev-parse\t--abbrev-ref\t--symbolic-full-name\tfeature@\{upstream\}',
                'git\tmerge-base\tlocal456\torigin/main',
                'git\tdiff\t--name-only\t--diff-filter=ACMR\tbase111\.\.local456\t--',
                'pwsh[\s\S]*-FileListPath',
                'pwsh-file\tScripts/Utils/New-Thing\.ps1'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "skips validation for delete pushes"
            Stdin                 = "refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature remote123`n"
            Environment           = @{}
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'skipping delete push'
            ExpectedLogPatterns   = @()
            UnexpectedLogPattern  = 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
        @{
            Name                  = "skips validation when pre-push receives no stdin ref updates"
            Stdin                 = ""
            Environment           = @{}
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'no ref updates received'
            ExpectedLogPatterns   = @()
            UnexpectedLogPattern  = 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
        @{
            Name                  = "ignores successful repository-root stderr output"
            Stdin                 = ""
            Environment           = @{
                WALLSTOP_TEST_REPO_ROOT_STDERR = "trace: repo-root probe`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'no ref updates received'
            ExpectedLogPatterns   = @('git\trev-parse\t--show-toplevel')
            UnexpectedLogPattern  = 'trace: repo-root probe|E_PREPUSH_REPO_ROOT_UNAVAILABLE|Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
        @{
            Name                  = "falls back to tracked files for new branches without any baseline"
            Stdin                 = "refs/heads/root local456 refs/heads/root 0000000000000000000000000000000000000000`n"
            Environment           = @{
                WALLSTOP_TEST_LS_FILES_OUTPUT = "README.md`nScripts/Utils/Fallback.ps1`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'W_PREPUSH_CHANGED_FILE_BASELINE_MISSING'
            ExpectedLogPatterns   = @(
                'git\tls-files',
                'pwsh[\s\S]*-FileListPath',
                'pwsh-file\tREADME\.md',
                'pwsh-file\tScripts/Utils/Fallback\.ps1'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "ignores successful tracked-file fallback stderr output"
            Stdin                 = "refs/heads/root local456 refs/heads/root 0000000000000000000000000000000000000000`n"
            Environment           = @{
                WALLSTOP_TEST_LS_FILES_OUTPUT = "README.md`nScripts/Utils/Fallback.ps1`n"
                WALLSTOP_TEST_LS_FILES_STDERR = "trace: ls-files probe`n"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'W_PREPUSH_CHANGED_FILE_BASELINE_MISSING'
            ExpectedLogPatterns   = @(
                'git\tls-files',
                'pwsh-file\tREADME\.md',
                'pwsh-file\tScripts/Utils/Fallback\.ps1'
            )
            UnexpectedLogPattern  = 'trace: ls-files probe|pwsh-file\ttrace:'
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "uses legacy PowerShell target-file checks when pre-commit is unavailable"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_DIFF_OUTPUT = ".githooks/pre-push`n"
            }
            RemovePreCommit       = $true
            ExpectedExitCode      = 0
            ExpectedStderrPattern = 'pre-commit is not installed; falling back to legacy PowerShell checks'
            ExpectedLogPatterns   = @(
                'pwsh[\s\S]*Scripts/Utils/Run-PreCommitValidation\.ps1[\s\S]*-IncludePreCommitOwnedChecks[\s\S]*-TargetFileListPath',
                'pwsh-file\t\.githooks/pre-push'
            )
            UnexpectedLogPattern  = ""
            AssertFileListCleanup = $true
        }
        @{
            Name                  = "rejects timeout overrides below the recovery budget contract"
            Stdin                 = ""
            Environment           = @{
                WALLSTOP_PREPUSH_TIMEOUT_SECONDS = "59"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 2
            ExpectedStderrPattern = "E_HOOK_TIMEOUT_CONFIG: WALLSTOP_PREPUSH_TIMEOUT_SECONDS must be an integer >= 60 seconds \(30s inner recovery timeout plus 15s shutdown buffer plus 15s setup slack; received '59'\)\."
            ExpectedLogPatterns   = @('git\trev-parse\t--show-toplevel')
            UnexpectedLogPattern  = 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
        @{
            Name                  = "emits stable diagnostics when repository root cannot be resolved"
            Stdin                 = "refs/heads/main local456 refs/heads/main remote123`n"
            Environment           = @{
                WALLSTOP_TEST_REPO_ROOT_EXIT   = "128"
                WALLSTOP_TEST_REPO_ROOT_OUTPUT = "fatal: not a git repository"
            }
            RemovePreCommit       = $false
            ExpectedExitCode      = 128
            ExpectedStderrPattern = 'E_PREPUSH_REPO_ROOT_UNAVAILABLE: failed to resolve repository root \(exitCode=128; workingDirectory=.*; gitCommand=.*git\)\. Git output: fatal: not a git repository'
            ExpectedLogPatterns   = @('git\trev-parse\t--show-toplevel')
            UnexpectedLogPattern  = 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
            AssertFileListCleanup = $false
        }
    ) {
        $harness = New-PrePushHookHarness
        if ($RemovePreCommit) {
            Remove-Item -LiteralPath (Join-Path -Path $harness.BinRoot -ChildPath "pre-commit") -Force
        }

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin $Stdin -Environment $Environment

        if ($ExpectedExitCode -eq 0) {
            Assert-PrePushHarnessSucceeded -Result $result
        }
        else {
            $result.ExitCode | Should -Be $ExpectedExitCode -Because (
                "stdout={0}; stderr={1}; commandLog={2}" -f $result.Stdout, $result.Stderr, $result.Log
            )
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedStderrPattern)) {
            $result.Stderr | Should -Match $ExpectedStderrPattern
        }

        foreach ($expectedLogPattern in @($ExpectedLogPatterns)) {
            $result.Log | Should -Match $expectedLogPattern
        }

        if (-not [string]::IsNullOrWhiteSpace($UnexpectedLogPattern)) {
            $result.Log | Should -Not -Match $UnexpectedLogPattern
        }

        if ($AssertFileListCleanup) {
            Assert-LoggedFileListPathsWereRemoved -CommandLog $result.Log
        }

        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }

    It "emits real remaining-budget diagnostics after file-list setup consumes slack" {
        $harness = New-PrePushHookHarness
        $mktempCounterPath = Join-Path -Path $harness.Root -ChildPath "mktemp-count.txt"
        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin "refs/heads/main local456 refs/heads/main remote123`n" -TimeoutMilliseconds 25000 -Environment @{
            WALLSTOP_PREPUSH_TIMEOUT_SECONDS     = "60"
            WALLSTOP_TEST_DIFF_OUTPUT            = "README.md`nScripts/Utils/SlowSetup.ps1`n"
            WALLSTOP_TEST_MKTEMP_COUNTER_PATH    = ConvertTo-BashPath -Path $mktempCounterPath
            WALLSTOP_TEST_MKTEMP_DELAY_CALL      = "3"
            WALLSTOP_TEST_MKTEMP_DELAY_SECONDS   = "16"
        }

        $result.ExitCode | Should -Be 124 -Because (
            "stdout={0}; stderr={1}; commandLog={2}" -f $result.Stdout, $result.Stderr, $result.Log
        )
        $result.Stderr | Should -Match 'E_HOOK_TIMEOUT: pre-push changed-file pre-commit validation'
        $result.Stderr | Should -Match 'configuredTimeoutSeconds=60'
        $result.Stderr | Should -Match 'elapsedSetupSeconds=(1[5-9]|[2-9][0-9]+)'
        $result.Stderr | Should -Match 'remainingSeconds=([0-9]|[1-3][0-9]|4[0-4])'
        $result.Stderr | Should -Match 'requiredRemainingSeconds=45'
        $result.Stderr | Should -Match 'timeoutProvider=(timeout|gtimeout|shell-watchdog)'
        $result.Stderr | Should -Match 'changedFileCount=2\.'
        $result.Log | Should -Match 'git\tdiff\t--name-only\t--diff-filter=ACMR\tremote123\.\.local456\t--'
        $result.Log | Should -Not -Match 'Invoke-PreCommitWithRecovery\.ps1|pre-commit\trun|Run-PreCommitValidation\.ps1'
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }

    It "preserves harness arguments with spaces and braces in paths" {
        $harness = New-PrePushHookHarness -RootLeafName ("pre push harness {{argument path}} {0}" -f [guid]::NewGuid().ToString("N"))
        $mktempRoot = Join-Path -Path $harness.Root -ChildPath "temp files {argument path}"
        [void][System.IO.Directory]::CreateDirectory($mktempRoot)

        $result = Invoke-PrePushHookHarness -Harness $harness -Stdin "refs/heads/main local456 refs/heads/main remote123`n" -Environment @{
            WALLSTOP_TEST_DIFF_OUTPUT      = "Scripts/Utils/Path With {Braces}.ps1`nREADME with spaces.md`n"
            WALLSTOP_TEST_MKTEMP_DIRECTORY = ConvertTo-BashPath -Path $mktempRoot
        }

        Assert-PrePushHarnessSucceeded -Result $result
        $result.Log | Should -Match 'pwsh[\s\S]*-FileListPath[\s\S]*temp files \{argument path\}[\s\S]*wallstop-prepush\.'
        $result.Log | Should -Match 'pwsh-file\tScripts/Utils/Path With \{Braces\}\.ps1'
        $result.Log | Should -Match 'pwsh-file\tREADME with spaces\.md'
        Assert-LoggedFileListPathsWereRemoved -CommandLog $result.Log
        Assert-NoDeepPrePushCommand -CommandLog $result.Log
    }
}
