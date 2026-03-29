[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TestPath,

    [Parameter(Mandatory = $false)]
    [switch]$EnableCoverage,

    [Parameter(Mandatory = $false)]
    [string]$CoveragePath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [int]$MinimumCoveragePercent = 0,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DiagnosticsPrefix = "Pester"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$minimumPesterVersion = [version]"5.5.0"

if (-not (Test-Path -Path $TestPath -PathType Container)) {
    throw "E_CI_PESTER_TEST_PATH_MISSING: test path directory not found at '$TestPath'."
}

if ($EnableCoverage) {
    if ([string]::IsNullOrWhiteSpace($CoveragePath)) {
        throw "E_CI_PESTER_COVERAGE_PATH_MISSING: -CoveragePath is required when -EnableCoverage is set."
    }
    if (-not (Test-Path -Path $CoveragePath -PathType Leaf)) {
        throw "E_CI_PESTER_COVERAGE_TARGET_MISSING: coverage target not found at '$CoveragePath'."
    }
}

Import-Module Pester -MinimumVersion $minimumPesterVersion -ErrorAction Stop
$pesterModule = Get-Module Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pesterModule) {
    throw "E_CI_PESTER_IMPORT_FAILED: Pester module was not loaded after Import-Module."
}

$pesterVersion = $null
try {
    $pesterVersion = [version]::Parse([string]$pesterModule.Version)
}
catch {
    throw "E_CI_PESTER_VERSION_PARSE_FAILED: Unable to parse loaded Pester version '$($pesterModule.Version)'."
}

if ($pesterVersion -lt $minimumPesterVersion) {
    throw "E_CI_PESTER_VERSION_TOO_OLD: Loaded Pester version $pesterVersion is below minimum $minimumPesterVersion."
}

$newPesterConfigurationCommand = Get-Command -Name "New-PesterConfiguration" -ErrorAction SilentlyContinue
Write-Host "$DiagnosticsPrefix diagnostics: version=$pesterVersion"
Write-Host "$DiagnosticsPrefix diagnostics: modulePath=$($pesterModule.Path)"
Write-Host "$DiagnosticsPrefix diagnostics: hasNewPesterConfiguration=$($null -ne $newPesterConfigurationCommand)"

if ($null -eq $newPesterConfigurationCommand) {
    throw "E_CI_PESTER_CONFIG_COMMAND_MISSING: New-PesterConfiguration is unavailable in this runner session."
}

$configuration = New-PesterConfiguration
if ($null -eq $configuration) {
    throw "E_CI_PESTER_CONFIG_CREATION_FAILED: New-PesterConfiguration returned null."
}

$configuration.Run.Path = @($TestPath)
$configuration.Run.PassThru = $true

if ($EnableCoverage) {
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = @($CoveragePath)
}

$result = Invoke-Pester -Configuration $configuration -ErrorAction Stop
if ($null -eq $result) {
    throw "E_CI_PESTER_RESULT_MISSING: Invoke-Pester returned no result object."
}

Write-Host "$DiagnosticsPrefix diagnostics: passed=$($result.PassedCount) failed=$($result.FailedCount)"
if ($result.FailedCount -gt 0) {
    throw "E_CI_PESTER_TESTS_FAILED: Pester failed with $($result.FailedCount) failed test(s)."
}

if (-not $EnableCoverage) {
    return
}

if ($null -eq $result.CodeCoverage) {
    throw "E_CI_PESTER_COVERAGE_MISSING: CodeCoverage object is null."
}

$coverageProperties = @($result.CodeCoverage.PSObject.Properties | ForEach-Object { $_.Name })
Write-Host "$DiagnosticsPrefix diagnostics: coverageProperties=$($coverageProperties -join ', ')"
if ($coverageProperties.Count -eq 0) {
    throw "E_CI_PESTER_COVERAGE_PROPS_EMPTY: CodeCoverage object exposed no properties."
}

if ($null -eq $result.CodeCoverage.CoveragePercent) {
    throw "E_CI_PESTER_COVERAGE_PERCENT_MISSING: CodeCoverage.CoveragePercent is null."
}

$coveragePercentRaw = [string]$result.CodeCoverage.CoveragePercent
$coverage = 0.0
$parseSucceeded = [double]::TryParse(
    $coveragePercentRaw,
    [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$coverage
)
if (-not $parseSucceeded) {
    $parseSucceeded = [double]::TryParse($coveragePercentRaw, [ref]$coverage)
}
if (-not $parseSucceeded) {
    throw "E_CI_PESTER_COVERAGE_PARSE_FAILED: CodeCoverage.CoveragePercent value '$coveragePercentRaw' is not a valid number."
}

Write-Host "$DiagnosticsPrefix diagnostics: coveragePercent=$coverage minimum=$MinimumCoveragePercent"
if ($coverage -lt [double]$MinimumCoveragePercent) {
    throw "E_CI_PESTER_COVERAGE_GATE_FAILED: Coverage gate failed because $coverage% is below $MinimumCoveragePercent%."
}
