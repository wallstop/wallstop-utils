[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BeautifierModulePath,

    [Parameter(Mandatory = $false)]
    [switch]$NoRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/StrictModeHelpers.ps1"
if (-not (Test-Path -LiteralPath $strictModeHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Strict mode helper file not found at '$strictModeHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $strictModeHelpersPath

function Resolve-BeautifierModulePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfiguredPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        if (-not (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: PowerShell-Beautifier module file not found at '$ConfiguredPath'."
        }

        return $ConfiguredPath
    }

    $availableModule = Get-Module -Name PowerShell-Beautifier -ListAvailable | Select-Object -First 1
    if ($null -eq $availableModule -or [string]::IsNullOrWhiteSpace($availableModule.Path)) {
        throw "E_CONFIG_ERROR: PowerShell-Beautifier module is not available. Install it (for example: Install-Module PowerShell-Beautifier -Scope CurrentUser) or pass -BeautifierModulePath."
    }

    return $availableModule.Path
}

function Invoke-Main {
    [CmdletBinding()]
    param()

    $modulePath = Resolve-BeautifierModulePath -ConfiguredPath $BeautifierModulePath
    Import-Module -Name $modulePath -ErrorAction Stop

    $rootDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
    Push-Location -LiteralPath $rootDirectory

    try {
        # Use provider-side filters and literal root paths to avoid wildcard expansion on directory names.
        $ps1Files = @(
            Get-ChildItem -LiteralPath $rootDirectory -Recurse -File -Filter '*.ps1'
            Get-ChildItem -LiteralPath $rootDirectory -Recurse -File -Filter '*.psm1'
        )
        $ps1FileCount = Get-SafeCount -InputObject $ps1Files

        if ($ps1FileCount -eq 0) {
            Write-Host "No PowerShell script files (.ps1/.psm1) found in the directory: $rootDirectory" -ForegroundColor Yellow
            return
        }

        foreach ($file in $ps1Files) {
            try {
                Write-Host "Beautifying $($file.FullName)..." -ForegroundColor Cyan
                Edit-DTWBeautifyScript $file
                Write-Host "$($file.FullName) has been beautified successfully!" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed to beautify $($file.FullName): $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        Write-Host "Completed beautifying all PowerShell script files." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

if (-not $NoRun.IsPresent -and $MyInvocation.InvocationName -ne ".") {
    Invoke-Main
}
