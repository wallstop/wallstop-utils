[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$moduleHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/ModuleHelpers.ps1"
if (-not (Test-Path -Path $moduleHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Module helper file not found at '$moduleHelpersPath'."
}

.$moduleHelpersPath

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-LeadingTabIndentedLineNumbers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $lines = @($Content -split '\r?\n')
    $lineNumbers = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^(?: )*\t+') {
            $lineNumbers.Add($index + 1) | Out-Null
        }
    }

    # Prevent output unrolling so callers always receive a true int[] value.
    Write-Output -NoEnumerate ($lineNumbers.ToArray())
}

function Get-LineNumberPreview {
    param(
        [Parameter(Mandatory = $false)]
        [int[]]$LineNumbers = @(),

        [Parameter(Mandatory = $false)]
        [int]$MaxCount = 20
    )

    if ($null -eq $LineNumbers -or $LineNumbers.Count -eq 0) {
        return "(none)"
    }

    $preview = @($LineNumbers | Select-Object -First $MaxCount)
    if ($LineNumbers.Count -gt $MaxCount) {
        return ("{0} (showing first {1} of {2})" -f ((@($preview) -join ', ')),$preview.Count,$LineNumbers.Count)
    }

    return (@($preview) -join ', ')
}

if ($null -eq $Paths -or @($Paths).Count -eq 0) {
    return
}

$minimumScriptAnalyzerVersion = [version]"1.21.0"
$invokeFormatterCommand = Get-CommandWithOptionalModuleImport -CommandName "Invoke-Formatter" -ModuleName "PSScriptAnalyzer" -MinimumVersion $minimumScriptAnalyzerVersion
if ($null -eq $invokeFormatterCommand) {
    $installedScriptAnalyzerVersions = Get-AvailableModuleVersionsText -ModuleName "PSScriptAnalyzer"
    throw (
        "E_CONFIG_ERROR: Invoke-Formatter from PSScriptAnalyzer {0} or newer is required but unavailable. Installed versions: {1}. Run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules PSScriptAnalyzer' or install manually with 'Install-Module PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -MinimumVersion {0} -Force'." -f
        $minimumScriptAnalyzerVersion,
        $installedScriptAnalyzerVersions
    )
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
    if ($extension -notin @(".ps1",".psm1",".psd1")) {
        continue
    }

    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot,$candidatePath)

    $rawContent = [System.IO.File]::ReadAllText($candidatePath)
    [int[]]$leadingTabLinesBefore = Get-LeadingTabIndentedLineNumbers -Content $rawContent
    $formattedContent = Invoke-Formatter -ScriptDefinition $rawContent -Settings $settingsPath

    if ([string]::IsNullOrEmpty($formattedContent)) {
        throw "E_FORMATTER_OUTPUT_INVALID: Formatter returned null/empty output for '$relativePath'. Check formatter settings and PSScriptAnalyzer availability."
    }

    [int[]]$leadingTabLinesAfter = Get-LeadingTabIndentedLineNumbers -Content $formattedContent

    $leadingBeforePreview = Get-LineNumberPreview -LineNumbers $leadingTabLinesBefore
    $leadingAfterPreview = Get-LineNumberPreview -LineNumbers $leadingTabLinesAfter
    Write-Verbose (
        "Formatter tab-normalization diagnostics: file={0}; leadingTabLinesBeforeCount={1}; leadingTabLinesAfterCount={2}; leadingTabLinesBefore={3}; leadingTabLinesAfter={4}" -f
        $relativePath,
        $leadingTabLinesBefore.Count,
        $leadingTabLinesAfter.Count,
        $leadingBeforePreview,
        $leadingAfterPreview
    )

    if ($leadingTabLinesAfter.Count -gt 0) {
        $linePreview = $leadingAfterPreview
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

    [System.IO.File]::WriteAllText($candidatePath,$formattedContent,$utf8NoBom)
    Write-Host "Formatted $relativePath"
    $formattedCount++
}

if ($formattedCount -gt 0) {
    Write-Host "PowerShell formatter updated $formattedCount file(s)."
}
