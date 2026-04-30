function Get-WrapperContractEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContextFilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$DefaultFallback = @()
    )

    $normalizedFallback = @(
        $DefaultFallback |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { ($_ -replace '[\\/]+','/').Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object { $_.ToUpperInvariant() } -Unique
    )

    if (-not (Test-Path -LiteralPath $ContextFilePath -PathType Leaf)) {
        return $normalizedFallback
    }

    $entries = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $inSection = $false

    foreach ($line in [System.IO.File]::ReadLines($ContextFilePath,[System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s{0,3}##\s+Wrapper Contract\s*$') {
            $inSection = $true
            continue
        }

        if ($inSection -and $line -match '^\s{0,3}##\s') {
            break
        }

        if ($inSection -and $line -match '^\s*-\s+`([^`]+)`') {
            $entry = ($Matches[1]).Trim()
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }

            $portableEntry = $entry -replace '[\\/]+','/'
            [void]$entries.Add($portableEntry)
        }
    }

    if ($entries.Count -gt 0) {
        return @($entries | Sort-Object { $_.ToUpperInvariant() })
    }

    return $normalizedFallback
}
