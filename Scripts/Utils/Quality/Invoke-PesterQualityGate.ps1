[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TestPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
    [string]$OutputVerbosity = "None",

    [Parameter(Mandatory = $false)]
    [switch]$EnableCoverage,

    [Parameter(Mandatory = $false)]
    [string]$CoveragePath,

    [Parameter(Mandatory = $false)]
    [string]$TestResultOutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [int]$MinimumCoveragePercent = 0,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DiagnosticsPrefix = "Pester"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$moduleHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/ModuleHelpers.ps1"
if (-not (Test-Path -Path $moduleHelpersPath -PathType Leaf)) {
    throw "E_CI_PESTER_HELPER_MISSING: module helper file not found at '$moduleHelpersPath'."
}

.$moduleHelpersPath

function Get-FailedTestSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 50)]
        [int]$MaxCount = 20
    )

    if ($null -eq $Result) {
        return "(no result object)"
    }

    if (-not ($Result.PSObject.Properties.Name -contains "Failed")) {
        return "(failed test details unavailable)"
    }

    $failedTestResult = $Result.Failed
    if ($null -eq $failedTestResult) {
        return "(failed test details unavailable)"
    }

    $failedTests = @($failedTestResult)
    if ($failedTests.Count -eq 0) {
        return "(failed test details unavailable)"
    }

    $preview = @($failedTests | Select-Object -First $MaxCount | ForEach-Object {
            $testName = if ($_.PSObject.Properties.Name -contains "ExpandedPath" -and -not [string]::IsNullOrWhiteSpace([string]$_.ExpandedPath)) {
                [string]$_.ExpandedPath
            }
            elseif ($_.PSObject.Properties.Name -contains "Name" -and -not [string]::IsNullOrWhiteSpace([string]$_.Name)) {
                [string]$_.Name
            }
            else {
                "(unknown test)"
            }

            $errorRecord = if ($_.PSObject.Properties.Name -contains "ErrorRecord") { $_.ErrorRecord } else { $null }
            $errorMessage = if ($null -ne $errorRecord -and $null -ne $errorRecord.Exception -and -not [string]::IsNullOrWhiteSpace([string]$errorRecord.Exception.Message)) {
                [string]$errorRecord.Exception.Message
            }
            elseif ($null -ne $errorRecord -and -not [string]::IsNullOrWhiteSpace([string]$errorRecord)) {
                [string]$errorRecord
            }
            else {
                "(no error message)"
            }

            "{0}: {1}" -f $testName, $errorMessage
        })

    if ($failedTests.Count -gt $MaxCount) {
        $remaining = $failedTests.Count - $MaxCount
        $preview += "... ($remaining more failed test(s))"
    }

    return ($preview -join " | ")
}

function Get-FailedContainerSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 50)]
        [int]$MaxCount = 20
    )

    if ($null -eq $Result) {
        return "(no result object)"
    }

    if (-not ($Result.PSObject.Properties.Name -contains "FailedContainers")) {
        return "(failed container details unavailable)"
    }

    $failedContainerResult = $Result.FailedContainers
    if ($null -eq $failedContainerResult) {
        return "(failed container details unavailable)"
    }

    $failedContainers = @($failedContainerResult)
    if ($failedContainers.Count -eq 0) {
        return "(failed container details unavailable)"
    }

    $preview = @($failedContainers | Select-Object -First $MaxCount | ForEach-Object {
            $containerPath = "(unknown container)"
            if ($_.PSObject.Properties.Name -contains "Item" -and $null -ne $_.Item) {
                $itemPathProperty = $_.Item.PSObject.Properties["Path"]
                if ($null -ne $itemPathProperty -and -not [string]::IsNullOrWhiteSpace([string]$_.Item.Path)) {
                    $containerPath = [string]$_.Item.Path
                }
            }

            if ($containerPath -eq "(unknown container)" -and $_.PSObject.Properties.Name -contains "Path" -and -not [string]::IsNullOrWhiteSpace([string]$_.Path)) {
                $containerPath = [string]$_.Path
            }

            $errorRecord = if ($_.PSObject.Properties.Name -contains "ErrorRecord") { $_.ErrorRecord } else { $null }
            $errorMessage = if ($null -ne $errorRecord -and $null -ne $errorRecord.Exception -and -not [string]::IsNullOrWhiteSpace([string]$errorRecord.Exception.Message)) {
                [string]$errorRecord.Exception.Message
            }
            elseif ($null -ne $errorRecord -and -not [string]::IsNullOrWhiteSpace([string]$errorRecord)) {
                [string]$errorRecord
            }
            else {
                "(no error message)"
            }

            $normalizedErrorMessage = [regex]::Replace($errorMessage, '\s+', ' ').Trim()
            if ($normalizedErrorMessage.Length -gt 240) {
                $normalizedErrorMessage = "{0}..." -f $normalizedErrorMessage.Substring(0, 240)
            }

            "{0}: {1}" -f $containerPath, $normalizedErrorMessage
        })

    if ($failedContainers.Count -gt $MaxCount) {
        $remaining = $failedContainers.Count - $MaxCount
        $preview += "... ($remaining more failed container(s))"
    }

    return ($preview -join " | ")
}

function Get-PesterResultCount {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PropertyName
    )

    if ($null -eq $Result) {
        return 0
    }

    if (-not ($Result.PSObject.Properties.Name -contains $PropertyName)) {
        return 0
    }

    $rawValue = $Result.$PropertyName
    if ($null -eq $rawValue) {
        return 0
    }

    $intValue = 0
    if ([int]::TryParse([string]$rawValue, [ref]$intValue)) {
        return $intValue
    }

    return 0
}

$minimumPesterVersion = [version]"5.5.0"

if (-not (Test-Path -Path $TestPath)) {
    throw "E_CI_PESTER_TEST_PATH_MISSING: test path was not found at '$TestPath'."
}

if ($EnableCoverage) {
    if ([string]::IsNullOrWhiteSpace($CoveragePath)) {
        throw "E_CI_PESTER_COVERAGE_PATH_MISSING: -CoveragePath is required when -EnableCoverage is set."
    }
    if (-not (Test-Path -Path $CoveragePath -PathType Leaf)) {
        throw "E_CI_PESTER_COVERAGE_TARGET_MISSING: coverage target not found at '$CoveragePath'."
    }
}

$invokePesterCommand = Get-CommandWithOptionalModuleImport -CommandName "Invoke-Pester" -ModuleName "Pester" -MinimumVersion $minimumPesterVersion
if ($null -eq $invokePesterCommand) {
    $installedPesterVersions = Get-AvailableModuleVersionsText -ModuleName "Pester"
    $modulePathDiagnostics = Get-ModulePathDiagnosticsText
    throw (
        "E_CI_PESTER_VERSION_TOO_OLD: Invoke-Pester from Pester {0} or newer is required but unavailable. Installed versions: {1}. Module path diagnostics: {2}. Run 'pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1 -Modules Pester' or install manually with 'Install-Module Pester -Scope CurrentUser -MinimumVersion {0} -Force'." -f
        $minimumPesterVersion,
        $installedPesterVersions,
        $modulePathDiagnostics
    )
}

$pesterModule = Get-Module Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pesterModule) {
    throw "E_CI_PESTER_IMPORT_FAILED: Pester module was not loaded after helper-based module resolution."
}

$pesterVersion = $null
try {
    $pesterVersion = [version]::Parse([string]$pesterModule.version)
}
catch {
    throw "E_CI_PESTER_VERSION_PARSE_FAILED: Unable to parse loaded Pester version '$($pesterModule.Version)'."
}

if ($pesterVersion -lt $minimumPesterVersion) {
    throw "E_CI_PESTER_VERSION_TOO_OLD: Loaded Pester version $pesterVersion is below minimum $minimumPesterVersion."
}

$newPesterConfigurationCommand = Get-Command -Name "New-PesterConfiguration" -Module "Pester" -ErrorAction SilentlyContinue
Write-Verbose "$DiagnosticsPrefix diagnostics: version=$pesterVersion"
Write-Verbose "$DiagnosticsPrefix diagnostics: modulePath=$($pesterModule.Path)"
Write-Verbose "$DiagnosticsPrefix diagnostics: hasNewPesterConfiguration=$($null -ne $newPesterConfigurationCommand)"

if ($null -eq $newPesterConfigurationCommand) {
    throw "E_CI_PESTER_CONFIG_COMMAND_MISSING: New-PesterConfiguration is unavailable in this runner session."
}

$configuration = New-PesterConfiguration
if ($null -eq $configuration) {
    throw "E_CI_PESTER_CONFIG_CREATION_FAILED: New-PesterConfiguration returned null."
}

$configuration.Run.Path = @($TestPath)
$configuration.Run.PassThru = $true

try {
    $configuration.Output.Verbosity = $OutputVerbosity
}
catch {
    throw "E_CI_PESTER_OUTPUT_VERBOSITY_INVALID: Unable to set Output.Verbosity to '$OutputVerbosity'."
}

$renderModeProperty = $configuration.Output.PSObject.Properties["RenderMode"]
if ($null -ne $renderModeProperty) {
    try {
        $configuration.Output.RenderMode = "PlainText"
    }
    catch {
        Write-Verbose "$DiagnosticsPrefix diagnostics: renderModeSetFailed=$($_.Exception.Message)"
    }
}

if ($EnableCoverage) {
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = @($CoveragePath)
}

if (-not [string]::IsNullOrWhiteSpace($TestResultOutputPath)) {
    $testResultDirectory = [System.IO.Path]::GetDirectoryName($TestResultOutputPath)
    if (-not [string]::IsNullOrWhiteSpace($testResultDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($testResultDirectory)
    }

    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $TestResultOutputPath
}

$result = Invoke-Pester -Configuration $configuration -ErrorAction Stop
if ($null -eq $result) {
    throw "E_CI_PESTER_RESULT_MISSING: Invoke-Pester returned no result object."
}

Write-Verbose "$DiagnosticsPrefix diagnostics: passed=$($result.PassedCount) failed=$($result.FailedCount)"
$totalCount = if ($result.PSObject.Properties.Name -contains "TotalCount") {
    Get-PesterResultCount -Result $result -PropertyName "TotalCount"
}
else {
    (Get-PesterResultCount -Result $result -PropertyName "PassedCount") +
    (Get-PesterResultCount -Result $result -PropertyName "FailedCount") +
    (Get-PesterResultCount -Result $result -PropertyName "SkippedCount") +
    (Get-PesterResultCount -Result $result -PropertyName "InconclusiveCount") +
    (Get-PesterResultCount -Result $result -PropertyName "NotRunCount")
}
$failedContainersCount = if ($result.PSObject.Properties.Name -contains "FailedContainersCount") {
    Get-PesterResultCount -Result $result -PropertyName "FailedContainersCount"
}
else {
    if (-not ($result.PSObject.Properties.Name -contains "FailedContainers") -or $null -eq $result.FailedContainers) {
        0
    }
    else {
        @($result.FailedContainers).Count
    }
}
$resultState = if ($result.PSObject.Properties.Name -contains "Result") { [string]$result.Result } else { "(unknown)" }
Write-Verbose "$DiagnosticsPrefix diagnostics: total=$totalCount failedContainers=$failedContainersCount result=$resultState"
Write-Verbose "$DiagnosticsPrefix diagnostics: outputVerbosity=$($configuration.Output.Verbosity)"
if ($null -ne $renderModeProperty) {
    Write-Verbose "$DiagnosticsPrefix diagnostics: renderMode=$($configuration.Output.RenderMode)"
}
if ($failedContainersCount -gt 0) {
    $failedContainerSummary = Get-FailedContainerSummary -Result $result
    throw "E_CI_PESTER_DISCOVERY_FAILED: Pester reported $failedContainersCount failed test container(s) for '$TestPath'. Failed containers: $failedContainerSummary"
}

if ($totalCount -eq 0) {
    throw "E_CI_PESTER_NO_TESTS_DISCOVERED: Pester discovered zero tests for '$TestPath'."
}

if ((Get-PesterResultCount -Result $result -PropertyName "FailedCount") -gt 0) {
    $failedSummary = Get-FailedTestSummary -Result $result
    $testResultArtifactDiagnostic = if ([string]::IsNullOrWhiteSpace($TestResultOutputPath)) {
        ""
    }
    else {
        " TestResultOutputPath='$TestResultOutputPath'."
    }
    throw "E_CI_PESTER_TESTS_FAILED: Pester failed with $($result.FailedCount) failed test(s). Failed tests: $failedSummary.$testResultArtifactDiagnostic"
}

if (-not $EnableCoverage) {
    return
}

if ($null -eq $result.CodeCoverage) {
    throw "E_CI_PESTER_COVERAGE_MISSING: CodeCoverage object is null."
}

$coverageProperties = @($result.CodeCoverage.PSObject.Properties | ForEach-Object { $_.Name })
Write-Verbose "$DiagnosticsPrefix diagnostics: coverageProperties=$($coverageProperties -join ', ')"
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

Write-Verbose "$DiagnosticsPrefix diagnostics: coveragePercent=$coverage minimum=$MinimumCoveragePercent"
if ($coverage -lt [double]$MinimumCoveragePercent) {
    throw "E_CI_PESTER_COVERAGE_GATE_FAILED: Coverage gate failed because $coverage% is below $MinimumCoveragePercent%."
}
