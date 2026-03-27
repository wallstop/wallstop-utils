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

function ConvertFrom-JsonSingleObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json,

        [Parameter(Mandatory = $false)]
        [string]$Context = "JSON payload"
    )

    $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    $items = @($parsed)

    if ((Get-SafeCount -InputObject $items) -ne 1) {
        throw "E_MALFORMED_RESPONSE: $Context must be a single JSON object."
    }

    return $items[0]
}
