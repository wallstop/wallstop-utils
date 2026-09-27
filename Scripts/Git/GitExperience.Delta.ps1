Set-StrictMode -Version Latest

function Get-GitExperienceDeltaAudit {
    param([string]$StateDirectory, [string]$LazygitConfigPath)
    foreach ($name in @('delta', 'lazygit')) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue
        [pscustomobject]@{ Key = $name; Recommended = 'Available'; Status = if ($command) { 'Available' } else { 'Missing' }; Effective = if ($command) { $command.Source } else { '' }; Origin = '' }
    }
    if ($null -ne $env:GIT_PAGER) {
        [pscustomobject]@{ Key = 'GIT_PAGER'; Recommended = 'Unset to use configured pager'; Status = 'Environment override'; Effective = $env:GIT_PAGER; Origin = 'process environment' }
    }
    Write-Verbose "Delta helper storage: $StateDirectory; explicit lazygit path: $LazygitConfigPath"
}

function Get-GitExperienceDeltaChange {
    param([string]$StateDirectory, [string]$ConfigPath, $Previous, [switch]$InstallDependencies, [switch]$ReplaceConflicts)
    $lazy = Get-Command -Name 'lazygit' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $lazy) { throw 'E_GIT_EXPERIENCE_LAZYGIT_MISSING: Install lazygit 0.65.1 or newer.' }
    Assert-GitExperienceVersion $lazy.Source '0.65.1' 'version=(\d+\.\d+\.\d+)' | Out-Null
    $delta = Get-Command -Name 'delta' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $delta -and $InstallDependencies) {
        $scoop = Get-Command -Name 'scoop' -ErrorAction SilentlyContinue
        $brew = Get-Command -Name 'brew' -CommandType Application -ErrorAction SilentlyContinue
        if ((Test-IsWindowsPlatform) -and $scoop) {
            $shell = Resolve-PowerShellExecutablePath
            Invoke-GitExperienceProcess $shell @('-NoLogo', '-NoProfile', '-File', $scoop.Source, 'install', 'delta') -TimeoutSeconds 300 | Out-Null
        }
        elseif ($brew) { Invoke-GitExperienceProcess $brew.Source @('install', 'git-delta') -TimeoutSeconds 300 | Out-Null }
        else { throw 'E_GIT_EXPERIENCE_DELTA_MISSING: Install git-delta with your package manager, then rerun. No supported Scoop/Homebrew installation was found.' }
        $delta = Get-Command -Name 'delta' -CommandType Application -ErrorAction SilentlyContinue
    }
    if (-not $delta) { throw 'E_GIT_EXPERIENCE_DELTA_MISSING: Install git-delta (Scoop: delta), or use -InstallDependencies with existing Scoop/Homebrew.' }
    Assert-GitExperienceVersion $delta.Source '0.19.2' | Out-Null
    if ($null -ne $Previous) {
        if ($ConfigPath -and -not (Test-GitExperienceSamePath ([System.IO.Path]::GetFullPath($ConfigPath)) $Previous.Path)) { throw 'E_GIT_EXPERIENCE_CONTEXT: Lazygit target changed; remove the original installation first.' }
        $ConfigPath = $Previous.Path
    }
    if (-not $ConfigPath) {
        if ($env:LG_CONFIG_FILE) {
            if ($env:LG_CONFIG_FILE.Contains(',')) { throw 'E_GIT_EXPERIENCE_LAZYGIT_LAYERS: Specify -LazygitConfigPath for the last file in LG_CONFIG_FILE.' }
            $ConfigPath = $env:LG_CONFIG_FILE
        }
        else {
            $directory = (Invoke-GitExperienceProcess $lazy.Source @('--print-config-dir')).Stdout.Trim()
            $ConfigPath = Join-Path $directory 'config.yml'
        }
    }
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    Get-GitExperienceFile $ConfigPath | Out-Null
    $python = Resolve-GitExperiencePython -StateDirectory $StateDirectory -InstallDependencies:$InstallDependencies
    $change = Invoke-GitExperienceYaml -Python $python -ConfigPath $ConfigPath -Previous $Previous -StateDirectory $StateDirectory -ReplaceConflicts:$ReplaceConflicts
    if (-not $change.State.Managed) { Write-Host 'Preserved existing lazygit renderer. Use -ReplaceConflicts to select delta.' }
    # Retain the isolated interpreter path for removal even when lazygit/delta is later uninstalled.
    $change.State | Add-Member -NotePropertyName Python -NotePropertyValue $python -Force
    return $change
}

function Get-GitExperienceDeltaRemoval {
    param($Previous)
    if (-not $Previous.Managed) {
        $before = Get-GitExperienceFile $Previous.Path
        return [pscustomobject]@{ Path = $Previous.Path; Before = $before; After = $before }
    }
    $directory = Split-Path -Parent (Split-Path -Parent $Previous.Python)
    return Invoke-GitExperienceYaml -Python $Previous.Python -ConfigPath $Previous.Path -Previous $Previous -StateDirectory $directory -Remove
}

function Resolve-GitExperiencePython {
    param([string]$StateDirectory, [switch]$InstallDependencies)
    $venv = Join-Path $StateDirectory 'yaml-venv'
    $python = if (Test-IsWindowsPlatform) { Join-Path $venv 'Scripts/python.exe' } else { Join-Path $venv 'bin/python' }
    $requirements = Join-Path $PSScriptRoot '../../requirements-git-experience.txt'
    $requirement = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $requirements).Path, [System.Text.Encoding]::UTF8).Trim()
    $expectedVersion = $requirement.Split('=')[-1]
    if (Test-Path -LiteralPath $python -PathType Leaf) {
        $probe = Invoke-GitExperienceProcess $python @('-c', 'import importlib.metadata; print(importlib.metadata.version("ruamel.yaml"))') -AllowedExitCodes @(0, 1)
        if ($probe.ExitCode -eq 0 -and $probe.Stdout.Trim() -eq $expectedVersion) { return $python }
    }
    if (-not $InstallDependencies) { throw 'E_GIT_EXPERIENCE_YAML_DEPENDENCY: Use -InstallDependencies to provision the isolated YAML helper.' }
    if (-not (Test-Path -LiteralPath $python)) {
        # Query through the shell once so Windows pyenv .bat shims resolve to the real interpreter.
        $shell = Resolve-PowerShellExecutablePath
        $code = 'foreach ($name in @("python3", "python", "py")) { if (Get-Command $name -ErrorAction SilentlyContinue) { & $name -c ''import sys; assert sys.version_info >= (3,9); print(sys.executable)''; if ($LASTEXITCODE -eq 0) { exit 0 } } }; exit 1'
        $hostPython = (Invoke-GitExperienceProcess $shell @('-NoLogo', '-NoProfile', '-Command', $code)).Stdout.Trim()
        Invoke-GitExperienceProcess $hostPython @('-m', 'venv', $venv) -TimeoutSeconds 120 | Out-Null
    }
    Invoke-GitExperienceProcess $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--only-binary=:all:', '-r', (Resolve-Path -LiteralPath $requirements).Path) -TimeoutSeconds 180 | Out-Null
    return $python
}

function Invoke-GitExperienceYaml {
    param([string]$Python, [string]$ConfigPath, $Previous, [string]$StateDirectory, [switch]$ReplaceConflicts, [switch]$Remove)
    $arguments = @((Join-Path $PSScriptRoot 'lazygit_config.py'), $ConfigPath)
    $previousPath = Join-Path $StateDirectory ('previous-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        if ($null -ne $Previous) {
            Write-GitExperienceFile $previousPath (ConvertTo-GitExperienceBytes ($Previous | ConvertTo-Json -Depth 12))
            $arguments += @('--previous', $previousPath)
        }
        if ($ReplaceConflicts) { $arguments += '--replace' }
        if ($Remove) { $arguments += '--remove' }
        $result = Invoke-GitExperienceProcess $Python $arguments
        return $result.Stdout | ConvertFrom-Json
    }
    finally {
        if (Test-Path -LiteralPath $previousPath) { Remove-Item -LiteralPath $previousPath -Force }
    }
}
