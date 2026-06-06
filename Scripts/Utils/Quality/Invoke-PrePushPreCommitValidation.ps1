[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, ValueFromRemainingArguments = $true)]
    [string[]]$TargetFiles = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$validationScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "../Run-PreCommitValidation.ps1"
if (-not (Test-Path -LiteralPath $validationScriptPath -PathType Leaf)) {
    throw "E_PREPUSH_PRECOMMIT_VALIDATION_SCRIPT_NOT_FOUND: Run-PreCommitValidation.ps1 was not found at '$validationScriptPath'."
}

$validationArguments = @{
    IncludePreCommitOwnedChecks = $true
    TargetFiles                  = @($TargetFiles)
}

& $validationScriptPath @validationArguments
