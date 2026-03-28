[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Add-ModulePathCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModulePath
    )

    if ([string]::IsNullOrWhiteSpace($ModulePath) -or -not (Test-Path -Path $ModulePath -PathType Container)) {
        return
    }

    $separator = [System.IO.Path]::PathSeparator
    $currentEntries = @($env:PSModulePath -split [regex]::Escape([string]$separator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($currentEntries -contains $ModulePath) {
        return
    }

    $env:PSModulePath = if ([string]::IsNullOrWhiteSpace($env:PSModulePath)) {
        $ModulePath
    } else {
        "$ModulePath$separator$env:PSModulePath"
    }
}

function Ensure-PortableUserModulePaths {
    $userHome = [Environment]::GetFolderPath("UserProfile")
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        return
    }

    Add-ModulePathCandidate -ModulePath (Join-Path -Path $userHome -ChildPath ".local/share/powershell/Modules")

    $snapCodeRoot = Join-Path -Path $userHome -ChildPath "snap/code"
    if (Test-Path -Path $snapCodeRoot -PathType Container) {
        $snapCodeProfiles = Get-ChildItem -Path $snapCodeRoot -Directory -ErrorAction SilentlyContinue
        foreach ($profile in @($snapCodeProfiles)) {
            Add-ModulePathCandidate -ModulePath (Join-Path -Path $profile.FullName -ChildPath ".local/share/powershell/Modules")
        }
    }
}

function Get-CommandWithOptionalModuleImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $true)]
        [version]$MinimumVersion
    )

    Ensure-PortableUserModulePaths
    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command
    }

    try {
        Import-Module -Name $ModuleName -MinimumVersion $MinimumVersion -ErrorAction Stop | Out-Null
    } catch {
        return $null
    }

    return (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)
}

if ($null -eq $Paths -or @($Paths).Count -eq 0) {
    return
}

$invokeFormatterCommand = Get-CommandWithOptionalModuleImport -CommandName "Invoke-Formatter" -ModuleName "PSScriptAnalyzer" -MinimumVersion ([version]"1.21.0")
if ($null -eq $invokeFormatterCommand) {
    throw "E_CONFIG_ERROR: Invoke-Formatter is not available. Install PSScriptAnalyzer (Install-Module PSScriptAnalyzer -Scope CurrentUser -MinimumVersion 1.21.0)."
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../../..")).Path
$settingsPath = Join-Path -Path $repoRoot -ChildPath ".psscriptanalyzer.psd1"
if (-not (Test-Path -Path $settingsPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: ScriptAnalyzer settings file not found at '$settingsPath'."
}

$formattedCount = 0
foreach ($inputPath in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        continue
    }

    $candidatePath = if ([System.IO.Path]::IsPathRooted($inputPath)) {
        $inputPath
    } else {
        Join-Path -Path $repoRoot -ChildPath $inputPath
    }

    if (-not (Test-Path -Path $candidatePath -PathType Leaf)) {
        continue
    }

    $extension = [System.IO.Path]::GetExtension($candidatePath)
    if ($extension -notin @(".ps1", ".psm1", ".psd1")) {
        continue
    }

    $rawContent = [System.IO.File]::ReadAllText($candidatePath)
    $formattedContent = Invoke-Formatter -ScriptDefinition $rawContent -Settings $settingsPath

    if ($null -eq $formattedContent -or $rawContent -ceq $formattedContent) {
        continue
    }

    [System.IO.File]::WriteAllText($candidatePath, $formattedContent, $utf8NoBom)
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $candidatePath)
    Write-Host "Formatted $relativePath"
    $formattedCount++
}

if ($formattedCount -gt 0) {
    Write-Host "PowerShell formatter updated $formattedCount file(s)."
}
