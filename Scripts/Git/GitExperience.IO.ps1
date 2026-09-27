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
    param([string]$Path, [switch]$Directory)
    if (-not (Test-IsWindowsPlatform)) {
        $mode = if ($Directory) { '700' } else { '600' }
        $chmod = Get-Command -Name 'chmod' -CommandType Application -ErrorAction Stop
        Invoke-GitExperienceProcess $chmod.Source @($mode, $Path) | Out-Null
    }
}

function Write-GitExperienceFile {
    param([string]$Path, [AllowNull()][object]$Base64)
    if ($null -eq $Base64) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
        return
    }
    $parent = Split-Path -Parent $Path
    [void][System.IO.Directory]::CreateDirectory($parent)
    $temporary = $Path + '.wallstop-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllBytes($temporary, [Convert]::FromBase64String($Base64))
        Set-GitExperiencePrivatePath $temporary
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
