[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-LeadingTabIndentedLineNumbers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $lines = @($Content -split "`r?`n", -1)
    $lineNumbers = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^(?: )*\t+') {
            $lineNumbers.Add($index + 1) | Out-Null
        }
    }

    return @($lineNumbers)
}

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
    }
    else {
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
    }
    catch {
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
$settingsPath = Join-Path -Path $repoRoot -ChildPath ".psscriptanalyzer.format.psd1"
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
    }
    else {
        Join-Path -Path $repoRoot -ChildPath $inputPath
    }

    if (-not (Test-Path -Path $candidatePath -PathType Leaf)) {
        continue
    }

    $extension = [System.IO.Path]::GetExtension($candidatePath)
    if ($extension -notin @(".ps1", ".psm1", ".psd1")) {
        continue
    }

    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $candidatePath)

    $rawContent = [System.IO.File]::ReadAllText($candidatePath)
    $leadingTabLinesBefore = @(Get-LeadingTabIndentedLineNumbers -Content $rawContent)
    $formattedContent = Invoke-Formatter -ScriptDefinition $rawContent -Settings $settingsPath

    if ([string]::IsNullOrEmpty($formattedContent)) {
        throw "E_FORMATTER_OUTPUT_INVALID: Formatter returned null/empty output for '$relativePath'. Check formatter settings and PSScriptAnalyzer availability."
    }

    $leadingTabLinesAfter = @(Get-LeadingTabIndentedLineNumbers -Content $formattedContent)

    if ($leadingTabLinesBefore.Count -gt 0) {
        Write-Verbose (
            "Formatter tab-normalization diagnostics: file={0}; leadingTabLinesBefore={1}; leadingTabLinesAfter={2}" -f
            $relativePath,
            $leadingTabLinesBefore.Count,
            $leadingTabLinesAfter.Count
        )
    }

    if ($leadingTabLinesAfter.Count -gt 0) {
        $linePreview = ($leadingTabLinesAfter | Select-Object -First 20) -join ', '
        throw (
            "E_FORMATTER_TAB_INDENTATION_REMAINING: Formatter output for '{0}' still contains leading tab indentation at line(s): {1}. Ensure {2} keeps PSUseConsistentIndentation with Kind='space'." -f
            $relativePath,
            $linePreview,
            [System.IO.Path]::GetFileName($settingsPath)
        )
    }

    if ($rawContent -ceq $formattedContent) {
        continue
    }

    [System.IO.File]::WriteAllText($candidatePath, $formattedContent, $utf8NoBom)
    Write-Host "Formatted $relativePath"
    $formattedCount++
}

if ($formattedCount -gt 0) {
    Write-Host "PowerShell formatter updated $formattedCount file(s)."
}
