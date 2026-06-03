[CmdletBinding()]
param(
    [string[]]$TargetFiles = @(),
    [switch]$RequireAutoHotkey,
    [switch]$Fix,
    [switch]$StaticOnly,
    [switch]$NoInvokeMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -Path $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Diagnostics helper file not found at '$diagnosticsHelpersPath'."
}

.$diagnosticsHelpersPath

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -Path $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath'."
}

.$compatibilityHelpersPath

function Convert-OutputToStringArray {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Output = @()
    )

    if ($null -eq $Output) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    return @(
        $Output |
            ForEach-Object {
                if ($null -eq $_) {
                    ""
                }
                else {
                    [string]$_
                }
            }
    )
}

function Test-OutputLooksLikeUnsupportedAhkSwitch {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Output = @()
    )

    if ($null -eq $Output -or $Output.Count -eq 0) {
        return $false
    }

    $joined = $Output -join "`n"
    return (
        $joined -match "(?im)(/validate|/ilib)\b.{0,120}(unknown|unrecognized|unrecognised|invalid|unsupported|not\s+recognized|not\s+supported).{0,60}(switch|option|parameter|argument|flag)"
    ) -or (
        $joined -match "(?im)(unknown|unrecognized|unrecognised|invalid|unsupported|not\s+recognized|not\s+supported).{0,60}(switch|option|parameter|argument|flag).{0,120}(/validate|/ilib)\b"
    )
}

function Test-IsAutoHotkeyV1Script {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    # Patterns that appear in AHK v1 but are absent or invalid in AHK v2
    $v1Markers = @(
        '(?m)^\s*#NoEnv\b',
        '(?m)^\s*#Persistent\b',
        '(?m)^\s*SendMode\s+\w',# v1: SendMode Input  (v2: SendMode("Input"))
        '(?m)^\s*SetWorkingDir\s+%',# v1: SetWorkingDir %A_ScriptDir%
        '(?m)^\s*CoordMode\s*,\s*\w',# v1: CoordMode, Mouse, Screen
        '(?m)^\s*SetTimer\s*,\s*\w',# v1: SetTimer, Label, Period
        '(?m)^\s*WinGet\s*,\s*\w',# v1: WinGet, Var, Sub, Win
        '(?m)^\s*WinGetTitle\s*,\s*\w',# v1: WinGetTitle, Var, Win
        '(?m)^\s*WinGetClass\s*,\s*\w',# v1: WinGetClass, Var, Win
        '(?m)^\s*WinGetPos\s*,\s*\w',# v1: WinGetPos, X, Y, W, H, Win
        '(?m)^\s*MouseGetPos\s*,\s*\w',# v1: MouseGetPos, X, Y
        '(?m)^\s*MouseMove\s*,\s*\S',# v1: MouseMove, X, Y, Speed
        '(?m)^\s*(MsgBox|Send|Run|RunWait|Click|Sleep|WinClose|WinMove|WinMinimize|WinMaximize|WinRestore)\s*,',# v1 command syntax: Command, Arg
        '(?m)^\s*IfWinExist\s*,',# v1: IfWinExist, Win
        '(?m)^\s*WinActivate\s*,',# v1: WinActivate, Win
        '(?m)^\s*WinWaitActive\s*,',# v1: WinWaitActive, Win
        '(?m)^\s*VarSetCapacity\s*\(',# v1: VarSetCapacity(Var, Size)
        '(?m)^\s*(Loop|Loop\s*,)\s*%' # v1: Loop, % expr
    )

    foreach ($pattern in $v1Markers) {
        if ($Content -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-AutoHotkeyRequiresV2Directive {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $normalized = $Content -replace "`r", ""
    if ($normalized.Length -gt 0 -and $normalized[0] -eq [char]0xfeff) {
        $normalized = $normalized.Substring(1)
    }

    $lines = @($normalized -split "`n")
    $lineIndex = 0
    while ($lineIndex -lt $lines.Count) {
        $trimmed = $lines[$lineIndex].TrimStart()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith(';')) {
            $lineIndex += 1
            continue
        }

        break
    }

    if ($lineIndex -lt $lines.Count) {
        $firstCodeLine = $lines[$lineIndex]
        if ($firstCodeLine -match '^\s*#Requires\s+AutoHotkey\s+v2(?:\.\d+)?\b') {
            return [pscustomobject]@{
                IsValid   = $true
                ErrorCode = ""
                Message   = ""
            }
        }

        if ($normalized -match '(?im)^\s*#Requires\s+AutoHotkey\s+v2(?:\.\d+)?\b') {
            return [pscustomobject]@{
                IsValid   = $false
                ErrorCode = "E_AHK_REQUIRES_V2_NOT_TOP_LEVEL"
                Message   = "#Requires AutoHotkey v2 (or v2.x) must be the first non-comment, non-blank line."
            }
        }
    }

    return [pscustomobject]@{
        IsValid   = $false
        ErrorCode = "E_AHK_REQUIRES_V2_MISSING"
        Message   = "Script must declare #Requires AutoHotkey v2 (or v2.x) at the top with only optional leading blank/comment lines."
    }
}

function Add-AutoHotkeyRequiresV2Directive {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $normalized = $Content -replace "`r", ""
    if ($normalized.Length -gt 0 -and $normalized[0] -eq [char]0xfeff) {
        $normalized = $normalized.Substring(1)
    }

    if ([string]::IsNullOrEmpty($normalized)) {
        return "#Requires AutoHotkey v2.0`n"
    }

    return "#Requires AutoHotkey v2.0`n`n$normalized"
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-RepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-RelativePathCompat -BasePath $RepoRoot -TargetPath $Path).Replace([System.IO.Path]::DirectorySeparatorChar, '/').Replace([System.IO.Path]::AltDirectorySeparatorChar, '/')
}

function Test-IsPathUnderDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        return $false
    }

    $resolvedDirectory = (Resolve-Path -LiteralPath $DirectoryPath -ErrorAction Stop).Path
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $relative = Get-RelativePathCompat -BasePath $resolvedDirectory -TargetPath $resolvedPath
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $true
    }

    return (-not [System.IO.Path]::IsPathRooted($relative)) -and
    $relative -ne '..' -and
    -not $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)") -and
    -not $relative.StartsWith("..$([System.IO.Path]::AltDirectorySeparatorChar)")
}

function Repair-AutoHotkeyStaticViolation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [object]$RequiresResult,

        [Parameter(Mandatory = $true)]
        [bool]$HasV1Syntax
    )

    $configRoot = Join-Path -Path $RepoRoot -ChildPath "Config/.config"
    $scriptSourceRoot = Join-Path -Path $RepoRoot -ChildPath "Scripts/AutoHotKey"

    if ($HasV1Syntax -and (Test-IsPathUnderDirectory -DirectoryPath $configRoot -Path $File.FullName)) {
        $relativeConfigPath = Get-RelativePathCompat -BasePath $configRoot -TargetPath $File.FullName
        $sourceCandidate = Join-Path -Path $scriptSourceRoot -ChildPath $relativeConfigPath
        if (Test-Path -LiteralPath $sourceCandidate -PathType Leaf) {
            $sourceContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $sourceCandidate).Path, [System.Text.Encoding]::UTF8)
            $sourceRequiresResult = Test-AutoHotkeyRequiresV2Directive -Content $sourceContent
            if ($sourceRequiresResult.IsValid -and -not (Test-IsAutoHotkeyV1Script -Content $sourceContent)) {
                Write-Utf8NoBomFile -Path $File.FullName -Content $sourceContent
                return [pscustomobject]@{
                    Fixed    = $true
                    Strategy = "snapshot-source-refresh"
                }
            }
        }
    }

    if ((-not $HasV1Syntax) -and (-not $RequiresResult.IsValid) -and $RequiresResult.ErrorCode -eq "E_AHK_REQUIRES_V2_MISSING") {
        $updatedContent = Add-AutoHotkeyRequiresV2Directive -Content $Content
        Write-Utf8NoBomFile -Path $File.FullName -Content $updatedContent
        return [pscustomobject]@{
            Fixed    = $true
            Strategy = "insert-requires-v2"
        }
    }

    return [pscustomobject]@{
        Fixed    = $false
        Strategy = "manual-migration-required"
    }
}

function Convert-CapturedTextToLines {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Text = ""
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $normalized = $Text -replace "`r", ""
    $lines = @($normalized -split "`n")

    while ($lines.Count -gt 0 -and [string]::IsNullOrEmpty($lines[$lines.Count - 1])) {
        if ($lines.Count -eq 1) {
            return @() # array-unwrap-safe: callers always wrap with @()
        }

        $lines = @($lines[0..($lines.Count - 2)])
    }

    return @($lines)
}

function Invoke-AutoHotkeyCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    # Process-level capture is more reliable than call-operator redirection for GUI-subsystem
    # binaries (such as AutoHotkey64.exe on CI), and keeps behavior consistent cross-platform.
    # Argument passing goes through Set-PortableProcessArguments so special characters (curly
    # braces, double quotes) are escaped exactly as .NET Core's ArgumentList would, without the
    # Start-Process -ArgumentList mangling: it uses the native ArgumentList collection on
    # PowerShell 7+ and an equivalently escaped .Arguments string on Windows PowerShell 5.1,
    # whose .NET Framework ProcessStartInfo has no ArgumentList property.
    $process = $null
    $stdoutLines = @()
    $stderrLines = @()
    $captureMode = "dotnet-process"
    $processTimeoutMilliseconds = 30000
    $streamDrainTimeoutMilliseconds = [math]::Min([math]::Max([int]($processTimeoutMilliseconds / 10), 1500), 10000)

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Executable
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList $Arguments

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            throw "Process start returned false."
        }

        $captureStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $stdoutReadTask = $process.StandardOutput.ReadToEndAsync()
        $stderrReadTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($processTimeoutMilliseconds)) {
            try {
                $process.Kill()
            }
            catch {
                # Preserve original timeout context if kill fails.
            }
            throw "E_AHK_PROCESS_TIMEOUT: executable='$Executable', timeout_ms=$processTimeoutMilliseconds"
        }

        $remainingStreamWaitMilliseconds = $processTimeoutMilliseconds - [int]$captureStopwatch.ElapsedMilliseconds
        if ($remainingStreamWaitMilliseconds -lt $streamDrainTimeoutMilliseconds) {
            $remainingStreamWaitMilliseconds = $streamDrainTimeoutMilliseconds
        }

        if (-not [System.Threading.Tasks.Task]::WaitAll(@($stdoutReadTask, $stderrReadTask), $remainingStreamWaitMilliseconds)) {
            throw "E_AHK_STREAM_CAPTURE_TIMEOUT: executable='$Executable', timeout_ms=$remainingStreamWaitMilliseconds"
        }

        if ($stdoutReadTask.IsFaulted -or $stderrReadTask.IsFaulted) {
            $streamFaults = New-Object System.Collections.Generic.List[string]
            if ($stdoutReadTask.IsFaulted -and $null -ne $stdoutReadTask.Exception) {
                $streamFaults.Add("stdout=$($stdoutReadTask.Exception.GetBaseException().Message)") | Out-Null
            }
            if ($stderrReadTask.IsFaulted -and $null -ne $stderrReadTask.Exception) {
                $streamFaults.Add("stderr=$($stderrReadTask.Exception.GetBaseException().Message)") | Out-Null
            }

            $faultSummary = if ($streamFaults.Count -gt 0) { ($streamFaults -join "; ") } else { "unknown stream fault" }
            throw "E_AHK_STREAM_CAPTURE_FAILED: executable='$Executable', details='$faultSummary'"
        }

        $stdoutText = $stdoutReadTask.GetAwaiter().GetResult()
        $stderrText = $stderrReadTask.GetAwaiter().GetResult()

        $stdoutLines = @(Convert-CapturedTextToLines -Text $stdoutText)
        $stderrLines = @(Convert-CapturedTextToLines -Text $stderrText)

        $rawOutput = @($stdoutLines)
        if ($stderrLines.Count -gt 0) {
            $rawOutput += @(
                $stderrLines | ForEach-Object {
                    "stderr: $_"
                }
            )
        }

        $captureDiagnostics = [pscustomobject]@{
            CaptureMode                    = $captureMode
            Executable                     = $Executable
            ArgumentCount                  = $Arguments.Count
            StdOutLineCount                = $stdoutLines.Count
            StdErrLineCount                = $stderrLines.Count
            TimeoutMilliseconds            = $processTimeoutMilliseconds
            StreamDrainTimeoutMilliseconds = $streamDrainTimeoutMilliseconds
            StdOutCaptureExists            = $false
            StdErrCaptureExists            = $false
        }

        return [pscustomobject]@{
            ExitCode    = [int]$process.ExitCode
            Output      = (Convert-OutputToStringArray -Output $rawOutput)
            Diagnostics = $captureDiagnostics
        }
    }
    catch {
        $argPreview = if ($Arguments.Count -gt 0) { ($Arguments -join " ") } else { "(none)" }
        $exceptionMessage = $_.Exception.Message
        $startFailure = if ($exceptionMessage -match '^E_AHK_[A-Z_]+:') {
            $exceptionMessage
        }
        else {
            "E_AHK_PROCESS_EXECUTION_FAILED: mode='$captureMode', executable='$Executable', args='$argPreview', error=$exceptionMessage"
        }

        return [pscustomobject]@{
            ExitCode    = -1
            Output      = @($startFailure)
            Diagnostics = [pscustomobject]@{
                CaptureMode                    = $captureMode
                Executable                     = $Executable
                ArgumentCount                  = $Arguments.Count
                StdOutLineCount                = 0
                StdErrLineCount                = 0
                TimeoutMilliseconds            = $processTimeoutMilliseconds
                StreamDrainTimeoutMilliseconds = $streamDrainTimeoutMilliseconds
                StdOutCaptureExists            = $false
                StdErrCaptureExists            = $false
            }
        }
    }
    finally {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            }
            catch {
                # Best-effort process cleanup.
            }

            $process.Dispose()
        }
    }
}

function Invoke-AutoHotkeyValidationCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $attemptResults = @()
    # /iLib NUL is a compatibility fallback for runtimes where /validate is unavailable.
    # It still performs parser-level loading and returns a non-zero exit code on syntax failures.
    $attemptDefinitions = @(
        [pscustomobject]@{
            Mode = "/validate"
            Args = @("/ErrorStdOut", "/validate", $ScriptPath)
        },
        [pscustomobject]@{
            Mode = "/iLib"
            Args = @("/ErrorStdOut", "/iLib", "NUL", $ScriptPath)
        }
    )

    foreach ($attempt in $attemptDefinitions) {
        $commandResult = Invoke-AutoHotkeyCommand -Executable $Executable -arguments $attempt.Args
        $attemptResult = [pscustomobject]@{
            Mode     = $attempt.Mode
            ExitCode = $commandResult.ExitCode
            Output   = @($commandResult.Output)
        }

        $attemptResults += , $attemptResult

        if ($attemptResult.ExitCode -eq 0) {
            return [pscustomobject]@{
                Status   = "ok"
                Mode     = $attempt.Mode
                Attempts = @($attemptResults)
            }
        }

        $hasActualOutput = (
            $null -ne $attemptResult.Output -and
            $attemptResult.Output.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace($attemptResult.Output -join "")
        )

        # Only report definitive validation failure when there is actual diagnostic output that does
        # not look like an unsupported-switch message. A non-zero exit code with NO output (e.g.,
        # exit code -1 returned by AHK v2 when processing an AHK v1 script) is ambiguous, so fall
        # through to try the next validation mode before concluding the validation is unsupported.
        if ($hasActualOutput -and -not (Test-OutputLooksLikeUnsupportedAhkSwitch -Output $attemptResult.Output)) {
            return [pscustomobject]@{
                Status   = "validation-failed"
                Mode     = $attempt.Mode
                Attempts = @($attemptResults)
            }
        }
    }

    return [pscustomobject]@{
        Status   = "unsupported"
        Mode     = ""
        Attempts = @($attemptResults)
    }
}

function Get-AutoHotkeyAttemptDiagnostics {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Attempts = @()
    )

    if ($null -eq $Attempts -or $Attempts.Count -eq 0) {
        return "(no command attempts recorded)"
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($attempt in $Attempts) {
        $preview = Get-OutputPreview -Output @($attempt.Output) -MaxLength 240 -CollapseWhitespace
        $parts.Add("$($attempt.Mode): exit=$($attempt.ExitCode), output=$preview") | Out-Null
    }

    return ($parts -join " | ")
}

function Test-AutoHotkeyAttemptsProducedNoOutput {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Attempts = @()
    )

    if ($null -eq $Attempts -or $Attempts.Count -eq 0) {
        return $false
    }

    foreach ($attempt in $Attempts) {
        $output = @($attempt.Output)
        if ($output.Count -eq 0) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace(($output -join ""))) {
            return $false
        }
    }

    return $true
}

function Get-AutoHotkeyExecutablePath {
    $commandCandidates = @("AutoHotkey64.exe", "AutoHotkey.exe", "autohotkey")
    foreach ($candidate in $commandCandidates) {
        $command = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            return $command.Source
        }
    }

    $pathCandidates = @(
        "$env:ProgramFiles/AutoHotkey/v2/AutoHotkey64.exe",
        "$env:ProgramFiles/AutoHotkey/AutoHotkey64.exe",
        "$env:ProgramFiles/AutoHotkey/AutoHotkey.exe",
        "$env:ProgramFiles(x86)/AutoHotkey/AutoHotkey.exe"
    )
    foreach ($candidate in $pathCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -Path $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Resolve-RequestedTargetFilePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$TargetFiles = @()
    )

    $targetFileInputs = @($TargetFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($targetFileInputs.Count -eq 0) {
        return , @()
    }

    $requested = New-Object System.Collections.Generic.List[string]
    foreach ($targetFileInput in $targetFileInputs) {
        $candidates = @($targetFileInput -split "(`r`n|`n|`r|;)")
        foreach ($candidateRaw in $candidates) {
            $candidate = $candidateRaw.Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            $resolvedPath = $null
            if ([System.IO.Path]::IsPathRooted($candidate)) {
                if (Test-Path -Path $candidate -PathType Leaf) {
                    $resolvedPath = (Resolve-Path -Path $candidate -ErrorAction Stop).Path
                }
            }
            else {
                $relativePath = $candidate.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\\', [System.IO.Path]::DirectorySeparatorChar)
                $absoluteCandidate = Join-Path -Path $RepoRoot -ChildPath $relativePath
                if (Test-Path -Path $absoluteCandidate -PathType Leaf) {
                    $resolvedPath = (Resolve-Path -Path $absoluteCandidate -ErrorAction Stop).Path
                }
            }

            if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
                continue
            }

            $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
            if ($extension -ne ".ahk" -and $extension -ne ".bat") {
                continue
            }

            $requested.Add($resolvedPath) | Out-Null
        }
    }

    if ($requested.Count -eq 0) {
        return , @()
    }

    return , @($requested | Sort-Object -Unique)
}

function Test-AutoHotkeyScripts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RequestedTargetFilePaths = @(),

        [Parameter(Mandatory = $false)]
        [switch]$UseTargetedScope,

        [Parameter(Mandatory = $false)]
        [switch]$RequireAutoHotkey,

        [Parameter(Mandatory = $false)]
        [switch]$Fix,

        [Parameter(Mandatory = $false)]
        [switch]$StaticOnly
    )

    $ahkFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    # Keep targeted mode explicit even when resolution produced zero files (no full-repo fallback).
    if ($UseTargetedScope -or $RequestedTargetFilePaths.Count -gt 0) {
        Write-Verbose "AutoHotkey checks: targeted scope enabled; resolved target candidates=$($RequestedTargetFilePaths.Count)."
        foreach ($targetPath in $RequestedTargetFilePaths) {
            if ([System.IO.Path]::GetExtension($targetPath).ToLowerInvariant() -ne ".ahk") {
                continue
            }

            if (Test-Path -Path $targetPath -PathType Leaf) {
                $ahkFiles.Add((Get-Item -LiteralPath $targetPath -ErrorAction Stop)) | Out-Null
            }
        }
    }
    else {
        $searchRoots = @(
            (Join-Path -Path $RepoRoot -ChildPath "Scripts/AutoHotKey"),
            (Join-Path -Path $RepoRoot -ChildPath "Config/.config")
        )

        foreach ($root in $searchRoots) {
            if (Test-Path -Path $root -PathType Container) {
                Get-ChildItem -Path $root -Filter "*.ahk" -File -Recurse -ErrorAction Stop | ForEach-Object {
                    $ahkFiles.Add($_) | Out-Null
                }
            }
        }
    }

    if ($ahkFiles.Count -eq 0) {
        Write-Verbose "AutoHotkey checks: no .ahk files found for selected scope; skipping."
        return
    }

    Write-Verbose "AutoHotkey checks: running dependency-free static validation for $($ahkFiles.Count) file(s)."
    $maxStaticPasses = if ($Fix) { 2 } else { 1 }
    $staticFailures = New-Object System.Collections.Generic.List[string]

    for ($staticPass = 1; $staticPass -le $maxStaticPasses; $staticPass++) {
        $staticFailures.Clear()
        $repairsAppliedThisPass = 0

        foreach ($file in $ahkFiles) {
            $relative = ConvertTo-RepositoryRelativePath -RepoRoot $RepoRoot -Path $file.FullName
            $fileContent = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
            $requiresResult = Test-AutoHotkeyRequiresV2Directive -Content $fileContent
            $hasV1Syntax = Test-IsAutoHotkeyV1Script -Content $fileContent

            if ((-not $requiresResult.IsValid) -or $hasV1Syntax) {
                if ($Fix) {
                    $repairResult = Repair-AutoHotkeyStaticViolation -RepoRoot $RepoRoot -File $file -Content $fileContent -RequiresResult $requiresResult -HasV1Syntax $hasV1Syntax
                    if ($repairResult.Fixed) {
                        $repairsAppliedThisPass += 1
                        Write-Host "Auto-repaired AutoHotkey static violation: $relative ($($repairResult.Strategy))."
                        $fileContent = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
                        $requiresResult = Test-AutoHotkeyRequiresV2Directive -Content $fileContent
                        $hasV1Syntax = Test-IsAutoHotkeyV1Script -Content $fileContent
                    }
                }

                if (-not $requiresResult.IsValid) {
                    $staticFailures.Add("$relative :: $($requiresResult.ErrorCode): $($requiresResult.Message)") | Out-Null
                }
                if ($hasV1Syntax) {
                    $staticFailures.Add("$relative :: E_AHK_V1_SYNTAX_DETECTED: Script uses AHK v1 syntax. Migrate to AHK v2 (https://www.autohotkey.com/docs/v2/).") | Out-Null
                }
            }
        }

        if ($staticFailures.Count -eq 0) {
            break
        }

        if ((-not $Fix) -or $staticPass -ge $maxStaticPasses -or $repairsAppliedThisPass -eq 0) {
            break
        }

        Write-Verbose "AutoHotkey checks: running follow-up static validation pass after auto-repair updates."
    }

    if ($staticFailures.Count -gt 0) {
        throw "E_AHK_STATIC_VALIDATION_FAILED: AutoHotkey static validation failed for: $($staticFailures -join '; ')"
    }

    if ($StaticOnly) {
        Write-Verbose "AutoHotkey checks: static-only mode enabled; skipping runtime validation."
        return
    }

    $ahkExecutable = Get-AutoHotkeyExecutablePath
    if ([string]::IsNullOrWhiteSpace($ahkExecutable)) {
        if ($RequireAutoHotkey) {
            throw "E_AHK_UNAVAILABLE: AutoHotkey executable not found while AutoHotkey validation is required."
        }

        Write-Warning "W_AHK_UNAVAILABLE: AutoHotkey executable not found. Skipping AutoHotkey validation."
        return
    }

    Write-Verbose "AutoHotkey checks: validating $($ahkFiles.Count) file(s) with runtime switch probing (/validate, then /iLib fallback)."
    Write-Verbose "AutoHotkey checks: using executable '$ahkExecutable'."
    $failures = New-Object System.Collections.Generic.List[string]
    $unsupportedMessage = ""

    foreach ($file in $ahkFiles) {
        $relative = ConvertTo-RepositoryRelativePath -RepoRoot $RepoRoot -Path $file.FullName

        $validationResult = Invoke-AutoHotkeyValidationCommand -Executable $ahkExecutable -ScriptPath $file.FullName
        $attemptDiagnostics = Get-AutoHotkeyAttemptDiagnostics -Attempts @($validationResult.Attempts)

        if ($validationResult.Status -eq "ok") {
            continue
        }

        if ($validationResult.Status -eq "unsupported") {
            $unsupportedMessage = "'$ahkExecutable' could not validate '$relative' because all validation switch probes failed. $attemptDiagnostics"

            if (Test-AutoHotkeyAttemptsProducedNoOutput -Attempts @($validationResult.Attempts)) {
                $unsupportedMessage = "$unsupportedMessage Hint: all probe attempts returned no output. This commonly indicates a runtime execution/capture issue (for example, GUI-subsystem behavior in headless CI), not just unsupported switches."
            }

            if ($RequireAutoHotkey) {
                throw "E_AHK_VALIDATE_UNAVAILABLE: $unsupportedMessage"
            }

            Write-Warning "W_AHK_VALIDATE_UNAVAILABLE: $unsupportedMessage"
            break
        }

        $failures.Add("$relative :: mode=$($validationResult.Mode) :: $attemptDiagnostics") | Out-Null
    }

    if ($failures.Count -gt 0) {
        throw "E_AHK_VALIDATION_FAILED: AutoHotkey validation failed for: $($failures -join '; ')"
    }

    if (-not [string]::IsNullOrWhiteSpace($unsupportedMessage)) {
        Write-Verbose "AutoHotkey checks: skipped remaining AutoHotkey file validation because runtime probing showed validation switches unavailable."
    }
}

function Test-BatchScriptsStaticSmoke {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RequestedTargetFilePaths = @(),

        [Parameter(Mandatory = $false)]
        [switch]$UseTargetedScope
    )

    $batchFiles = @()
    # Keep targeted mode explicit even when resolution produced zero files (no full-repo fallback).
    if ($UseTargetedScope -or $RequestedTargetFilePaths.Count -gt 0) {
        Write-Verbose "Batch checks: targeted scope enabled; resolved target candidates=$($RequestedTargetFilePaths.Count)."
        $batchFiles = @(
            $RequestedTargetFilePaths |
                Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -eq ".bat" } |
                ForEach-Object {
                    if (Test-Path -Path $_ -PathType Leaf) {
                        Get-Item -LiteralPath $_ -ErrorAction Stop
                    }
                }
        )
    }
    else {
        $batchFiles = @(Get-ChildItem -Path (Join-Path -Path $RepoRoot -ChildPath "Scripts") -Filter "*.bat" -File -Recurse -ErrorAction Stop)
    }

    if ($batchFiles.Count -eq 0) {
        Write-Verbose "Batch checks: no .bat files found for selected scope; skipping."
        return
    }

    Write-Verbose "Batch checks: running best-effort static smoke checks for $($batchFiles.Count) file(s)."
    Write-Verbose "Batch checks limitation: this is heuristic validation and does not fully parse cmd.exe syntax."

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($file in $batchFiles) {
        $lines = @(Get-Content -Path $file.FullName -ErrorAction Stop)
        $parenBalance = 0

        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]
            $lineNumber = $index + 1
            $relative = Get-RelativePathCompat -BasePath $RepoRoot -TargetPath $file.FullName

            if ($line -match "\s+$") {
                $violations.Add("${relative}:$lineNumber trailing whitespace") | Out-Null
            }
            if ($line -match "^\t+") {
                $violations.Add("${relative}:$lineNumber leading tabs") | Out-Null
            }
            if ($line -match "^(<<<<<<<|=======|>>>>>>>)") {
                $violations.Add("${relative}:$lineNumber unresolved merge marker") | Out-Null
            }

            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }
            if ($trimmed -match "^(?i)(::|REM\b)") {
                continue
            }

            $openCount = [regex]::Matches($line, "(?<!\^)\(").Count
            $closeCount = [regex]::Matches($line, "(?<!\^)\)").Count
            $parenBalance += ($openCount - $closeCount)

            if ($parenBalance -lt 0) {
                $violations.Add("${relative}:$lineNumber parenthesis balance became negative") | Out-Null
                $parenBalance = 0
            }
        }

        if ($parenBalance -ne 0) {
            $relative = Get-RelativePathCompat -BasePath $RepoRoot -TargetPath $file.FullName
            $violations.Add("$relative unbalanced parentheses at end-of-file") | Out-Null
        }
    }

    if ($violations.Count -gt 0) {
        throw "E_BATCH_SMOKE_FAILED: Batch static smoke checks failed. Violations: $($violations -join '; ')"
    }
}

function Invoke-Main {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$TargetFiles = @(),

        [Parameter(Mandatory = $false)]
        [switch]$RequireAutoHotkey,

        [Parameter(Mandatory = $false)]
        [switch]$Fix,

        [Parameter(Mandatory = $false)]
        [switch]$StaticOnly
    )

    $repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../../..")).Path
    $requestedTargetFilePaths = Resolve-RequestedTargetFilePaths -RepoRoot $repoRoot -TargetFiles $TargetFiles
    $targetedModeRequested = @($TargetFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0

    if ($targetedModeRequested) {
        Write-Verbose "Windows language checks: targeted mode requested via TargetFiles input."
    }

    if ($requestedTargetFilePaths.Count -gt 0) {
        Write-Verbose "Windows language checks: running in targeted mode for $($requestedTargetFilePaths.Count) file(s)."
    }
    elseif ($targetedModeRequested) {
        Write-Verbose "Windows language checks: targeted mode resolved zero existing .ahk/.bat files; skipping targeted checks without full-repo fallback."
    }

    Test-AutoHotkeyScripts -RepoRoot $repoRoot -RequestedTargetFilePaths $requestedTargetFilePaths -UseTargetedScope:$targetedModeRequested -RequireAutoHotkey:$RequireAutoHotkey -Fix:$Fix -StaticOnly:$StaticOnly
    Test-BatchScriptsStaticSmoke -RepoRoot $repoRoot -RequestedTargetFilePaths $requestedTargetFilePaths -UseTargetedScope:$targetedModeRequested

    Write-Host "Windows language checks passed."
}

if (-not $NoInvokeMain) {
    Invoke-Main -TargetFiles $TargetFiles -RequireAutoHotkey:$RequireAutoHotkey -Fix:$Fix -StaticOnly:$StaticOnly
}
