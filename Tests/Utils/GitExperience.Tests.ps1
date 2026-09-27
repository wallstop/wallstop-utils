Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -NoInvokeMain
    $script:git = (Get-Command -Name 'git' -ErrorAction Stop | Select-Object -First 1).Source
    function Read-Setting([string]$Key) {
        $result = Invoke-GitExperienceProcess $script:git @('config', '--global', '--includes', '--get', $Key) -AllowedExitCodes @(0, 1)
        return $result.Stdout.Trim()
    }
}

Describe 'Git experience installation' {
    BeforeEach {
        $script:savedGlobal = $env:GIT_CONFIG_GLOBAL
        $script:savedNoSystem = $env:GIT_CONFIG_NOSYSTEM
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'personal config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $script:stateDir = Join-Path $TestDrive ('state [special] ' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL, "[user]`n`tname = Test Person`n", [System.Text.UTF8Encoding]::new($false))
    }
    AfterEach {
        $env:GIT_CONFIG_GLOBAL = $script:savedGlobal
        $env:GIT_CONFIG_NOSYSTEM = $script:savedNoSystem
    }
    It 'audits without writing files' {
        $before = [System.IO.File]::ReadAllText($env:GIT_CONFIG_GLOBAL)
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -StateDirectory $script:stateDir | Out-Null
        [System.IO.File]::ReadAllText($env:GIT_CONFIG_GLOBAL) | Should -BeExactly $before
        Test-Path -LiteralPath $script:stateDir | Should -BeFalse
    }
    It 'preflights Git availability before starting work' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'git' }
        { Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir } | Should -Throw '*E_GIT_EXPERIENCE_GIT_NOT_AVAILABLE*'
        Test-Path -LiteralPath $script:stateDir | Should -BeFalse
    }
    It 'rejects versions older than the required feature floor' {
        Mock Invoke-GitExperienceProcess { return [pscustomobject]@{ Stdout = 'git version 2.37.0'; ExitCode = 0; Stderr = '' } }
        { Assert-GitExperienceVersion 'git' '2.38.0' } | Should -Throw '*E_GIT_EXPERIENCE_VERSION*'
    }
    It 'leaves global configuration intact when delta prerequisites fail' {
        $before = Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL
        Mock Get-GitExperienceDeltaChange { throw 'E_GIT_EXPERIENCE_DELTA_MISSING: fixture' }
        { Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir -WithDelta } | Should -Throw '*E_GIT_EXPERIENCE_DELTA_MISSING*'
        Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $script:stateDir 'profile.gitconfig') | Should -BeFalse
    }
    It 'honors WhatIf before creating directories or installing dependencies' {
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir -WithDelta -InstallDependencies -WhatIf | Out-Null
        Test-Path -LiteralPath $script:stateDir | Should -BeFalse
        Read-Setting 'diff.algorithm' | Should -BeNullOrEmpty
    }
    It 'installs once and removes only its own settings' {
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir | Out-Null
        Read-Setting 'diff.algorithm' | Should -Be 'histogram'
        Read-Setting 'rebase.updateRefs' | Should -Be 'true'
        $first = [System.IO.File]::ReadAllText($env:GIT_CONFIG_GLOBAL)
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir | Out-Null
        [System.IO.File]::ReadAllText($env:GIT_CONFIG_GLOBAL) | Should -BeExactly $first
        & $script:git config --global user.name 'Changed Person'
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Remove -StateDirectory $script:stateDir | Out-Null
        Read-Setting 'diff.algorithm' | Should -BeNullOrEmpty
        Read-Setting 'user.name' | Should -Be 'Changed Person'
    }
    It 'preserves legacy non-UTF-8 bytes in global configuration through apply and remove' {
        $original = [byte[]](@([System.Text.Encoding]::ASCII.GetBytes("# legacy ")) + @(0xe9) + @([System.Text.Encoding]::ASCII.GetBytes("`n[user]`n`tname = Test Person`n")))
        [System.IO.File]::WriteAllBytes($env:GIT_CONFIG_GLOBAL, $original)

        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        $installed = [System.IO.File]::ReadAllBytes($env:GIT_CONFIG_GLOBAL)
        ([BitConverter]::ToString($installed)).Contains([BitConverter]::ToString($original)) | Should -BeTrue

        Invoke-GitExperience -Action Remove -StateDirectory $script:stateDir | Out-Null
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($env:GIT_CONFIG_GLOBAL)) | Should -BeExactly ([Convert]::ToBase64String($original))
    }
    It 'keeps an existing UTF-8 BOM at the start of global configuration' {
        $original = "[user]`n`tname = Test Person`n"
        [System.IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL, $original, [System.Text.UTF8Encoding]::new($true))
        $before = Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL

        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        $installed = [System.IO.File]::ReadAllBytes($env:GIT_CONFIG_GLOBAL)
        [BitConverter]::ToString($installed[0..2]) | Should -Be 'EF-BB-BF'
        Read-Setting 'diff.algorithm' | Should -Be 'histogram'

        Invoke-GitExperience -Action Remove -StateDirectory $script:stateDir | Out-Null
        Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL | Should -BeExactly $before
    }
    It 'uses platform-aware path identity for config targets and origins' {
        Test-GitExperienceSamePath '/tmp/Profile' '/tmp/profile' | Should -Be ([bool](Test-IsWindowsPlatform))
        Test-GitExperienceSamePath '/tmp/Profile' '/tmp/Profile' | Should -BeTrue
        Mock Test-IsWindowsPlatform { return $false }
        Test-GitExperienceSamePath '/tmp/Profile' '/tmp/profile' | Should -BeFalse
    }
    It 'selects one executable when a command exists in multiple PATH directories' {
        Mock Test-IsWindowsPlatform { return $false }
        Mock Get-Command {
            @([pscustomobject]@{ Source = '/usr/bin/chmod' }, [pscustomobject]@{ Source = '/bin/chmod' })
        } -ParameterFilter { $Name -eq 'chmod' }
        Mock Invoke-GitExperienceProcess { return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' } } -ParameterFilter { $Executable -eq '/usr/bin/chmod' }

        Set-GitExperiencePrivatePath $env:GIT_CONFIG_GLOBAL
        Should -Invoke Invoke-GitExperienceProcess -Times 1 -Exactly -ParameterFilter { $Executable -eq '/usr/bin/chmod' }
    }
    It 'preserves preferences in included files and can explicitly override them reversibly' {
        $included = Join-Path $TestDrive 'existing preferences'
        [System.IO.File]::WriteAllText($included, "[diff]`n`talgorithm = patience`n", [System.Text.UTF8Encoding]::new($false))
        & $script:git config --global include.path $included
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir | Out-Null
        Read-Setting 'diff.algorithm' | Should -Be 'patience'
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir -ReplaceConflicts | Out-Null
        Read-Setting 'diff.algorithm' | Should -Be 'histogram'
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Remove -StateDirectory $script:stateDir | Out-Null
        Read-Setting 'diff.algorithm' | Should -Be 'patience'
    }
    It 'rejects malformed configuration before installing anything' {
        [System.IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL, '[broken', [System.Text.UTF8Encoding]::new($false))
        { & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir } | Should -Throw '*E_GIT_EXPERIENCE_COMMAND*'
        Test-Path -LiteralPath $script:stateDir | Should -BeFalse
    }
    It 'does not overwrite a manually edited managed profile' {
        & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir | Out-Null
        [System.IO.File]::AppendAllText((Join-Path $script:stateDir 'profile.gitconfig'), "`n# user edit`n")
        { & (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -Action Apply -StateDirectory $script:stateDir } | Should -Throw '*E_GIT_EXPERIENCE_DRIFT*'
    }
    It 'repairs a missing managed profile and can remove its stale include' {
        $before = Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        $profile = Join-Path $script:stateDir 'profile.gitconfig'
        Remove-Item -LiteralPath $profile

        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        Read-Setting 'diff.algorithm' | Should -Be 'histogram'
        Remove-Item -LiteralPath $profile

        Invoke-GitExperience -Action Remove -StateDirectory $script:stateDir | Out-Null
        Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $script:stateDir 'installation.json') | Should -BeFalse
    }
    It 'preserves Unix mode of an existing user config through apply and remove' {
        if (Test-IsWindowsPlatform) { Set-ItResult -Skipped -Because 'Unix file permissions'; return }
        $chmod = Get-Command -Name 'chmod' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $stat = Get-Command -Name 'stat' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $modeOf = {
            param([string]$Path)
            $arguments = if (Test-IsMacOSPlatform) { @('-f', '%Lp', $Path) } else { @('-c', '%a', $Path) }
            return (Invoke-GitExperienceProcess $stat.Source $arguments).Stdout.Trim()
        }
        Invoke-GitExperienceProcess $chmod.Source @('640', $env:GIT_CONFIG_GLOBAL) | Out-Null
        $identityBefore = Get-GitExperienceUnixIdentity $env:GIT_CONFIG_GLOBAL

        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        & $modeOf $env:GIT_CONFIG_GLOBAL | Should -Be '640'
        Get-GitExperienceUnixIdentity $env:GIT_CONFIG_GLOBAL | Should -Be $identityBefore
        $statePath = Join-Path $script:stateDir 'installation.json'
        Invoke-GitExperienceProcess $chmod.Source @('644', $statePath) | Out-Null
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        & $modeOf $statePath | Should -Be '600'
        Invoke-GitExperience -Action Remove -StateDirectory $script:stateDir | Out-Null
        & $modeOf $env:GIT_CONFIG_GLOBAL | Should -Be '640'
        Get-GitExperienceUnixIdentity $env:GIT_CONFIG_GLOBAL | Should -Be $identityBefore
    }
    It 'sets temporary file permissions before writing configuration bytes' {
        Mock Set-GitExperiencePrivatePath {
            if ((Get-Item -LiteralPath $Path).Length -ne 0) { throw 'temporary file contained data before mode was set' }
        }
        $target = Join-Path $TestDrive 'private temp target'
        Write-GitExperienceFile $target (ConvertTo-GitExperienceBytes 'secret setting')
        [System.IO.File]::ReadAllText($target) | Should -Be 'secret setting'
    }
    It 'rejects a destination edit made while preparing a replacement file' {
        $target = Join-Path $TestDrive 'concurrent target'
        [System.IO.File]::WriteAllText($target, 'original')
        $original = Get-GitExperienceFile $target
        Mock Set-GitExperiencePrivatePath {
            [System.IO.File]::WriteAllText($target, 'new user edit')
        }
        { Write-GitExperienceFile $target (ConvertTo-GitExperienceBytes 'installer change') -VerifyOriginal -Original $original } |
            Should -Throw '*E_GIT_EXPERIENCE_CONCURRENT*'
        [System.IO.File]::ReadAllText($target) | Should -Be 'new user edit'
    }
    It 'does not copy a group-readable config through a different temporary group' {
        $target = Join-Path $TestDrive 'group readable target'
        [System.IO.File]::WriteAllText($target, 'private original')
        Mock Test-IsWindowsPlatform { return $false }
        Mock Get-GitExperienceUnixMode { return '640' }
        Mock Get-GitExperienceUnixIdentity {
            if ($Path -eq $target) { return '1000:2000:640' }
            return '1000:3000:640'
        }
        Mock Set-GitExperiencePrivatePath {}
        { Write-GitExperienceFile $target (ConvertTo-GitExperienceBytes 'replacement') -PreserveExistingMode } |
            Should -Throw '*E_GIT_EXPERIENCE_METADATA*'
        [System.IO.File]::ReadAllText($target) | Should -Be 'private original'
    }
    It 'continues with verified Unix ownership when xattr copying is unavailable' {
        $target = Join-Path $TestDrive 'xattr fallback target'
        [System.IO.File]::WriteAllText($target, 'original')
        Mock Test-IsWindowsPlatform { return $false }
        Mock Test-IsMacOSPlatform { return $false }
        Mock Get-GitExperienceUnixMode { return '640' }
        Mock Get-GitExperienceUnixIdentity { return '1000:1000:640' }
        Mock Set-GitExperiencePrivatePath {}
        Mock Get-Command { return [pscustomobject]@{ Source = 'cp' } } -ParameterFilter { $Name -eq 'cp' }
        Mock Invoke-GitExperienceProcess {
            if ($Arguments[0] -eq '--preserve=mode,ownership,xattr') { throw "cp: setting attribute 'user.sample': Operation not supported" }
            return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        } -ParameterFilter { $Executable -eq 'cp' }

        Write-GitExperienceFile $target (ConvertTo-GitExperienceBytes 'replacement') -PreserveExistingMode

        [System.IO.File]::ReadAllText($target) | Should -Be 'replacement'
        Should -Invoke Invoke-GitExperienceProcess -Times 1 -Exactly -ParameterFilter {
            $Executable -eq 'cp' -and $Arguments[0] -eq '--preserve=mode,ownership'
        }
    }
    It 'does not discard xattrs after an unrelated copy failure' {
        $target = Join-Path $TestDrive 'xattr unrelated failure target'
        [System.IO.File]::WriteAllText($target, 'original')
        Mock Test-IsWindowsPlatform { return $false }
        Mock Test-IsMacOSPlatform { return $false }
        Mock Get-GitExperienceUnixMode { return '640' }
        Mock Get-GitExperienceUnixIdentity { return '1000:1000:640' }
        Mock Set-GitExperiencePrivatePath {}
        Mock Get-Command { return [pscustomobject]@{ Source = 'cp' } } -ParameterFilter { $Name -eq 'cp' }
        Mock Invoke-GitExperienceProcess {
            if ($Arguments[0] -eq '--preserve=mode,ownership,xattr') { throw 'cp: source I/O error' }
            return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        } -ParameterFilter { $Executable -eq 'cp' }

        { Write-GitExperienceFile $target (ConvertTo-GitExperienceBytes 'replacement') -PreserveExistingMode } |
            Should -Throw '*source I/O error*'
        [System.IO.File]::ReadAllText($target) | Should -Be 'original'
        Should -Not -Invoke Invoke-GitExperienceProcess -ParameterFilter {
            $Executable -eq 'cp' -and $Arguments[0] -eq '--preserve=mode,ownership'
        }
    }
    It 'uses portable cp flags when GNU preserve options are unavailable' {
        $target = Join-Path $TestDrive 'portable cp target'
        [System.IO.File]::WriteAllText($target, 'original')
        Mock Test-IsWindowsPlatform { return $false }
        Mock Test-IsMacOSPlatform { return $false }
        Mock Get-GitExperienceUnixMode { return '640' }
        Mock Get-GitExperienceUnixIdentity { return '1000:1000:640' }
        Mock Set-GitExperiencePrivatePath {}
        Mock Get-Command { return [pscustomobject]@{ Source = 'cp' } } -ParameterFilter { $Name -eq 'cp' }
        Mock Invoke-GitExperienceProcess {
            if ($Arguments[0] -like '--preserve=*') { throw "cp: unrecognized option '--preserve=mode,ownership,xattr'" }
            return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        } -ParameterFilter { $Executable -eq 'cp' }

        Write-GitExperienceFile $target (ConvertTo-GitExperienceBytes 'replacement') -PreserveExistingMode

        [System.IO.File]::ReadAllText($target) | Should -Be 'replacement'
        Should -Invoke Invoke-GitExperienceProcess -Times 1 -Exactly -ParameterFilter {
            $Executable -eq 'cp' -and $Arguments[0] -eq '-p'
        }
    }
    It 'does not overwrite a managed profile edited during preparation' {
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        $script:profileDuringPreparation = Join-Path $script:stateDir 'profile.gitconfig'
        Mock Get-GitExperienceDeltaChange {
            [System.IO.File]::AppendAllText($script:profileDuringPreparation, "# concurrent user edit`n")
            return $null
        }
        { Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir -WithDelta } | Should -Throw '*E_GIT_EXPERIENCE_CONCURRENT*'
        [System.IO.File]::ReadAllText($script:profileDuringPreparation) | Should -Match 'concurrent user edit'
    }
    It 'rejects a symlinked state directory without changing its target mode' {
        if (Test-IsWindowsPlatform) { Set-ItResult -Skipped -Because 'Unix symlink permissions'; return }
        $actual = Join-Path $TestDrive 'actual state directory'
        [void][System.IO.Directory]::CreateDirectory($actual)
        $linked = Join-Path $TestDrive 'linked state directory'
        New-Item -ItemType SymbolicLink -Path $linked -Target $actual | Out-Null
        $before = Get-GitExperienceUnixMode $actual
        { Invoke-GitExperience -Action Apply -StateDirectory $linked } | Should -Throw '*E_GIT_EXPERIENCE_SYMLINK*'
        Get-GitExperienceUnixMode $actual | Should -Be $before
    }
    It 'restores an absent global config to absence' {
        Remove-Item -LiteralPath $env:GIT_CONFIG_GLOBAL
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        Invoke-GitExperience -Action Remove -StateDirectory $script:stateDir | Out-Null
        Test-Path -LiteralPath $env:GIT_CONFIG_GLOBAL | Should -BeFalse
    }
    It 'rolls back when publication fails midway' {
        $before = Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL
        Mock Write-GitExperienceFile { throw 'injected publication failure' } -ParameterFilter { $Path -eq $env:GIT_CONFIG_GLOBAL }
        { Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir } | Should -Throw '*injected publication failure*'
        Get-GitExperienceFile $env:GIT_CONFIG_GLOBAL | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $script:stateDir 'profile.gitconfig') | Should -BeFalse
        Test-Path -LiteralPath ($env:GIT_CONFIG_GLOBAL + '.lock') | Should -BeFalse
    }
    It 'respects a global config lock without removing it' {
        [System.IO.File]::WriteAllText(($env:GIT_CONFIG_GLOBAL + '.lock'), 'other writer')
        try {
            { Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir } | Should -Throw '*E_GIT_EXPERIENCE_LOCK*'
            [System.IO.File]::ReadAllText(($env:GIT_CONFIG_GLOBAL + '.lock')) | Should -Be 'other writer'
        }
        finally { Remove-Item -LiteralPath ($env:GIT_CONFIG_GLOBAL + '.lock') }
    }
    It 'preserves personal edits through a later reapply and removal' {
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        & $script:git config --global user.name 'Keep Later Edit'
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        Invoke-GitExperience -Action Remove -StateDirectory $script:stateDir | Out-Null
        Read-Setting 'user.name' | Should -Be 'Keep Later Edit'
    }
    It 'places explicit overrides after conflicting sections that follow existing includes' {
        $included = Join-Path $TestDrive 'first include'
        [System.IO.File]::WriteAllText($included, "[user]`n`tname = Included User`n", [System.Text.UTF8Encoding]::new($false))
        & $script:git config --global include.path $included
        & $script:git config --global diff.algorithm patience
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir -ReplaceConflicts | Out-Null
        Read-Setting 'diff.algorithm' | Should -Be 'histogram'
        Invoke-GitExperience -Action Remove -StateDirectory $script:stateDir | Out-Null
        Read-Setting 'diff.algorithm' | Should -Be 'patience'
    }
    It 'selects the lower priority XDG file for defaults when both globals exist' {
        $savedXdg = $env:XDG_CONFIG_HOME
        $globalOverride = $env:GIT_CONFIG_GLOBAL
        try {
            $env:GIT_CONFIG_GLOBAL = $null
            $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
            [void][System.IO.Directory]::CreateDirectory((Join-Path $env:XDG_CONFIG_HOME 'git'))
            $xdgFile = Join-Path $env:XDG_CONFIG_HOME 'git/config'
            [System.IO.File]::WriteAllText($xdgFile, '')
            Resolve-GitExperienceGlobalPath | Should -Be $xdgFile
        }
        finally { $env:XDG_CONFIG_HOME = $savedXdg; $env:GIT_CONFIG_GLOBAL = $globalOverride }
    }
    It 'lets inactive conditional preferences win when used in another repository' {
        $other = Join-Path $TestDrive 'other-repo'
        & $script:git init -q $other
        $included = Join-Path $TestDrive 'conditional config'
        [System.IO.File]::WriteAllText($included, "[diff]`n`talgorithm = patience`n", [System.Text.UTF8Encoding]::new($false))
        $condition = 'includeIf.gitdir:' + ($other -replace '\\', '/') + '/.path'
        & $script:git config --global $condition $included
        Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null
        $result = Invoke-GitExperienceProcess $script:git @('-C', $other, 'config', '--get', 'diff.algorithm')
        $result.Stdout.Trim() | Should -Be 'patience'
        Push-Location -LiteralPath $other
        try { Invoke-GitExperience -Action Apply -StateDirectory $script:stateDir | Out-Null }
        finally { Pop-Location }
        Read-Setting 'diff.algorithm' | Should -Be 'histogram'
    }
}
