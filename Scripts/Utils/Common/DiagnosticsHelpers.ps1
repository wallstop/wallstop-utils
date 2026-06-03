function Get-OutputPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Alias('Output')]
        [object[]]$OutputLines = @(),

        [Parameter(Mandatory = $false)]
        [Alias('MaxPreviewLines')]
        [ValidateRange(1, 200)]
        [int]$MaxLines = 5,

        [Parameter(Mandatory = $false)]
        [Alias('MaxLength')]
        [ValidateRange(32, 4096)]
        [int]$MaxCharacters = 640,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 4096)]
        [int]$PerLineMaxCharacters = 0,

        [Parameter(Mandatory = $false)]
        [switch]$FilterBlankLines,

        [Parameter(Mandatory = $false)]
        [switch]$HeadTailWhenTruncated,

        [Parameter(Mandatory = $false)]
        [switch]$CollapseWhitespace
    )

    $materializedLines = @(
        $OutputLines |
            ForEach-Object {
                if ($null -eq $_) {
                    return ""
                }

                return [string]$_
            }
    )

    if ($FilterBlankLines) {
        $materializedLines = @($materializedLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($materializedLines.Count -eq 0) {
        return "(no output)"
    }

    if ($CollapseWhitespace) {
        $collapsed = (($materializedLines -join " ") -replace "\s+", " ").Trim()
        if ([string]::IsNullOrWhiteSpace($collapsed)) {
            return "(no output)"
        }

        if ($collapsed.Length -le $MaxCharacters) {
            return $collapsed
        }

        return ($collapsed.Substring(0, $MaxCharacters) + " ...")
    }

    $formatPreviewLine = {
        param([string]$Line)

        if ([string]::IsNullOrWhiteSpace($Line)) {
            return "(blank line)"
        }

        $trimmed = $Line.Trim()
        if ($PerLineMaxCharacters -gt 0 -and $trimmed.Length -gt $PerLineMaxCharacters) {
            return ($trimmed.Substring(0, $PerLineMaxCharacters) + "...")
        }

        return $trimmed
    }

    if ($HeadTailWhenTruncated) {
        if ($materializedLines.Count -le $MaxLines) {
            $previewLines = @($materializedLines | ForEach-Object { & $formatPreviewLine $_ })
            return ($previewLines -join " | ")
        }

        $headCount = [int][math]::Ceiling($MaxLines / 2)
        $tailCount = $MaxLines - $headCount
        if ($tailCount -lt 1) {
            $tailCount = 1
            $headCount = [math]::Max($MaxLines - $tailCount, 1)
        }

        $headPreview = @($materializedLines | Select-Object -First $headCount | ForEach-Object { & $formatPreviewLine $_ })
        $tailPreview = @($materializedLines | Select-Object -Last $tailCount | ForEach-Object { & $formatPreviewLine $_ })
        $omittedCount = [math]::Max($materializedLines.Count - ($headCount + $tailCount), 0)

        return (
            "head: {0} | ... ({1} omitted line(s)) ... | tail: {2}" -f
            ($headPreview -join " | "),
            $omittedCount,
            ($tailPreview -join " | ")
        )
    }

    $preview = @(
        $materializedLines |
            Select-Object -First $MaxLines |
            ForEach-Object { & $formatPreviewLine $_ }
    ) -join ' | '

    if ([string]::IsNullOrWhiteSpace($preview)) {
        return "(blank output)"
    }

    if ($preview.Length -gt $MaxCharacters) {
        return ("{0}...(truncated)" -f $preview.Substring(0, $MaxCharacters))
    }

    return $preview
}

function Test-IsGitIndexLockFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Alias('Output')]
        [object[]]$OutputLines = @()
    )

    $combinedOutput = @(
        $OutputLines |
            ForEach-Object {
                if ($null -eq $_) {
                    return ''
                }

                return [string]$_
            }
    ) -join [Environment]::NewLine

    if ([string]::IsNullOrWhiteSpace($combinedOutput)) {
        return $false
    }

    $indexLockSignaturePattern = '(?is)Unable\s+to\s+create\s+["''][^"'']*index\.lock["'']\s*:\s*File exists|index\.lock[^\r\n]*File exists|Another git process seems to be running'
    return ($combinedOutput -match $indexLockSignaturePattern)
}

function Get-GitIndexLockPathFromOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Alias('Output')]
        [object[]]$OutputLines = @()
    )

    $combinedOutput = @(
        $OutputLines |
            ForEach-Object {
                if ($null -eq $_) {
                    return ''
                }

                return [string]$_
            }
    ) -join [Environment]::NewLine

    if ([string]::IsNullOrWhiteSpace($combinedOutput)) {
        return ''
    }

    $quotedPathMatch = [regex]::Match($combinedOutput, '(?is)Unable\s+to\s+create\s+["''](?<path>[^"'']*index\.lock)["'']\s*:\s*File exists')
    if ($quotedPathMatch.Success) {
        return [string]$quotedPathMatch.Groups['path'].Value
    }

    $unquotedPathMatch = [regex]::Match($combinedOutput, '(?is)Unable\s+to\s+create\s+(?<path>\S*index\.lock)\s*:\s*File exists')
    if ($unquotedPathMatch.Success) {
        return [string]$unquotedPathMatch.Groups['path'].Value
    }

    return ''
}

function Get-GitIndexLockRecoveryConfig {
    [CmdletBinding()]
    param()

    $modeRaw = [string]$env:WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE
    $mode = if ([string]::IsNullOrWhiteSpace($modeRaw)) {
        'safe'
    }
    else {
        $modeRaw.Trim().ToLowerInvariant()
    }

    if ($mode -notin @('safe', 'off')) {
        throw "E_PRECOMMIT_GIT_INDEX_LOCK_CONFIG: WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE must be one of: safe, off. Received '$modeRaw'."
    }

    $staleSecondsRaw = [string]$env:WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS
    $staleSeconds = if ([string]::IsNullOrWhiteSpace($staleSecondsRaw)) {
        15
    }
    else {
        $parsedStaleSeconds = 0
        if (-not [int]::TryParse($staleSecondsRaw, [ref]$parsedStaleSeconds) -or $parsedStaleSeconds -lt 5 -or $parsedStaleSeconds -gt 3600) {
            throw "E_PRECOMMIT_GIT_INDEX_LOCK_CONFIG: WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS must be an integer between 5 and 3600. Received '$staleSecondsRaw'."
        }

        $parsedStaleSeconds
    }

    $allowActiveGitRaw = [string]$env:WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT
    $allowActiveGit = if ([string]::IsNullOrWhiteSpace($allowActiveGitRaw)) {
        $false
    }
    else {
        switch -Regex ($allowActiveGitRaw.Trim().ToLowerInvariant()) {
            '^(1|true|yes|on)$' {
                $true
                break
            }
            '^(0|false|no|off)$' {
                $false
                break
            }
            default {
                throw "E_PRECOMMIT_GIT_INDEX_LOCK_CONFIG: WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT must be a boolean-like value (0/1/true/false/yes/no/on/off). Received '$allowActiveGitRaw'."
            }
        }
    }

    $slowPathRaw = [string]$env:WALLSTOP_GIT_INDEX_LOCK_SLOW_PATH_MS
    $slowPathMilliseconds = if ([string]::IsNullOrWhiteSpace($slowPathRaw)) {
        250
    }
    else {
        $parsedSlowPathMilliseconds = 0
        if (-not [int]::TryParse($slowPathRaw, [ref]$parsedSlowPathMilliseconds) -or $parsedSlowPathMilliseconds -lt 1 -or $parsedSlowPathMilliseconds -gt 60000) {
            throw "E_PRECOMMIT_GIT_INDEX_LOCK_CONFIG: WALLSTOP_GIT_INDEX_LOCK_SLOW_PATH_MS must be an integer between 1 and 60000. Received '$slowPathRaw'."
        }

        $parsedSlowPathMilliseconds
    }

    return [pscustomobject]@{
        Mode                 = $mode
        StaleSeconds         = $staleSeconds
        AllowActiveGit       = $allowActiveGit
        SlowPathMilliseconds = $slowPathMilliseconds
    }
}

function Get-ActiveGitProcessScanState {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$GitDirectory = '',

        [Parameter(Mandatory = $true)]
        [System.StringComparison]$PathComparison
    )

    $result = [pscustomobject]@{
        ActiveGitProcessCount = -1
        ProcessScanDegraded   = $false
    }

    $isGitCommandLineMatch = {
        param([string]$CommandLine)

        if ([string]::IsNullOrWhiteSpace($CommandLine)) {
            return $false
        }

        if ($CommandLine -notmatch '(?i)\bgit(\.exe)?\b|\bpre-commit\b') {
            return $false
        }

        if ($CommandLine.IndexOf($RepositoryRoot, $PathComparison) -ge 0) {
            return $true
        }

        if (-not [string]::IsNullOrWhiteSpace($GitDirectory) -and $CommandLine.IndexOf($GitDirectory, $PathComparison) -ge 0) {
            return $true
        }

        return $false
    }

    try {
        if ([System.IO.Path]::DirectorySeparatorChar -eq '\\') {
            $getCimInstanceCommand = Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue
            if ($null -eq $getCimInstanceCommand) {
                $result.ProcessScanDegraded = $true
                return $result
            }

            $processes = @(& $getCimInstanceCommand -ClassName Win32_Process -ErrorAction Stop)
            $result.ActiveGitProcessCount = @(
                $processes |
                    Where-Object {
                        & $isGitCommandLineMatch -CommandLine ([string]$_.CommandLine)
                    }
            ).Count

            return $result
        }

        $psExecutable = ''
        $psApplication = @(Get-Command -Name 'ps' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($psApplication.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$psApplication[0].Source)) {
            $psExecutable = [string]$psApplication[0].Source
        }
        else {
            foreach ($candidatePath in @('/bin/ps', '/usr/bin/ps')) {
                if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                    $psExecutable = $candidatePath
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($psExecutable)) {
            $result.ProcessScanDegraded = $true
            return $result
        }

        $processLines = @(& $psExecutable -eo command= 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $result.ProcessScanDegraded = $true
            return $result
        }

        $result.ActiveGitProcessCount = @(
            $processLines |
                Where-Object {
                    & $isGitCommandLineMatch -CommandLine ([string]$_)
                }
        ).Count

        return $result
    }
    catch {
        $result.ProcessScanDegraded = $true
        return $result
    }
}

function Invoke-SafeGitIndexLockRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Alias('Output')]
        [object[]]$OutputLines = @(),

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Context = 'git-index-lock-recovery'
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $recoveryConfig = Get-GitIndexLockRecoveryConfig

    $result = [pscustomobject]@{
        Context               = $Context
        Mode                  = [string]$recoveryConfig.Mode
        RecoveryAttempted     = $false
        Recovered             = $false
        SkippedReason         = ''
        ErrorMessage          = ''
        LockPath              = ''
        LockAgeSeconds        = -1
        ActiveGitProcessCount = -1
        ProcessScanDegraded   = $false
        ElapsedMilliseconds   = 0
        SlowPathThresholdMs   = [int]$recoveryConfig.SlowPathMilliseconds
    }

    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\\') {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    $newSkippedResult = {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Reason
        )

        $result.SkippedReason = $Reason
        return $result
    }

    try {
        if ($recoveryConfig.Mode -eq 'off') {
            return & $newSkippedResult -Reason 'mode_off'
        }

        if (-not (Test-IsGitIndexLockFailure -OutputLines $OutputLines)) {
            return & $newSkippedResult -Reason 'not_index_lock_failure'
        }

        $resolvedRepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
        $expectedLockPath = ''
        $expectedLockOutput = @(& $GitExecutable -C $resolvedRepositoryRoot rev-parse --git-path index.lock 2>$null)
        if ($LASTEXITCODE -eq 0 -and $expectedLockOutput.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$expectedLockOutput[0])) {
            $expectedLockCandidate = ([string]$expectedLockOutput[0]).Trim()
            if ([System.IO.Path]::IsPathRooted($expectedLockCandidate)) {
                $expectedLockPath = [System.IO.Path]::GetFullPath($expectedLockCandidate)
            }
            else {
                $expectedLockPath = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRepositoryRoot -ChildPath $expectedLockCandidate))
            }
        }

        $parsedLockPath = Get-GitIndexLockPathFromOutput -OutputLines $OutputLines
        $candidateLockPath = if (-not [string]::IsNullOrWhiteSpace($parsedLockPath)) {
            if ([System.IO.Path]::IsPathRooted($parsedLockPath)) {
                [System.IO.Path]::GetFullPath($parsedLockPath)
            }
            else {
                [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRepositoryRoot -ChildPath $parsedLockPath))
            }
        }
        else {
            $expectedLockPath
        }

        if ([string]::IsNullOrWhiteSpace($candidateLockPath)) {
            return & $newSkippedResult -Reason 'parse_failed'
        }

        if ([string]::IsNullOrWhiteSpace($expectedLockPath)) {
            return & $newSkippedResult -Reason 'expected_lock_path_unavailable'
        }

        if (-not $candidateLockPath.Equals($expectedLockPath, $comparison)) {
            return & $newSkippedResult -Reason 'unsafe_lock_path'
        }

        if (-not [string]::Equals([System.IO.Path]::GetFileName($candidateLockPath), 'index.lock', $comparison)) {
            return & $newSkippedResult -Reason 'unexpected_lock_filename'
        }

        $result.LockPath = $candidateLockPath

        if (-not (Test-Path -LiteralPath $candidateLockPath -PathType Leaf)) {
            return & $newSkippedResult -Reason 'lock_missing'
        }

        $firstLockSample = Get-Item -LiteralPath $candidateLockPath -ErrorAction Stop
        Start-Sleep -Milliseconds 120

        if (-not (Test-Path -LiteralPath $candidateLockPath -PathType Leaf)) {
            return & $newSkippedResult -Reason 'lock_missing'
        }

        $secondLockSample = Get-Item -LiteralPath $candidateLockPath -ErrorAction Stop
        if ($firstLockSample.Length -ne $secondLockSample.Length -or $firstLockSample.LastWriteTimeUtc -ne $secondLockSample.LastWriteTimeUtc) {
            return & $newSkippedResult -Reason 'lock_mutating'
        }

        $lockAgeSeconds = [int]([datetime]::UtcNow - $secondLockSample.LastWriteTimeUtc).TotalSeconds
        $result.LockAgeSeconds = $lockAgeSeconds
        if ($lockAgeSeconds -lt $recoveryConfig.StaleSeconds) {
            return & $newSkippedResult -Reason 'lock_too_new'
        }

        $gitDirectory = ''
        $gitDirectoryOutput = @(& $GitExecutable -C $resolvedRepositoryRoot rev-parse --absolute-git-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitDirectoryOutput.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$gitDirectoryOutput[0])) {
            $gitDirectory = [System.IO.Path]::GetFullPath(([string]$gitDirectoryOutput[0]).Trim())
        }

        $processScanState = Get-ActiveGitProcessScanState -RepositoryRoot $resolvedRepositoryRoot -GitDirectory $gitDirectory -PathComparison $comparison
        $activeGitProcessCount = [int]$processScanState.ActiveGitProcessCount
        $result.ProcessScanDegraded = [bool]$processScanState.ProcessScanDegraded

        $result.ActiveGitProcessCount = $activeGitProcessCount
        if (-not $recoveryConfig.AllowActiveGit -and $result.ProcessScanDegraded) {
            return & $newSkippedResult -Reason 'process_scan_degraded'
        }

        if (-not $recoveryConfig.AllowActiveGit -and $activeGitProcessCount -gt 0) {
            return & $newSkippedResult -Reason 'active_git_process_detected'
        }

        $exclusiveProbe = $null
        try {
            $exclusiveProbe = [System.IO.File]::Open($candidateLockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch {
            return & $newSkippedResult -Reason 'lock_in_use'
        }
        finally {
            if ($null -ne $exclusiveProbe) {
                $exclusiveProbe.Dispose()
            }
        }

        $result.RecoveryAttempted = $true
        $quarantinePath = '{0}.wallstop-recover-{1}' -f $candidateLockPath, ([guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $candidateLockPath -Destination $quarantinePath -ErrorAction Stop
        Remove-Item -LiteralPath $quarantinePath -Force -ErrorAction Stop
        $result.Recovered = $true
        return $result
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
        $result.SkippedReason = 'recovery_failed'
        return $result
    }
    finally {
        $result.ElapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
    }
}
