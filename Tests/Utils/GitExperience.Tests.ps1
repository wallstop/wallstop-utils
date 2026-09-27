Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    . (Join-Path $script:root 'Scripts/Git/Set-GitExperience.ps1') -NoInvokeMain
    $script:git = (Get-Command -Name 'git' -ErrorAction Stop).Source
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
