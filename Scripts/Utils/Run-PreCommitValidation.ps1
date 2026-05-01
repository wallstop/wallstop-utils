[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAnalyzer,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 7200)]
    [int]$PesterTimeoutSeconds = 900,

    [Parameter(Mandatory = $false)]
    [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
    [string]$PesterOutputVerbosity = "None"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$moduleHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/ModuleHelpers.ps1"
if (-not (Test-Path -Path $moduleHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Module helper file not found at '$moduleHelpersPath'."
}

.$moduleHelpersPath

$formatSafetyHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/FormatOperatorSafetyHelpers.ps1"
if (-not (Test-Path -Path $formatSafetyHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Format-operator safety helper file not found at '$formatSafetyHelpersPath'."
}

.$formatSafetyHelpersPath

$llmWrapperHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/LlmWrapperContractHelpers.ps1"
if (-not (Test-Path -Path $llmWrapperHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: LLM wrapper helper file not found at '$llmWrapperHelpersPath'."
}

.$llmWrapperHelpersPath

function New-LlmHarnessPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$WrapperFiles
    )

    $patternSegments = New-Object 'System.Collections.Generic.List[string]'
    [void]$patternSegments.Add('\.llm/.+\.md')

    $normalizedWrappers = @(
        $WrapperFiles |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ -replace '[\\/]+', '/' } |
            Sort-Object -Unique
    )

    foreach ($wrapperFile in $normalizedWrappers) {
        [void]$patternSegments.Add([regex]::Escape($wrapperFile))
    }

    [void]$patternSegments.Add('\.github/dependabot\.yml')
    [void]$patternSegments.Add('Scripts/Utils/Quality/(Update-LlmSkillsIndex|Test-LlmHarness)\.ps1')
    [void]$patternSegments.Add('Tests/Utils/LlmHarness\.Tests\.ps1')

    return ('^({0})$' -f ($patternSegments -join '|'))
}

function Get-GitExecutableOrThrow {
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_PRECOMMIT_VALIDATION_GIT_NOT_AVAILABLE: git is required to read staged files but was not found on PATH."
    }

    Write-Verbose ("Pre-commit validation git diagnostics: gitPath='{0}'" -f $gitCommand.Source)
    return $gitCommand.Source
}

function Get-PwshExecutableOrThrow {
    $pwshCommand = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $pwshCommand) {
        throw "E_CONFIG_ERROR: pwsh is required for isolated Pester execution but was not found on PATH."
    }

    Write-Verbose ("Pre-commit validation pwsh diagnostics: pwshPath='{0}'" -f $pwshCommand.Source)
    return $pwshCommand.Source
}

function Get-OutputPreview {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$OutputLines = @(),

        [Parameter(Mandatory = $false)]
        [ValidateRange(2, 200)]
        [int]$MaxPreviewLines = 12
    )

    $normalizedLines = @($OutputLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($normalizedLines.Count -eq 0) {
        return "(no output)"
    }

    $formatPreviewLine = {
        param([string]$Line)

        $trimmed = $Line.Trim()
        if ($trimmed.Length -gt 240) {
            return "$($trimmed.Substring(0, 240))..."
        }

        return $trimmed
    }

    if ($normalizedLines.Count -le $MaxPreviewLines) {
        $previewLines = @($normalizedLines | ForEach-Object {
                & $formatPreviewLine $_
            })
        return ($previewLines -join " | ")
    }

    $headCount = [int][math]::Ceiling($MaxPreviewLines / 2)
    $tailCount = $MaxPreviewLines - $headCount
    if ($tailCount -lt 1) {
        $tailCount = 1
        $headCount = [math]::Max($MaxPreviewLines - $tailCount, 1)
    }

    $headPreview = @($normalizedLines | Select-Object -First $headCount | ForEach-Object {
            $trimmed = $_.Trim()
            if ($trimmed.Length -gt 240) {
                return "$($trimmed.Substring(0, 240))..."
            }

            return $trimmed
        })

    $tailPreview = @($normalizedLines | Select-Object -Last $tailCount | ForEach-Object {
            & $formatPreviewLine $_
        })

    $omittedCount = [math]::Max($normalizedLines.Count - ($headCount + $tailCount), 0)
    return (
        "head: {0} | ... ({1} omitted line(s)) ... | tail: {2}" -f
        ($headPreview -join " | "),
        $omittedCount,
        ($tailPreview -join " | ")
    )
}

function Get-FirstRootErrorCode {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$OutputLines = @()
    )

    foreach ($line in @($OutputLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $match = [regex]::Match($line, '\b(E_[A-Z0-9_]+)\b')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return "unknown"
}

function Get-RedactedFailureLine {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Line
    )

    if ($null -eq $Line) {
        return ""
    }

    $redacted = $Line
    $redacted = [regex]::Replace($redacted, '(?i)(authorization\s*[:=]\s*).+$', '$1[REDACTED]')
    $redacted = [regex]::Replace($redacted, '(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b', '[REDACTED_TOKEN]')
    $redacted = [regex]::Replace($redacted, '(?i)(\b(?:token|password|secret|api[_-]?key|client[_-]?secret|github[_-]?token|access[_-]?token|refresh[_-]?token)\b\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s;]+)', '$1[REDACTED]')

    return $redacted
}

function Test-IsLinkOrReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.IO.FileSystemInfo]$Item
    )

    $linkTypeProperty = $Item.PSObject.Properties['LinkType']
    $hasLinkType = ($null -ne $linkTypeProperty -and -not [string]::IsNullOrWhiteSpace([string]$Item.LinkType))
    $hasReparsePointAttribute = (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    return ($hasReparsePointAttribute -or $hasLinkType)
}

function Resolve-CanonicalPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($rootPath)) {
        throw "E_CONFIG_ERROR: unable to resolve canonical path root for '$Path'."
    }

    $relativePath = $fullPath.Substring($rootPath.Length)
    $pathSeparators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $segments = @($relativePath.Split($pathSeparators, [System.StringSplitOptions]::RemoveEmptyEntries))

    $currentPath = $rootPath
    foreach ($segment in $segments) {
        $candidatePath = Join-Path -Path $currentPath -ChildPath $segment
        if (-not (Test-Path -LiteralPath $candidatePath)) {
            $currentPath = [System.IO.Path]::GetFullPath($candidatePath)
            continue
        }

        $candidateItem = Get-Item -LiteralPath $candidatePath -Force
        if (Test-IsLinkOrReparsePoint -Item $candidateItem) {
            try {
                $linkTargetItem = $candidateItem.ResolveLinkTarget($true)
            }
            catch {
                throw "E_CONFIG_ERROR: unable to resolve symbolic link or reparse point '$candidatePath': $($_.Exception.Message)"
            }

            if ($null -eq $linkTargetItem) {
                throw "E_CONFIG_ERROR: symbolic link or reparse point '$candidatePath' has no resolvable target."
            }

            $currentPath = [System.IO.Path]::GetFullPath($linkTargetItem.FullName)
            continue
        }

        $currentPath = [System.IO.Path]::GetFullPath($candidateItem.FullName)
    }

    return [System.IO.Path]::GetFullPath($currentPath)
}

function Convert-ToRedactedOutputLines {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$OutputLines = @()
    )

    if ($null -eq $OutputLines -or $OutputLines.Count -eq 0) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $redactedLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($OutputLines)) {
        $redactedLines.Add((Get-RedactedFailureLine -Line $line)) | Out-Null
    }

    return @($redactedLines.ToArray()) # array-unwrap-safe: callers always wrap with @()
}

function Write-IsolatedPesterFailureArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SuiteLabel,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootCode,

        [Parameter(Mandatory = $false)]
        [string[]]$StdoutLines = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$StderrLines = @(),

        [Parameter(Mandatory = $false)]
        [bool]$StdoutTruncated = $false,

        [Parameter(Mandatory = $false)]
        [bool]$StderrTruncated = $false,

        [Parameter(Mandatory = $true)]
        [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
        [string]$OutputVerbosity,

        [Parameter(Mandatory = $true)]
        [ValidateRange(30, 7200)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int]$StreamDrainTimeoutMilliseconds,

        [Parameter(Mandatory = $true)]
        [int]$ProcessBookkeepingTimeoutMilliseconds
    )

    $tempRoot = [System.IO.Path]::GetTempPath()
    $resolvedTempRoot = Resolve-CanonicalPath -Path $tempRoot
    $artifactDirectory = Join-Path -Path $resolvedTempRoot -ChildPath "wallstop-precommit-validation"

    $safeSuiteLabel = [regex]::Replace($SuiteLabel, '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeSuiteLabel)) {
        $safeSuiteLabel = "unknown-suite"
    }

    $timestampUtc = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssfffffffZ")
    $artifactNonce = [guid]::NewGuid().ToString("N")
    $artifactFileName = "isolated-pester-{0}-{1}-{2}.log" -f $safeSuiteLabel, $timestampUtc, $artifactNonce
    $artifactPath = Join-Path -Path $artifactDirectory -ChildPath $artifactFileName

    $resolvedRepoRoot = Resolve-CanonicalPath -Path $RepoRoot
    $resolvedArtifactPath = [System.IO.Path]::GetFullPath($artifactPath)
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    $normalizedRepoRoot = $resolvedRepoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $repoRootPrefix = "$normalizedRepoRoot$([System.IO.Path]::DirectorySeparatorChar)"
    if ($resolvedArtifactPath.StartsWith($repoRootPrefix, $comparison) -or $resolvedArtifactPath.Equals($normalizedRepoRoot, $comparison)) {
        throw "E_CONFIG_ERROR: isolated Pester failure artifact path must be outside repository root (repoRoot='$resolvedRepoRoot'; logPath='$resolvedArtifactPath')."
    }

    if (Test-Path -LiteralPath $artifactDirectory -PathType Container) {
        $artifactDirectoryItem = Get-Item -LiteralPath $artifactDirectory -Force
        if (Test-IsLinkOrReparsePoint -Item $artifactDirectoryItem) {
            throw "E_CONFIG_ERROR: isolated Pester failure artifact directory must not be a symbolic link or reparse point (logDirectory='$artifactDirectory')."
        }
    }
    else {
        [void](New-Item -ItemType Directory -Path $artifactDirectory -Force)
    }

    $resolvedArtifactDirectory = Resolve-CanonicalPath -Path $artifactDirectory
    $resolvedArtifactDirectoryItem = Get-Item -LiteralPath $resolvedArtifactDirectory -Force
    if (Test-IsLinkOrReparsePoint -Item $resolvedArtifactDirectoryItem) {
        throw "E_CONFIG_ERROR: isolated Pester failure artifact directory must not be a symbolic link or reparse point (logDirectory='$resolvedArtifactDirectory')."
    }

    $resolvedArtifactPath = Resolve-CanonicalPath -Path (Join-Path -Path $resolvedArtifactDirectory -ChildPath $artifactFileName)
    if ($resolvedArtifactPath.StartsWith($repoRootPrefix, $comparison) -or $resolvedArtifactPath.Equals($normalizedRepoRoot, $comparison)) {
        throw "E_CONFIG_ERROR: isolated Pester failure artifact path must be outside repository root (repoRoot='$resolvedRepoRoot'; logPath='$resolvedArtifactPath')."
    }

    $redactedStdoutLines = @(Convert-ToRedactedOutputLines -OutputLines $StdoutLines)
    $redactedStderrLines = @(Convert-ToRedactedOutputLines -OutputLines $StderrLines)

    $artifactLines = New-Object System.Collections.Generic.List[string]
    $artifactLines.Add("suite=$SuiteLabel") | Out-Null
    $artifactLines.Add("exitCode=$ExitCode") | Out-Null
    $artifactLines.Add("rootCode=$RootCode") | Out-Null
    $artifactLines.Add("capturedAtUtc=$([datetime]::UtcNow.ToString('o'))") | Out-Null
    $artifactLines.Add("outputVerbosity=$OutputVerbosity") | Out-Null
    $artifactLines.Add("timeoutSeconds=$TimeoutSeconds") | Out-Null
    $artifactLines.Add("streamDrainTimeoutMs=$StreamDrainTimeoutMilliseconds") | Out-Null
    $artifactLines.Add("processBookkeepingTimeoutMs=$ProcessBookkeepingTimeoutMilliseconds") | Out-Null
    $artifactLines.Add("stdoutLines=$($redactedStdoutLines.Count)") | Out-Null
    $artifactLines.Add("stderrLines=$($redactedStderrLines.Count)") | Out-Null
    $artifactLines.Add("stdoutTruncated=$StdoutTruncated") | Out-Null
    $artifactLines.Add("stderrTruncated=$StderrTruncated") | Out-Null
    $artifactLines.Add("") | Out-Null
    $artifactLines.Add("[stdout]") | Out-Null
    if ($redactedStdoutLines.Count -eq 0) {
        $artifactLines.Add("(no output)") | Out-Null
    }
    else {
        foreach ($stdoutLine in $redactedStdoutLines) {
            $artifactLines.Add($stdoutLine) | Out-Null
        }
    }

    $artifactLines.Add("") | Out-Null
    $artifactLines.Add("[stderr]") | Out-Null
    if ($redactedStderrLines.Count -eq 0) {
        $artifactLines.Add("(no output)") | Out-Null
    }
    else {
        foreach ($stderrLine in $redactedStderrLines) {
            $artifactLines.Add($stderrLine) | Out-Null
        }
    }

    $artifactContent = (($artifactLines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine
    $fileStream = [System.IO.FileStream]::new(
        $resolvedArtifactPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )

    try {
        $writer = [System.IO.StreamWriter]::new($fileStream, [System.Text.UTF8Encoding]::new($false))
        try {
            $writer.Write($artifactContent)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }

    return $resolvedArtifactPath
}

function Initialize-BoundedProcessCaptureType {
    if ($null -ne ("Wallstop.Utils.BoundedProcessCapture" -as [type])) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;

namespace Wallstop.Utils {
    public sealed class BoundedProcessCapture {
        private readonly int _maxLines;
        private readonly int _maxCharactersPerStream;
        private readonly object _stdoutLock = new object();
        private readonly object _stderrLock = new object();
        private readonly List<string> _stdoutLines = new List<string>();
        private readonly List<string> _stderrLines = new List<string>();
        private int _stdoutCharacterCount;
        private int _stderrCharacterCount;
        private bool _stdoutTruncated;
        private bool _stderrTruncated;
        // Keep continuations off the event-handler thread to avoid context-sensitive callbacks
        // running where no PowerShell runspace exists.
        private readonly TaskCompletionSource<bool> _stdoutCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _stderrCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        public BoundedProcessCapture(int maxLines, int maxCharactersPerStream) {
            _maxLines = maxLines;
            _maxCharactersPerStream = maxCharactersPerStream;
        }

        public bool StdoutTruncated {
            get { return _stdoutTruncated; }
        }

        public bool StderrTruncated {
            get { return _stderrTruncated; }
        }

        public bool IsStdoutCompleted {
            get { return _stdoutCompleted.Task.IsCompleted; }
        }

        public bool IsStderrCompleted {
            get { return _stderrCompleted.Task.IsCompleted; }
        }

        public bool HasStreamFaults {
            get { return _stdoutCompleted.Task.IsFaulted || _stderrCompleted.Task.IsFaulted; }
        }

        public string GetFaultSummary() {
            var faults = new List<string>();

            if (_stdoutCompleted.Task.IsFaulted && _stdoutCompleted.Task.Exception != null) {
                faults.Add("stdout=" + _stdoutCompleted.Task.Exception.GetBaseException().Message);
            }

            if (_stderrCompleted.Task.IsFaulted && _stderrCompleted.Task.Exception != null) {
                faults.Add("stderr=" + _stderrCompleted.Task.Exception.GetBaseException().Message);
            }

            if (faults.Count == 0) {
                return "unknown stream failure";
            }

            return string.Join("; ", faults);
        }

        public bool WaitForDrain(int timeoutMilliseconds) {
            return Task.WaitAll(new Task[] { _stdoutCompleted.Task, _stderrCompleted.Task }, timeoutMilliseconds);
        }

        public string[] GetStdoutLines() {
            lock (_stdoutLock) {
                return _stdoutLines.ToArray();
            }
        }

        public string[] GetStderrLines() {
            lock (_stderrLock) {
                return _stderrLines.ToArray();
            }
        }

        public void Attach(Process process) {
            process.OutputDataReceived += OnOutputDataReceived;
            process.ErrorDataReceived += OnErrorDataReceived;
        }

        public void Detach(Process process) {
            process.OutputDataReceived -= OnOutputDataReceived;
            process.ErrorDataReceived -= OnErrorDataReceived;
        }

        private void OnOutputDataReceived(object sender, DataReceivedEventArgs eventArgs) {
            HandleData(
                eventArgs,
                _stdoutLines,
                _stdoutLock,
                ref _stdoutCharacterCount,
                ref _stdoutTruncated,
                _stdoutCompleted,
                "stdout"
            );
        }

        private void OnErrorDataReceived(object sender, DataReceivedEventArgs eventArgs) {
            HandleData(
                eventArgs,
                _stderrLines,
                _stderrLock,
                ref _stderrCharacterCount,
                ref _stderrTruncated,
                _stderrCompleted,
                "stderr"
            );
        }

        private void HandleData(
            DataReceivedEventArgs eventArgs,
            List<string> lineList,
            object lineLock,
            ref int characterCount,
            ref bool truncated,
            TaskCompletionSource<bool> completion,
            string streamName
        ) {
            try {
                if (eventArgs.Data == null) {
                    completion.TrySetResult(true);
                    return;
                }

                lock (lineLock) {
                    if (truncated) {
                        return;
                    }

                    string line = eventArgs.Data;
                    int nextCharacterCount = characterCount + line.Length + 1;
                    if (lineList.Count >= _maxLines || nextCharacterCount > _maxCharactersPerStream) {
                        truncated = true;
                        lineList.Add("[" + streamName + " output truncated after " + lineList.Count + " line(s)]");
                        return;
                    }

                    lineList.Add(line);
                    characterCount = nextCharacterCount;
                }
            }
            catch (Exception exception) {
                completion.TrySetException(exception);
            }
        }
    }
}
"@
}

function Assert-PreCommitPowerShellModuleAvailability {
    param(
        [Parameter(Mandatory = $false)]
        [switch]$RequirePester,

        [Parameter(Mandatory = $false)]
        [switch]$RequireScriptAnalyzer
    )

    $requirements = New-Object System.Collections.Generic.List[object]

    if ($RequirePester) {
        $requirements.Add([pscustomobject]@{
                ModuleName      = "Pester"
                MinimumVersion  = [version]"5.5.0"
                CommandNames    = @("Invoke-Pester")
                InstallCommand  = "pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules Pester"
                AdditionalNotes = @(
                    "Manual fallback: Install-Module Pester -Repository PSGallery -Scope CurrentUser -MinimumVersion 5.5.0 -Force"
                    "Windows note: built-in Windows PowerShell ships Pester 3.4.0, which is incompatible with this suite."
                )
            }) | Out-Null
    }

    if ($RequireScriptAnalyzer) {
        $requirements.Add([pscustomobject]@{
                ModuleName      = "PSScriptAnalyzer"
                MinimumVersion  = [version]"1.21.0"
                CommandNames    = @("Invoke-ScriptAnalyzer")
                InstallCommand  = "pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules PSScriptAnalyzer"
                AdditionalNotes = @("Manual fallback: Install-Module PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -MinimumVersion 1.21.0 -Force")
            }) | Out-Null
    }

    Assert-ModuleCommandRequirements -Requirements ($requirements.ToArray()) -ErrorCode "E_PRECOMMIT_VALIDATION_MODULES_MISSING" -ContextLabel "Pre-commit module prerequisites"
}

function Invoke-PesterQualityGateInIsolatedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TestPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SuiteLabel,

        [Parameter(Mandatory = $true)]
        [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
        [string]$OutputVerbosity,

        [Parameter(Mandatory = $true)]
        [ValidateRange(30, 7200)]
        [int]$TimeoutSeconds
    )

    $pesterGateScriptPath = Join-Path -Path $RepoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
    if (-not (Test-Path -Path $pesterGateScriptPath -PathType Leaf)) {
        throw "E_CONFIG_ERROR: Pester quality gate script is missing at '$pesterGateScriptPath'."
    }

    if (-not (Test-Path -Path $TestPath)) {
        throw "E_CONFIG_ERROR: Pester test path was not found at '$TestPath'."
    }

    $pwshExecutable = Get-PwshExecutableOrThrow
    $timeoutMilliseconds = $TimeoutSeconds * 1000
    $streamDrainTimeoutMilliseconds = [math]::Min([math]::Max([int]($timeoutMilliseconds / 10), 2000), 15000)
    $processBookkeepingTimeoutMilliseconds = 5000
    $maxCapturedOutputLinesPerStream = 2000
    $maxCapturedOutputCharactersPerStream = 262144
    $process = $null
    $capture = $null

    Initialize-BoundedProcessCaptureType

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshExecutable
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $startInfo.Environment["PSModulePath"] = $env:PSModulePath
        $pathSeparator = [System.IO.Path]::PathSeparator
        $modulePathEntryCount = @($env:PSModulePath -split [regex]::Escape([string]$pathSeparator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        Write-Verbose ("Isolated Pester environment diagnostics: inheritedModulePathEntryCount={0}" -f $modulePathEntryCount)

        foreach ($argument in @(
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-File",
                $pesterGateScriptPath,
                "-TestPath",
                $TestPath,
                "-DiagnosticsPrefix",
                $SuiteLabel,
                "-OutputVerbosity",
                $OutputVerbosity
            )) {
            [void]$startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $capture = [Wallstop.Utils.BoundedProcessCapture]::new($maxCapturedOutputLinesPerStream, $maxCapturedOutputCharactersPerStream)
        $capture.Attach($process)

        if (-not $process.Start()) {
            throw "E_TEST_PROCESS_START_FAILED: unable to start isolated Pester process for $SuiteLabel."
        }

        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        if (-not $process.WaitForExit($timeoutMilliseconds)) {
            try {
                $process.Kill()
            }
            catch {
                # Preserve timeout diagnostics if process termination fails.
            }

            throw "E_TEST_TIMEOUT: $SuiteLabel timed out after $TimeoutSeconds seconds in isolated Pester execution."
        }

        # After process exit, allow a full bounded drain window for async stream callbacks.
        $remainingStreamWaitMilliseconds = $streamDrainTimeoutMilliseconds

        if (-not $capture.WaitForDrain($remainingStreamWaitMilliseconds)) {
            $pendingStreams = New-Object System.Collections.Generic.List[string]
            if (-not $capture.IsStdoutCompleted) {
                $pendingStreams.Add("stdout") | Out-Null
            }
            if (-not $capture.IsStderrCompleted) {
                $pendingStreams.Add("stderr") | Out-Null
            }

            $pendingStreamsText = if ($pendingStreams.Count -gt 0) { $pendingStreams -join "," } else { "unknown" }
            throw "E_TEST_CAPTURE_TIMEOUT: $SuiteLabel output capture exceeded ${remainingStreamWaitMilliseconds}ms after process exit (pendingStreams=$pendingStreamsText)."
        }

        if ($capture.HasStreamFaults) {
            $faultSummary = $capture.GetFaultSummary()
            throw "E_TEST_CAPTURE_FAILED: $SuiteLabel stream capture failed ($faultSummary)."
        }

        $stdoutLines = @($capture.GetStdoutLines())
        $stderrLines = @($capture.GetStderrLines())
        $stdoutWasTruncated = $capture.StdoutTruncated
        $stderrWasTruncated = $capture.StderrTruncated

        try {
            $process.CancelOutputRead()
        }
        catch {
            Write-Verbose "Isolated Pester cleanup diagnostics: unable to cancel stdout read after capture completion."
        }

        try {
            $process.CancelErrorRead()
        }
        catch {
            Write-Verbose "Isolated Pester cleanup diagnostics: unable to cancel stderr read after capture completion."
        }

        # Ensure process bookkeeping has fully settled before reading ExitCode.
        # Use a bounded wait to avoid indefinite hangs in degraded host environments.
        if (-not $process.WaitForExit($processBookkeepingTimeoutMilliseconds)) {
            throw "E_TEST_CAPTURE_TIMEOUT: $SuiteLabel process bookkeeping wait exceeded ${processBookkeepingTimeoutMilliseconds}ms after stream drain completion."
        }

        $combinedLines = @($stdoutLines)
        if ($stderrLines.Count -gt 0) {
            $combinedLines += @($stderrLines | ForEach-Object { "stderr: $_" })
        }

        Write-Verbose (
            "Isolated Pester diagnostics: suite={0}; exitCode={1}; timeoutSeconds={2}; stdoutLines={3}; stderrLines={4}; outputVerbosity={5}; stdoutTruncated={6}; stderrTruncated={7}; streamDrainTimeoutMs={8}; processBookkeepingTimeoutMs={9}" -f
            $SuiteLabel,
            $process.ExitCode,
            $TimeoutSeconds,
            $stdoutLines.Count,
            $stderrLines.Count,
            $OutputVerbosity,
            $stdoutWasTruncated,
            $stderrWasTruncated,
            $streamDrainTimeoutMilliseconds,
            $processBookkeepingTimeoutMilliseconds
        )

        if ($process.ExitCode -ne 0) {
            $rootCode = Get-FirstRootErrorCode -OutputLines $combinedLines
            $redactedCombinedLines = @(Convert-ToRedactedOutputLines -OutputLines $combinedLines)
            $preview = Get-OutputPreview -OutputLines $redactedCombinedLines -MaxPreviewLines 4
            $artifactLogPath = "(artifact-unavailable)"

            try {
                $artifactLogPath = Write-IsolatedPesterFailureArtifact -RepoRoot $RepoRoot -SuiteLabel $SuiteLabel -ExitCode $process.ExitCode -RootCode $rootCode -StdoutLines $stdoutLines -StderrLines $stderrLines -StdoutTruncated:$stdoutWasTruncated -StderrTruncated:$stderrWasTruncated -OutputVerbosity $OutputVerbosity -TimeoutSeconds $TimeoutSeconds -StreamDrainTimeoutMilliseconds $streamDrainTimeoutMilliseconds -ProcessBookkeepingTimeoutMilliseconds $processBookkeepingTimeoutMilliseconds
            }
            catch {
                Write-Verbose (
                    "Isolated Pester artifact diagnostics: suite={0}; exitCode={1}; rootCode={2}; artifactWriteFailure={3}" -f
                    $SuiteLabel,
                    $process.ExitCode,
                    $rootCode,
                    $_.Exception.Message
                )
            }

            Write-Warning (
                "W_TEST_FAILURE_OUTPUT_PREVIEW: suite={0}; exitCode={1}; stdoutLines={2}; stderrLines={3}; preview={4}" -f
                $SuiteLabel,
                $process.ExitCode,
                $stdoutLines.Count,
                $stderrLines.Count,
                $preview
            )
            Write-Warning (
                "W_TEST_FAILURE_ARTIFACT: suite={0}; exitCode={1}; rootCode={2}; logPath={3}" -f
                $SuiteLabel,
                $process.ExitCode,
                $rootCode,
                $artifactLogPath
            )
            throw "E_TEST_FAILURE: $SuiteLabel failed in isolated Pester execution (exitCode=$($process.ExitCode); rootCode=$rootCode; details=see W_TEST_FAILURE_ARTIFACT)."
        }
    }
    finally {
        if ($null -ne $process) {
            if ($null -ne $capture) {
                try {
                    $capture.Detach($process)
                }
                catch {
                    Write-Verbose "Isolated Pester cleanup diagnostics: failed to detach stream capture handlers."
                }
            }

            try {
                $process.Kill()
            }
            catch {
                Write-Verbose "Isolated Pester cleanup diagnostics: failed to kill process '$SuiteLabel': $($_.Exception.Message)"
            }

            try {
                $process.Dispose()
            }
            catch {
                Write-Verbose "Isolated Pester cleanup diagnostics: process resource disposal raised exception: $($_.Exception.Message)"
            }
        }
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
Push-Location -LiteralPath $repoRoot

try {
    $stagedFiles = @()
    if (-not $All) {
        $gitExecutable = Get-GitExecutableOrThrow
        $stagedFileQuery = 'git diff --cached --name-only --diff-filter=ACMR'
        $stagedFileOutput = @(& $gitExecutable diff --cached --name-only --diff-filter=ACMR 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $gitErrorText = if ($stagedFileOutput.Count -gt 0) { $stagedFileOutput -join ' ' } else { '(no output)' }
            throw "E_CONFIG_ERROR: Failed to read staged files using '$stagedFileQuery' (exitCode=$LASTEXITCODE). Git output: $gitErrorText"
        }

        $stagedFiles = $stagedFileOutput
    }

    $utilsTestPattern = '^(Scripts/Utils|Tests/Utils)/.+\.ps1$'
    $githubTestPattern = '^(Scripts/Utils/GitHub|Tests/GitHub)/.+\.ps1$'
    $scriptPattern = '^Scripts/Utils/.+\.ps1$'

    $contextPath = Join-Path -Path $repoRoot -ChildPath '.llm/context.md'
    $llmHarnessPatternSource = 'wrapper-contract'
    $llmHarnessWrapperFiles = @()
    if (Test-Path -Path $contextPath -PathType Leaf) {
        $llmHarnessWrapperFiles = @(Get-WrapperContractEntries -ContextFilePath $contextPath)
        if ($llmHarnessWrapperFiles.Count -eq 0) {
            throw 'E_CONFIG_ERROR: Wrapper Contract section in .llm/context.md lists no wrapper files; cannot derive LLM harness trigger pattern.'
        }
    }
    else {
        $llmHarnessPatternSource = 'fallback-default-wrapper-set'
        $llmHarnessWrapperFiles = @('AGENTS.md', '.github/copilot-instructions.md', 'CLAUDE.md')
    }

    $llmHarnessPattern = New-LlmHarnessPattern -WrapperFiles $llmHarnessWrapperFiles
    Write-Verbose ("LLM harness trigger diagnostics: source={0}; wrapperCount={1}; wrappers={2}; pattern={3}" -f $llmHarnessPatternSource, $llmHarnessWrapperFiles.Count, ($llmHarnessWrapperFiles -join ','), $llmHarnessPattern)

    $utilsTestFiles = @($stagedFiles | Where-Object { $_ -match $utilsTestPattern })
    $githubTestFiles = @($stagedFiles | Where-Object { $_ -match $githubTestPattern })
    $scriptFiles = @($stagedFiles | Where-Object { $_ -match $scriptPattern })
    $llmHarnessFiles = @($stagedFiles | Where-Object { $_ -match $llmHarnessPattern })

    $analyzerTargets = @()
    if ($All) {
        $analyzerTargets = @("Scripts/Utils")
    }
    elseif ($scriptFiles.Count -gt 0) {
        $missingAnalyzerTargets = @(
            $scriptFiles |
                Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) } |
                Sort-Object -Unique
        )
        if ($missingAnalyzerTargets.Count -gt 0) {
            Write-Verbose (
                "ScriptAnalyzer staged-path diagnostics: skippedMissingCount={0}; skippedMissingTargets={1}" -f
                $missingAnalyzerTargets.Count,
                ($missingAnalyzerTargets -join ', ')
            )
        }

        $analyzerTargets = @(
            $scriptFiles |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Sort-Object -Unique
        )
    }

    $runUtilsTests = $All -or $utilsTestFiles.Count -gt 0
    $runGitHubTests = $All -or $githubTestFiles.Count -gt 0
    $runAnalyzer = $analyzerTargets.Count -gt 0
    $runFormatOperatorSafetyCheck = $All -or $scriptFiles.Count -gt 0 -or $utilsTestFiles.Count -gt 0 -or $githubTestFiles.Count -gt 0
    $runLlmHarnessValidation = $All -or $llmHarnessFiles.Count -gt 0
    $analyzerTargetsText = if ($analyzerTargets.Count -gt 0) { $analyzerTargets -join ', ' } else { '(none)' }
    $llmHarnessMatchedFilesText = if ($llmHarnessFiles.Count -gt 0) { $llmHarnessFiles -join ', ' } else { '(none)' }

    Write-Verbose (
        "Validation trigger summary: allMode={0}; stagedCount={1}; runUtilsTests={2}; runGitHubTests={3}; runAnalyzer={4}; analyzerTargetCount={5}; runLlmHarnessValidation={6}" -f
        $All.IsPresent,
        $stagedFiles.Count,
        $runUtilsTests,
        $runGitHubTests,
        $runAnalyzer,
        $analyzerTargets.Count,
        $runLlmHarnessValidation
    )
    Write-Verbose ("ScriptAnalyzer target diagnostics: allMode={0}; targetCount={1}; targets={2}" -f $All.IsPresent, $analyzerTargets.Count, $analyzerTargetsText)

    if ($runLlmHarnessValidation) {
        Write-Host ("Running LLM harness validation... allMode={0}; source={1}; matchedCount={2}" -f $All.IsPresent, $llmHarnessPatternSource, $llmHarnessFiles.Count)
        Write-Verbose ("LLM harness staged-file diagnostics: allMode={0}; source={1}; matchedCount={2}; matchedFiles={3}" -f $All.IsPresent, $llmHarnessPatternSource, $llmHarnessFiles.Count, $llmHarnessMatchedFilesText)
    }
    else {
        Write-Verbose ("Skipping LLM harness validation: allMode={0}; source={1}; matchedCount={2}" -f $All.IsPresent, $llmHarnessPatternSource, $llmHarnessFiles.Count)
    }

    if (-not $runUtilsTests -and -not $runGitHubTests -and -not $runAnalyzer -and -not $runLlmHarnessValidation) {
        Write-Verbose "No staged files requiring utility validation; skipping validation."
        return
    }

    if ($runFormatOperatorSafetyCheck) {
        Write-Verbose (
            "Running format-operator safety validation: allMode={0}; scriptCount={1}; utilsTestCount={2}; githubTestCount={3}" -f
            $All.IsPresent,
            $scriptFiles.Count,
            $utilsTestFiles.Count,
            $githubTestFiles.Count
        )
        Assert-NoFormatOperatorContinuationViolations -RootPath $repoRoot -RelativeRoots @("Scripts", "Tests") -ErrorCode "E_PRECOMMIT_FORMAT_OPERATOR_BINDING" -ContextLabel "Pre-commit PowerShell format-operator safety"
    }

    $requiresPesterModule = $runUtilsTests -or $runGitHubTests
    $requiresScriptAnalyzerModule = (-not $SkipAnalyzer) -and $runAnalyzer
    if ($requiresPesterModule -or $requiresScriptAnalyzerModule) {
        Write-Host "Running PowerShell module prerequisite validation..."
        Assert-PreCommitPowerShellModuleAvailability -RequirePester:$requiresPesterModule -RequireScriptAnalyzer:$requiresScriptAnalyzerModule
    }

    if ($runUtilsTests -or $runGitHubTests) {
        $pesterGateScriptPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
        if (-not (Test-Path -Path $pesterGateScriptPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: Pester quality gate script is missing at '$pesterGateScriptPath'."
        }

        Write-Verbose (
            "Pre-commit Pester execution diagnostics: timeoutSeconds={0}; outputVerbosity={1}; pesterGatePath={2}" -f
            $PesterTimeoutSeconds,
            $PesterOutputVerbosity,
            $pesterGateScriptPath
        )
    }

    if ($runUtilsTests) {
        Write-Host "Running Tests/Utils Pester suite in isolated process..."
        Invoke-PesterQualityGateInIsolatedProcess -RepoRoot $repoRoot -TestPath (Join-Path -Path $repoRoot -ChildPath "Tests/Utils") -SuiteLabel "PreCommitUtils" -OutputVerbosity $PesterOutputVerbosity -TimeoutSeconds $PesterTimeoutSeconds
    }

    if ($runGitHubTests) {
        Write-Host "Running Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1 Pester suite in isolated process..."
        Invoke-PesterQualityGateInIsolatedProcess -RepoRoot $repoRoot -TestPath (Join-Path -Path $repoRoot -ChildPath "Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1") -SuiteLabel "PreCommitGitHub" -OutputVerbosity $PesterOutputVerbosity -TimeoutSeconds $PesterTimeoutSeconds
    }

    if (-not $SkipAnalyzer -and $runAnalyzer) {
        $minimumScriptAnalyzerVersion = [version]"1.21.0"
        $scriptAnalyzerCommand = Get-CommandWithOptionalModuleImport -CommandName "Invoke-ScriptAnalyzer" -ModuleName "PSScriptAnalyzer" -MinimumVersion $minimumScriptAnalyzerVersion
        if ($null -eq $scriptAnalyzerCommand) {
            $installedScriptAnalyzerVersions = Get-AvailableModuleVersionsText -ModuleName "PSScriptAnalyzer"
            throw (
                "E_CONFIG_ERROR: Invoke-ScriptAnalyzer from PSScriptAnalyzer {0} or newer is required but unavailable. Installed versions: {1}. Run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules PSScriptAnalyzer' (or install manually with 'Install-Module PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -MinimumVersion {0} -Force') or re-run with -SkipAnalyzer." -f
                $minimumScriptAnalyzerVersion,
                $installedScriptAnalyzerVersions
            )
        }

        $analyzerRecurse = $All
        Write-Host ("Running ScriptAnalyzer for {0} target(s)..." -f $analyzerTargets.Count)
        Write-Verbose ("ScriptAnalyzer execution diagnostics: recurse={0}; targets={1}" -f $analyzerRecurse, $analyzerTargetsText)
        $analysisResult = New-Object System.Collections.Generic.List[object]
        foreach ($analyzerTarget in $analyzerTargets) {
            $analysisRaw = Invoke-ScriptAnalyzer -Path $analyzerTarget -Settings ".psscriptanalyzer.psd1" -Recurse:$analyzerRecurse -ErrorAction Stop
            if ($null -eq $analysisRaw) {
                continue
            }

            foreach ($analysisIssue in @($analysisRaw)) {
                $analysisResult.Add($analysisIssue) | Out-Null
            }
        }

        $analysisCount = $analysisResult.Count
        if ($analysisCount -gt 0) {
            $firstIssue = $analysisResult[0]
            throw "E_LINT_FAILURE: ScriptAnalyzer reported $analysisCount issue(s). First issue: $($firstIssue.RuleName) at $($firstIssue.ScriptName):$($firstIssue.Line)"
        }
    }

    if ($runLlmHarnessValidation) {
        $llmValidatorPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Test-LlmHarness.ps1"
        if (-not (Test-Path -Path $llmValidatorPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: LLM harness validator is missing at '$llmValidatorPath'."
        }

        & $llmValidatorPath -RootPath $repoRoot
    }

    Write-Host "Pre-commit validation passed."
}
finally {
    Pop-Location
}
