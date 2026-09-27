Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '../Utils/Common/CompatibilityHelpers.ps1')

function Invoke-GitExperienceProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [int]$TimeoutSeconds = 30
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.WorkingDirectory = (Get-Location).Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    Set-PortableProcessArguments -StartInfo $info -ArgumentList $Arguments
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-ProcessTreePortably -Process $process
            throw "E_GIT_EXPERIENCE_TIMEOUT: '$Executable' exceeded ${TimeoutSeconds}s."
        }
        if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) {
            Stop-ProcessTreePortably -Process $process
            throw "E_GIT_EXPERIENCE_CAPTURE_TIMEOUT: '$Executable' output did not close."
        }
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
        if ($AllowedExitCodes -notcontains $result.ExitCode) {
            $detail = $result.Stderr.Trim()
            if ($detail.Length -gt 1500) { $detail = $detail.Substring(0, 1500) }
            throw "E_GIT_EXPERIENCE_COMMAND: '$Executable' exited $($result.ExitCode). $detail"
        }
        return $result
    }
    finally { $process.Dispose() }
}

function Get-GitExperienceFile {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "E_GIT_EXPERIENCE_SYMLINK: Supply the resolved configuration path instead of '$Path'."
        }
        return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }
    if (Test-Path -LiteralPath $Path) { throw "E_GIT_EXPERIENCE_PATH: Expected a file at '$Path'." }
    return $null
}

function Set-GitExperiencePrivatePath {
    param([string]$Path, [switch]$Directory, [string]$Mode)
    if (-not (Test-IsWindowsPlatform)) {
        $mode = if ($Mode) { $Mode } elseif ($Directory) { '700' } else { '600' }
        $chmod = Get-Command -Name 'chmod' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        Invoke-GitExperienceProcess $chmod.Source @($mode, $Path) | Out-Null
    }
}

function Get-GitExperienceUnixMode {
    param([string]$Path)
    $stat = Get-Command -Name 'stat' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $arguments = if (Test-IsMacOSPlatform) { @('-f', '%Lp', $Path) } else { @('-c', '%a', $Path) }
    $mode = (Invoke-GitExperienceProcess $stat.Source $arguments).Stdout.Trim()
    if ($mode -notmatch '^[0-7]{1,4}$') { throw "E_GIT_EXPERIENCE_MODE: Invalid Unix file mode '$mode' for '$Path'." }
    return $mode
}

function Get-GitExperienceUnixIdentity {
    param([string]$Path)
    $stat = Get-Command -Name 'stat' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $arguments = if (Test-IsMacOSPlatform) { @('-f', '%u:%g:%Lp', $Path) } else { @('-c', '%u:%g:%a', $Path) }
    $identity = (Invoke-GitExperienceProcess $stat.Source $arguments).Stdout.Trim()
    if ($identity -notmatch '^\d+:\d+:[0-7]{1,4}$') { throw "E_GIT_EXPERIENCE_METADATA: Invalid Unix identity '$identity' for '$Path'." }
    return $identity
}

function Write-GitExperienceFile {
    param([string]$Path, [AllowNull()][object]$Base64, [switch]$PreserveExistingMode, [switch]$VerifyOriginal, [AllowNull()][object]$Original)
    if ($null -eq $Base64) {
        if ($VerifyOriginal -and (Get-GitExperienceFile $Path) -cne $Original) { throw "E_GIT_EXPERIENCE_CONCURRENT: '$Path' changed during preparation." }
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
        return
    }
    $parent = Split-Path -Parent $Path
    [void][System.IO.Directory]::CreateDirectory($parent)
    $temporary = $Path + '.wallstop-' + [guid]::NewGuid().ToString('N')
    $existingMode = if ($PreserveExistingMode -and -not (Test-IsWindowsPlatform) -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Get-GitExperienceUnixMode $Path } else { '' }
    try {
        $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { Set-GitExperiencePrivatePath $temporary -Mode $existingMode }
        finally { $stream.Dispose() }
        if ($existingMode) {
            $sourceIdentity = (Get-GitExperienceUnixIdentity $Path).Split(':')
            $temporaryIdentity = (Get-GitExperienceUnixIdentity $temporary).Split(':')
            $permissionBits = $existingMode.PadLeft(3, '0')
            $groupCanRead = ([Convert]::ToInt32($permissionBits[$permissionBits.Length - 2].ToString(), 8) -band 4) -ne 0
            $worldCanRead = ([Convert]::ToInt32($permissionBits[$permissionBits.Length - 1].ToString(), 8) -band 4) -ne 0
            if ($groupCanRead -and -not $worldCanRead -and $sourceIdentity[1] -ne $temporaryIdentity[1]) {
                throw "E_GIT_EXPERIENCE_METADATA: Refusing to copy '$Path' through a temporary file owned by a different readable group."
            }
            # Copy original metadata onto the private temporary inode before replacing it.
            $cp = Get-Command -Name 'cp' -CommandType Application -ErrorAction Stop | Select-Object -First 1
            if (Test-IsMacOSPlatform) { Invoke-GitExperienceProcess $cp.Source @('-p', $Path, $temporary) | Out-Null }
            else {
                try { Invoke-GitExperienceProcess $cp.Source @('--preserve=mode,ownership,xattr', $Path, $temporary) | Out-Null }
                catch {
                    $copyFailure = $_.Exception.Message
                    $unsupportedPreserveOption = $copyFailure -match '(?i)(?:unrecognized|unknown|invalid|unsupported) (?:long )?option[^\r\n]*preserve'
                    $unsupportedXattr = $copyFailure -match '(?i)(?:xattr|attribute)[^\r\n]*(?:Operation not supported|ENOTSUP|EOPNOTSUPP)'
                    if (-not $unsupportedPreserveOption -and -not $unsupportedXattr) { throw }
                    Write-Warning "W_GIT_EXPERIENCE_XATTR_UNAVAILABLE: Extended attributes could not be copied for '$Path'; preserving owner, group, and mode."
                    $fallbackArguments = if ($unsupportedPreserveOption) { @('-p', $Path, $temporary) } else { @('--preserve=mode,ownership', $Path, $temporary) }
                    Invoke-GitExperienceProcess $cp.Source $fallbackArguments | Out-Null
                }
            }
            if ((Get-GitExperienceUnixIdentity $Path) -cne (Get-GitExperienceUnixIdentity $temporary)) {
                throw "E_GIT_EXPERIENCE_METADATA: Could not preserve Unix owner, group, and mode for '$Path'."
            }
        }
        $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::Truncate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [Convert]::FromBase64String($Base64)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
        if ($existingMode -and (Get-GitExperienceUnixIdentity $Path) -cne (Get-GitExperienceUnixIdentity $temporary)) {
            throw "E_GIT_EXPERIENCE_METADATA: Unix owner, group, or mode changed while writing '$Path'."
        }
        if ($VerifyOriginal -and (Get-GitExperienceFile $Path) -cne $Original) { throw "E_GIT_EXPERIENCE_CONCURRENT: '$Path' changed during preparation." }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
        }
        else { [System.IO.File]::Move($temporary, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function ConvertTo-GitExperienceBytes {
    param([AllowEmptyString()][string]$Text)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Test-GitExperienceSamePath {
    param([string]$Left, [string]$Right)
    $comparison = if (Test-IsWindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    return [string]::Equals($Left, $Right, $comparison)
}

function Resolve-GitExperienceGlobalPath {
    param([switch]$OverridePreferences)
    if ($env:GIT_CONFIG_GLOBAL) { return [System.IO.Path]::GetFullPath($env:GIT_CONFIG_GLOBAL) }
    $classic = Join-Path $HOME '.gitconfig'
    $xdg = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    $xdgFile = Join-Path $xdg 'git/config'
    if ((Test-Path -LiteralPath $xdgFile) -and -not ($OverridePreferences -and (Test-Path -LiteralPath $classic))) { return $xdgFile }
    return $classic
}

function Get-GitExperienceValues {
    param([string]$GitPath, [string]$Key, [switch]$Global)
    $arguments = @('config', '--includes', '--null', '--show-origin')
    if ($Global) { $arguments += '--global' }
    $result = Invoke-GitExperienceProcess $GitPath ($arguments + @('--get-all', $Key)) -AllowedExitCodes @(0, 1)
    $parts = $result.Stdout.Split([char]0)
    for ($index = 0; $index + 1 -lt $parts.Length; $index += 2) {
        [pscustomobject]@{ Origin = $parts[$index]; Value = $parts[$index + 1] }
    }
}

function Assert-GitExperienceVersion {
    param([string]$Executable, [string]$Minimum, [string]$Pattern = '(\d+\.\d+\.\d+)')
    $result = Invoke-GitExperienceProcess $Executable @('--version')
    if ($result.Stdout -notmatch $Pattern -or [version]$Matches[1] -lt [version]$Minimum) {
        throw "E_GIT_EXPERIENCE_VERSION: '$Executable' requires version $Minimum or newer."
    }
    return $result.Stdout.Trim()
}
