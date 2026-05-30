# CompatibilityHelpers.ps1
#
# Single source of truth for Windows PowerShell 5.1 (Desktop edition / .NET Framework)
# <-> PowerShell 7+ (Core edition / .NET 5+) portability shims.
#
# Why this file exists:
#   Scripts in this repository must run on BOTH Windows PowerShell 5.1 and PowerShell 7+.
#   Several constructs the codebase relies on behave differently or are absent on 5.1:
#     - $IsWindows / $IsMacOS / $IsLinux automatic variables do not exist on Desktop
#       edition; under `Set-StrictMode -Version Latest` a bare reference THROWS
#       ("the variable cannot be retrieved because it has not been set").
#     - [System.IO.Path]::GetRelativePath(string,string) does not exist in .NET Framework.
#     - `ConvertTo-Json -AsArray` and `ConvertFrom-Json -Depth/-NoEnumerate` are 6+ only.
#   Consumers must dot-source this file and call these helpers instead of using the
#   non-portable construct directly. Re-divergence is policy-tested in
#   Tests/Utils/CompatibilityConventions.Tests.ps1 and the shims are unit-tested in
#   Tests/Utils/CompatibilityHelpers.Tests.ps1.
#
# This file must itself remain 5.1-safe: it must not reference $IsWindows/$IsMacOS/$IsLinux
# directly, must not use 7+-only syntax (ternary, ??, &&/||), and must not call 7+-only APIs.

function Test-IsDesktopEdition {
    # Windows PowerShell 5.1 reports PSEdition 'Desktop'; PowerShell 6+ reports 'Core'.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return ($PSVersionTable.PSEdition -eq 'Desktop')
}

function Get-PortableAutomaticBool {
    # Reads an OS automatic variable ($IsWindows/$IsMacOS/$IsLinux) without tripping
    # StrictMode on Desktop edition, where those variables are undefined.
    # Get-Variable is a cmdlet probe, so SilentlyContinue avoids the strict-mode throw
    # that a bare `$IsWindows` reference would raise.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $variable = Get-Variable -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $false
    }

    return [bool]$variable.Value
}

function Test-IsWindowsPlatform {
    # Portable replacement for $IsWindows that is safe on Windows PowerShell 5.1.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Desktop edition (Windows PowerShell) only ever runs on Windows.
    if (Test-IsDesktopEdition) {
        return $true
    }

    return (Get-PortableAutomaticBool -Name 'IsWindows')
}

function Test-IsMacOSPlatform {
    # Portable replacement for $IsMacOS that is safe on Windows PowerShell 5.1.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (Test-IsDesktopEdition) {
        return $false
    }

    return (Get-PortableAutomaticBool -Name 'IsMacOS')
}

function Test-IsLinuxPlatform {
    # Portable replacement for $IsLinux that is safe on Windows PowerShell 5.1.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (Test-IsDesktopEdition) {
        return $false
    }

    return (Get-PortableAutomaticBool -Name 'IsLinux')
}

function Get-RelativePathFallback {
    # .NET Framework fallback for [System.IO.Path]::GetRelativePath. Mirrors the native
    # algorithm: normalize both paths, confirm a shared root, diff the path segments, and
    # emit `..` for each base segment past the common prefix followed by the remaining
    # target segments. Kept as a dedicated function so it can be parity-tested directly
    # against the native method on editions where the native method exists.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string]$TargetPath
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $altSeparator = [System.IO.Path]::AltDirectorySeparatorChar
    $splitChars = [char[]]@($separator, $altSeparator)
    $trimChars = [char[]]@($separator, $altSeparator)

    # GetFullPath normalizes the inputs the same way the native method does.
    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

    # Windows path comparison is case-insensitive; Unix is case-sensitive. The fallback
    # only runs on Desktop edition (Windows) in production, but matching the running
    # platform keeps parity tests meaningful on Linux/macOS too.
    if (Test-IsWindowsPlatform) {
        $comparison = [System.StringComparison]::OrdinalIgnoreCase
    } else {
        $comparison = [System.StringComparison]::Ordinal
    }

    # A relative path only exists when both paths share the same root (drive/UNC/`/`).
    # When roots differ the native method returns the normalized full target path.
    $baseRoot = [System.IO.Path]::GetPathRoot($baseFull)
    $targetRoot = [System.IO.Path]::GetPathRoot($targetFull)
    if (-not [string]::Equals($baseRoot, $targetRoot, $comparison)) {
        return $targetFull
    }

    $baseTrimmed = $baseFull.TrimEnd($trimChars)
    $targetTrimmed = $targetFull.TrimEnd($trimChars)
    if ([string]::Equals($baseTrimmed, $targetTrimmed, $comparison)) {
        # Identical paths: native GetRelativePath returns ".".
        return '.'
    }

    # Slice off the shared root before diffing segments. Trimming a root-only path
    # (for example "/" or "C:\") can leave a string shorter than the root, so guard
    # the substring to avoid an out-of-range start index.
    $rootLength = $baseRoot.Length
    if ($baseTrimmed.Length -gt $rootLength) {
        $baseAfterRoot = $baseTrimmed.Substring($rootLength)
    } else {
        $baseAfterRoot = ''
    }
    if ($targetTrimmed.Length -gt $rootLength) {
        $targetAfterRoot = $targetTrimmed.Substring($rootLength)
    } else {
        $targetAfterRoot = ''
    }

    $baseSegments = $baseAfterRoot.Split($splitChars, [System.StringSplitOptions]::RemoveEmptyEntries)
    $targetSegments = $targetAfterRoot.Split($splitChars, [System.StringSplitOptions]::RemoveEmptyEntries)

    $common = 0
    $maxCommon = [Math]::Min($baseSegments.Length, $targetSegments.Length)
    while ($common -lt $maxCommon -and [string]::Equals($baseSegments[$common], $targetSegments[$common], $comparison)) {
        $common++
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    for ($i = $common; $i -lt $baseSegments.Length; $i++) {
        $parts.Add('..')
    }
    for ($i = $common; $i -lt $targetSegments.Length; $i++) {
        $parts.Add($targetSegments[$i])
    }

    if ($parts.Count -eq 0) {
        return '.'
    }

    return [string]::Join([string]$separator, $parts.ToArray())
}

function Get-RelativePathCompat {
    # Portable replacement for [System.IO.Path]::GetRelativePath(BasePath, TargetPath).
    # Uses the native method on editions that have it (.NET Core / .NET 5+) and a
    # segment-diff fallback on .NET Framework (Windows PowerShell 5.1).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '',
        Justification = 'GetRelativePath is reached only after a runtime reflection guard confirms the native overload exists; Windows PowerShell 5.1 always takes the Get-RelativePathFallback branch. This shim is the single sanctioned reference to the native method.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string]$TargetPath,

        # Test-only: force the .NET Framework fallback even where the native method exists.
        [Parameter(Mandatory = $false)]
        [switch]$ForceFallback
    )

    if (-not $ForceFallback) {
        $nativeMethod = [System.IO.Path].GetMethod('GetRelativePath', [type[]]@([string], [string]))
        if ($null -ne $nativeMethod) {
            return [System.IO.Path]::GetRelativePath($BasePath, $TargetPath)
        }
    }

    return (Get-RelativePathFallback -BasePath $BasePath -TargetPath $TargetPath)
}

function ConvertTo-JsonArrayCompat {
    # Portable replacement for `... | ConvertTo-Json -AsArray`.
    # On Windows PowerShell 5.1 `-AsArray` does not exist, and ConvertTo-Json collapses
    # single-element collections to a bare value. This shim uses -AsArray when present
    # (6+) and reconstructs array shape manually on 5.1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'ConvertTo-Json -AsArray is reached only after a runtime Get-Command capability probe confirms the parameter exists; Windows PowerShell 5.1 takes the manual array-shape branch instead. This shim is the single sanctioned use of -AsArray.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        $InputObject,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$Depth = 10,

        [Parameter(Mandatory = $false)]
        [switch]$Compress
    )

    begin {
        $items = [System.Collections.Generic.List[object]]::new()
    }

    process {
        # Collect pipeline input element-by-element so callers can pipe a collection.
        foreach ($item in $InputObject) {
            $items.Add($item)
        }
    }

    end {
        $materialized = @($items)

        # Empty collections are an array on every edition.
        if ($materialized.Count -eq 0) {
            return '[]'
        }

        # PowerShell 6+ has -AsArray. Pipe the elements so each is a separate item and
        # -AsArray guarantees array shape (including the single-element case).
        $supportsAsArray = (Get-Command -Name 'ConvertTo-Json' -ErrorAction Stop).Parameters.ContainsKey('AsArray')
        if ($supportsAsArray) {
            if ($Compress) {
                return ($materialized | ConvertTo-Json -Depth $Depth -AsArray -Compress)
            }
            return ($materialized | ConvertTo-Json -Depth $Depth -AsArray)
        }

        # Windows PowerShell 5.1 has no -AsArray and collapses single-element collections to
        # a bare value. Serialize via -InputObject (avoids pipeline unrolling) and wrap when
        # the serializer did not already emit array brackets.
        $jsonParameters = @{ InputObject = $materialized; Depth = $Depth }
        if ($Compress) {
            $jsonParameters['Compress'] = $true
        }

        $json = ConvertTo-Json @jsonParameters
        if ($json.TrimStart().StartsWith('[')) {
            return $json
        }

        if ($Compress) {
            return ('[' + $json + ']')
        }

        $newLine = [System.Environment]::NewLine
        $indented = (($json -split "`r?`n") | ForEach-Object { '  ' + $_ }) -join $newLine
        return ('[' + $newLine + $indented + $newLine + ']')
    }
}

# direct-json-ok: ConvertFrom-Json - this helper IS the sanctioned cross-version
# ConvertFrom-Json wrapper; it must call the cmdlet directly to provide the portable
# alternative that other utility scripts use in its place.
function ConvertFrom-JsonCompat {
    # Portable replacement for ConvertFrom-Json that tolerates the absence of
    # -Depth and -NoEnumerate on Windows PowerShell 5.1.
    #   - On 5.1, -Depth is unsupported (its parser has a fixed effective depth) and is
    #     silently dropped.
    #   - On 5.1, -NoEnumerate is unsupported; array preservation is reproduced by
    #     returning the parsed value wrapped with the comma operator so a top-level
    #     array is not unrolled by the caller's pipeline.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        $InputObject,

        [Parameter(Mandatory = $false)]
        [int]$Depth,

        [Parameter(Mandatory = $false)]
        [switch]$NoEnumerate
    )

    process {
        $convertCommand = Get-Command -Name 'ConvertFrom-Json' -ErrorAction Stop
        $convertParameters = @{ ErrorAction = 'Stop' }

        if ($PSBoundParameters.ContainsKey('Depth') -and $convertCommand.Parameters.ContainsKey('Depth')) {
            $convertParameters['Depth'] = $Depth
        }

        # Use native -NoEnumerate when present so nested structures parse correctly; the
        # comma-operator return below still applies (see note).
        if ($NoEnumerate -and $convertCommand.Parameters.ContainsKey('NoEnumerate')) {
            $convertParameters['NoEnumerate'] = $true
        }

        $parsed = $InputObject | ConvertFrom-Json @convertParameters

        if ($NoEnumerate -and ([string]$InputObject).TrimStart().StartsWith('[')) {
            # A top-level JSON array must be returned as a SINGLE object so that neither
            # this function's own pipeline output (which would otherwise unroll it) nor
            # Windows PowerShell 5.1's enumeration collapses it — in particular a
            # single-element array must not degrade to a scalar. Materialize and emit via
            # the comma operator. Non-array JSON (object/scalar) is returned as-is.
            return , ([object[]]@($parsed))
        }

        return $parsed
    }
}
