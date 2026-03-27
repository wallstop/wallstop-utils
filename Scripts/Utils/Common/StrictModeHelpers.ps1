function Get-SafeCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return 0
    }

    return @($InputObject).Count
}

function Assert-IsHashtableLike {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Value) {
        throw "E_TYPE_ERROR: $Name cannot be null."
    }

    if ($Value -isnot [System.Collections.IDictionary]) {
        throw "E_TYPE_ERROR: $Name must be hashtable-like."
    }
}

function Get-SafeJsonPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Json,

        [Parameter(Mandatory = $false)]
        [ValidateRange(20, 500)]
        [int]$MaxLength = 120
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return "<empty>"
    }

    $preview = ($Json -replace "\s+", " ").Trim()
    # Keep diagnostics useful while avoiding token leakage.
    $preview = [regex]::Replace($preview, '(?i)(Authorization\s*:\s*(?:Bearer|token)\s+)[A-Za-z0-9_\-\.]{20,}', '$1<redacted>')
    $preview = [regex]::Replace($preview, '\bghp_[A-Za-z0-9]{36}\b', 'ghp_<redacted>')
    $preview = [regex]::Replace($preview, '\bgithub_pat_[A-Za-z0-9_]{80,}\b', 'github_pat_<redacted>')

    if ($preview.Length -gt $MaxLength) {
        return ($preview.Substring(0, $MaxLength) + "...")
    }

    return $preview
}

function ConvertFrom-JsonSingleObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json,

        [Parameter(Mandatory = $false)]
        [string]$Context = "JSON payload"
    )

    $safePreview = Get-SafeJsonPreview -Json $Json
    $trimmedJson = $Json.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmedJson)) {
        throw "E_MALFORMED_RESPONSE: $Context must be a single JSON object. ParsedType=empty. Preview: $safePreview"
    }

    if (-not ($trimmedJson.StartsWith("{") -and $trimmedJson.EndsWith("}"))) {
        throw "E_MALFORMED_RESPONSE: $Context must be a single JSON object with top-level '{}' notation. Preview: $safePreview"
    }

    try {
        $parsed = $Json | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
    } catch {
        throw "E_MALFORMED_RESPONSE: $Context could not be parsed as JSON. Preview: $safePreview"
    }

    if ($null -eq $parsed) {
        throw "E_MALFORMED_RESPONSE: $Context must be a single JSON object. ParsedType=null. Preview: $safePreview"
    }

    if ($parsed -isnot [System.Collections.IDictionary] -and $parsed -isnot [pscustomobject]) {
        $parsedType = $parsed.GetType().FullName
        throw "E_MALFORMED_RESPONSE: $Context must be a single JSON object, but parsed to unsupported type '$parsedType'. Preview: $safePreview"
    }

    return $parsed
}
