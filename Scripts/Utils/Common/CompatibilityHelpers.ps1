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

function Resolve-PowerShellExecutablePath {
    # Resolves the PowerShell executable path used to invoke child scripts.
    # Preference order:
    #   1) pwsh (all platforms)
    #   2) powershell.exe (Windows fallback)
    # Throws a stable E_* diagnostic when no supported executable is available.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $pwshCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    if ($null -ne $pwshCommand -and -not [string]::IsNullOrWhiteSpace([string]$pwshCommand.Source)) {
        Write-Verbose (
            "PowerShell executable resolver diagnostics: selectedExecutable='{0}'; source='pwsh'." -f
            $pwshCommand.Source
        )
        return [string]$pwshCommand.Source
    }

    if (Test-IsWindowsPlatform) {
        $windowsPowerShellCommand = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue
        if ($null -ne $windowsPowerShellCommand -and -not [string]::IsNullOrWhiteSpace([string]$windowsPowerShellCommand.Source)) {
            Write-Verbose (
                "PowerShell executable resolver diagnostics: selectedExecutable='{0}'; source='powershell.exe-fallback'." -f
                $windowsPowerShellCommand.Source
            )
            return [string]$windowsPowerShellCommand.Source
        }
    }

    $platformName = 'Unknown'
    if (Test-IsWindowsPlatform) {
        $platformName = 'Windows'
    }
    elseif (Test-IsMacOSPlatform) {
        $platformName = 'macOS'
    }
    elseif (Test-IsLinuxPlatform) {
        $platformName = 'Linux'
    }

    $checkedExecutables = @('pwsh')
    if ($platformName -eq 'Windows') {
        $checkedExecutables += 'powershell.exe'
    }

    throw (
        "E_COMPATIBILITY_POWERSHELL_EXECUTABLE_NOT_FOUND: unable to resolve a PowerShell executable for child script execution. Checked={0}; platform='{1}'." -f
        ($checkedExecutables -join ', '),
        $platformName
    )
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

function ConvertTo-ProcessArgumentString {
    # Builds a single Win32 command-line string from an argument vector, applying the exact
    # escaping algorithm .NET Core uses internally to render ProcessStartInfo.ArgumentList
    # into the OS command line (the runtime's PasteArguments.AppendArgument). This is the
    # .NET Framework (Windows PowerShell 5.1) fallback for the ArgumentList collection, which
    # does not exist before .NET Core 2.1; see Set-PortableProcessArguments.
    #
    # Rules (CommandLineToArgvW-compatible):
    #   - Empty arguments render as "" so they survive as a distinct, empty token.
    #   - Arguments without whitespace or a double quote are emitted verbatim (backslashes
    #     stay literal because they are not adjacent to a quote).
    #   - Otherwise the argument is wrapped in quotes; backslashes are doubled only when they
    #     precede a quote (or the closing quote) and an embedded quote is escaped as \".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @()
    )

    if ($null -eq $ArgumentList) {
        return ""
    }

    $builder = [System.Text.StringBuilder]::new()
    $backslash = [char]'\'
    $quote = [char]'"'

    foreach ($rawArgument in @($ArgumentList)) {
        $argument = if ($null -eq $rawArgument) { '' } else { [string]$rawArgument }

        if ($builder.Length -gt 0) {
            [void]$builder.Append(' ')
        }

        $needsQuoting = ($argument.Length -eq 0)
        if (-not $needsQuoting) {
            foreach ($character in $argument.ToCharArray()) {
                if ([char]::IsWhiteSpace($character) -or $character -eq $quote) {
                    $needsQuoting = $true
                    break
                }
            }
        }

        if (-not $needsQuoting) {
            [void]$builder.Append($argument)
            continue
        }

        [void]$builder.Append($quote)
        $index = 0
        while ($index -lt $argument.Length) {
            $character = $argument[$index]
            $index++

            if ($character -eq $backslash) {
                $backslashCount = 1
                while ($index -lt $argument.Length -and $argument[$index] -eq $backslash) {
                    $index++
                    $backslashCount++
                }

                if ($index -eq $argument.Length) {
                    # Trailing run of backslashes precedes the closing quote: double them so
                    # the quote is not consumed as an escape.
                    [void]$builder.Append($backslash, $backslashCount * 2)
                }
                elseif ($argument[$index] -eq $quote) {
                    # Backslashes precede a literal quote: double them and escape the quote.
                    [void]$builder.Append($backslash, $backslashCount * 2 + 1)
                    [void]$builder.Append($quote)
                    $index++
                }
                else {
                    # Backslashes are not adjacent to a quote: emit them unchanged.
                    [void]$builder.Append($backslash, $backslashCount)
                }
            }
            elseif ($character -eq $quote) {
                [void]$builder.Append($backslash)
                [void]$builder.Append($quote)
            }
            else {
                [void]$builder.Append($character)
            }
        }
        [void]$builder.Append($quote)
    }

    return $builder.ToString()
}

function Set-PortableProcessArguments {
    # Portable replacement for the `foreach ($a in $args) { $psi.ArgumentList.Add($a) }`
    # idiom. ProcessStartInfo.ArgumentList (which escapes each argument independently and
    # avoids hand-rolled command-line quoting bugs) exists only on .NET Core 2.1+/.NET 5+
    # (PowerShell 7+). On .NET Framework (Windows PowerShell 5.1) the property is absent and
    # accessing it throws "The property 'ArgumentList' cannot be found on this object"; there
    # the equivalent escaped string is assigned to .Arguments instead. This is the single
    # sanctioned reference to ProcessStartInfo.ArgumentList in the repository.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '',
        Justification = 'ArgumentList is populated only after a runtime reflection guard confirms the .NET Core property exists; Windows PowerShell 5.1 takes the ConvertTo-ProcessArgumentString / .Arguments branch. Single sanctioned reference to ProcessStartInfo.ArgumentList.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Diagnostics.ProcessStartInfo]$StartInfo,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        # Test-only: force the .NET Framework (.Arguments string) fallback even where the
        # native ArgumentList collection exists.
        [Parameter(Mandatory = $false)]
        [switch]$ForceFallback
    )

    $normalizedArguments = @()
    if ($null -ne $ArgumentList) {
        $normalizedArguments = @($ArgumentList)
    }

    $hasArgumentList = $false
    if (-not $ForceFallback) {
        $hasArgumentList = ($null -ne [System.Diagnostics.ProcessStartInfo].GetProperty('ArgumentList'))
    }

    if ($hasArgumentList) {
        foreach ($argument in $normalizedArguments) {
            [void]$StartInfo.ArgumentList.Add($argument) # compat-core-member-ok: guarded by the reflection probe above.
        }
        return
    }

    # Advisory telemetry only (argument count, never values, to avoid leaking secrets into
    # verbose logs): records that the .NET Framework escaping path was taken on this edition.
    Write-Verbose ("Set-PortableProcessArguments diagnostics: mode=arguments-string-fallback argumentCount={0} (ProcessStartInfo.ArgumentList is unavailable on this PowerShell edition)." -f $normalizedArguments.Count)
    $StartInfo.Arguments = ConvertTo-ProcessArgumentString -ArgumentList $normalizedArguments
}

function Set-PortableProcessEnvironmentVariable {
    # Sets/removes a ProcessStartInfo environment variable while avoiding duplicate
    # case variants on Windows, where child process environment names are case-insensitive.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Diagnostics.ProcessStartInfo]$StartInfo,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value,

        # Test-only: force Windows-style matching on non-Windows runners.
        [Parameter(Mandatory = $false)]
        [switch]$CaseInsensitive
    )

    if ($CaseInsensitive -or (Test-IsWindowsPlatform)) {
        $comparison = [System.StringComparison]::OrdinalIgnoreCase
    } else {
        $comparison = [System.StringComparison]::Ordinal
    }

    $keysToRemove = @(
        $StartInfo.Environment.Keys |
            Where-Object { [string]::Equals([string]$_, $Name, $comparison) } |
            ForEach-Object { [string]$_ }
    )

    foreach ($existingName in $keysToRemove) {
        [void]$StartInfo.Environment.Remove($existingName)
    }

    if ($null -ne $Value) {
        $StartInfo.Environment[$Name] = [string]$Value
    }
}

function Get-ChildProcessIdsPortably {
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ParentProcessId
    )

    if (Test-IsWindowsPlatform) {
        $getCimInstanceCommand = Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue
        if ($null -eq $getCimInstanceCommand) {
            Write-Verbose "Process tree cleanup diagnostics: Get-CimInstance unavailable; descendant discovery degraded."
            return @() # array-unwrap-safe: callers always wrap with @()
        }

        try {
            $filter = "ParentProcessId = {0}" -f $ParentProcessId
            return @(
                & $getCimInstanceCommand -ClassName Win32_Process -Filter $filter -ErrorAction Stop |
                    ForEach-Object { [int]$_.ProcessId }
            ) # array-unwrap-safe: callers always wrap with @()
        }
        catch {
            Write-Verbose ("Process tree cleanup diagnostics: Get-CimInstance child discovery failed for parentPid={0}: {1}" -f $ParentProcessId,$_.Exception.Message)
            return @() # array-unwrap-safe: callers always wrap with @()
        }
    }

    $pgrepCommand = @(Get-Command -Name 'pgrep' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($pgrepCommand.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$pgrepCommand[0].Source)) {
        try {
            $pgrepOutput = @(& ([string]$pgrepCommand[0].Source) -P $ParentProcessId 2>$null)
            if ($LASTEXITCODE -eq 0) {
                return @(
                    $pgrepOutput |
                        Where-Object { [string]$_ -match '^\d+$' } |
                        ForEach-Object { [int]$_ }
                ) # array-unwrap-safe: callers always wrap with @()
            }
        }
        catch {
            Write-Verbose ("Process tree cleanup diagnostics: pgrep child discovery failed for parentPid={0}: {1}" -f $ParentProcessId,$_.Exception.Message)
        }
    }

    $psCommand = @(Get-Command -Name 'ps' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($psCommand.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$psCommand[0].Source)) {
        try {
            $processLines = @(& ([string]$psCommand[0].Source) -eo pid=,ppid= 2>$null)
            if ($LASTEXITCODE -eq 0) {
                return @(
                    $processLines |
                        ForEach-Object {
                            $match = [regex]::Match([string]$_, '^\s*(?<pid>\d+)\s+(?<ppid>\d+)\s*$')
                            if ($match.Success -and [int]$match.Groups['ppid'].Value -eq $ParentProcessId) {
                                [int]$match.Groups['pid'].Value
                            }
                        }
                ) # array-unwrap-safe: callers always wrap with @()
            }
        }
        catch {
            Write-Verbose ("Process tree cleanup diagnostics: ps child discovery failed for parentPid={0}: {1}" -f $ParentProcessId,$_.Exception.Message)
        }
    }

    Write-Verbose ("Process tree cleanup diagnostics: descendant discovery unavailable for parentPid={0}." -f $ParentProcessId)
    return @() # array-unwrap-safe: callers always wrap with @()
}

function Get-ProcessDescendantIdsPortably {
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ParentProcessId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$VisitedProcessIds
    )

    if ($null -eq $VisitedProcessIds) {
        $VisitedProcessIds = @{}
    }

    $descendantIds = New-Object System.Collections.Generic.List[int]
    foreach ($childProcessId in @(Get-ChildProcessIdsPortably -ParentProcessId $ParentProcessId)) {
        $childKey = [string]$childProcessId
        if ($VisitedProcessIds.ContainsKey($childKey)) {
            continue
        }

        $VisitedProcessIds[$childKey] = $true
        foreach ($grandchildProcessId in @(Get-ProcessDescendantIdsPortably -ParentProcessId $childProcessId -VisitedProcessIds $VisitedProcessIds)) {
            $descendantIds.Add([int]$grandchildProcessId) | Out-Null
        }

        $descendantIds.Add([int]$childProcessId) | Out-Null
    }

    return @($descendantIds.ToArray()) # array-unwrap-safe: callers always wrap with @()
}

function Stop-ProcessByIdPortably {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    try {
        $targetProcess = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    }
    catch {
        return
    }

    try {
        $targetProcess.Kill()
    }
    catch {
        Write-Verbose ("Process tree cleanup diagnostics: failed to kill processId={0}: {1}" -f $ProcessId,$_.Exception.Message)
    }
    finally {
        $targetProcess.Dispose()
    }
}

function Stop-ProcessTreeFallbackPortably {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Diagnostics.Process]$Process
    )

    $rootProcessId = [int]$Process.Id
    $visitedProcessIds = @{ ([string]$rootProcessId) = $true }
    $descendantProcessIds = @(Get-ProcessDescendantIdsPortably -ParentProcessId $rootProcessId -VisitedProcessIds $visitedProcessIds)

    foreach ($descendantProcessId in $descendantProcessIds) {
        Stop-ProcessByIdPortably -ProcessId ([int]$descendantProcessId)
    }

    try {
        $Process.Kill()
    }
    catch {
        Write-Verbose ("Process tree cleanup diagnostics: failed to kill root processId={0}: {1}" -f $rootProcessId,$_.Exception.Message)
    }
}

function Stop-ProcessTreePortably {
    # Portable replacement for [System.Diagnostics.Process]::Kill($true) (terminate the whole
    # process tree). The Kill(bool) overload was added in .NET Core 3.0 and is ABSENT on
    # Windows PowerShell 5.1 (.NET Framework), where $process.Kill($true) throws "Cannot find an
    # overload for 'Kill' and the argument count: '1'". On editions with the overload the entire
    # tree is terminated by .NET. On fallback paths, descendants are discovered and killed
    # recursively before the root process. This is the single sanctioned reference to the
    # Kill(bool) overload.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '',
        Justification = 'Kill($true) is invoked only after a runtime reflection guard confirms the .NET Core 3.0+ overload exists; Windows PowerShell 5.1 falls back to explicit descendant discovery plus parameterless Kill(). Single sanctioned reference to the Kill(bool) overload.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Diagnostics.Process]$Process,

        # Test-only: force the Windows PowerShell 5.1 explicit descendant-discovery fallback even
        # where the Kill(bool) overload exists.
        [Parameter(Mandatory = $false)]
        [switch]$ForceFallback
    )

    $hasTreeKill = $false
    if (-not $ForceFallback) {
        $hasTreeKill = ($null -ne [System.Diagnostics.Process].GetMethod('Kill', [type[]]@([bool])))
    }

    if ($hasTreeKill) {
        $Process.Kill($true) # compat-core-member-ok: guarded by the reflection probe above.
        return
    }

    Stop-ProcessTreeFallbackPortably -Process $Process
}

function Get-FileSystemLinkTargetProperty {
    # Reads the immediate symbolic-link/reparse-point target of a FileSystemInfo-like object
    # from the LinkTarget/Target members, returning the target string or $null. Both the
    # .NET 6 LinkTarget property and the Windows PowerShell 5.0+ Target ETS member are
    # consulted via duck typing so the same helper works on real items across editions and on
    # the Add-Member test doubles used by the discovery tests. On Windows PowerShell 5.1 the
    # Target member can surface as a string array (legacy multi-target shape); the first
    # entry is used.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Item
    )

    foreach ($propertyName in @('LinkTarget', 'Target')) {
        $property = $Item.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $null -eq $property.Value) {
            continue
        }

        $value = $property.Value
        if ($value -is [System.Array]) {
            if ($value.Length -eq 0) {
                continue
            }
            $value = $value[0]
        }

        $stringValue = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($stringValue)) {
            return $stringValue
        }
    }

    return $null
}

function Get-PortableLinkTarget {
    # Portable equivalent of [System.IO.FileSystemInfo]::ResolveLinkTarget($true), which was
    # introduced in .NET 6 / PowerShell 7.1 and is absent on Windows PowerShell 5.1. Returns
    # the FINAL target's full path (string) for a symbolic link or reparse point, or $null
    # when the item is not a link or no target can be resolved.
    #
    # On editions that expose the native method it is used directly (it already follows link
    # chains to the final target). On Windows PowerShell 5.1 the link target is read from the
    # LinkTarget/Target ETS members that PowerShell projects onto FileSystemInfo and chains
    # are followed hop-by-hop (bounded by -MaxDepth, and stopping as soon as a hop no longer
    # resolves or is no longer a link) so the result matches the native "final target"
    # semantics. Item access is duck-typed so production callers and the Add-Member test
    # doubles share one code path. This is the single sanctioned reference to ResolveLinkTarget.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '',
        Justification = 'ResolveLinkTarget is invoked only after a runtime duck-typing guard confirms the .NET 6+ method is present on the instance; Windows PowerShell 5.1 takes the LinkTarget/Target ETS branch. Single sanctioned reference to the native method.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Item,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 256)]
        [int]$MaxDepth = 64,

        # Test-only: force the Windows PowerShell 5.1 (LinkTarget/Target ETS) fallback even
        # where the native ResolveLinkTarget method exists, so the fallback can be parity-
        # tested against the native method on PowerShell 7+.
        [Parameter(Mandatory = $false)]
        [switch]$ForceFallback
    )

    if (-not $ForceFallback -and ($Item.PSObject.Methods.Name -contains 'ResolveLinkTarget')) {
        $resolved = $null
        try {
            $resolved = $Item.ResolveLinkTarget($true) # compat-core-member-ok: guarded by the PSObject.Methods probe above.
        }
        catch {
            $resolved = $null
        }

        if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace([string]$resolved.FullName)) {
            return [string]$resolved.FullName
        }

        return $null
    }

    $currentItem = $Item
    $resolvedPath = $null
    # Track visited targets so a symlink cycle terminates (bounded additionally by -MaxDepth)
    # instead of looping; comparison is OS-appropriate (case-insensitive only on Windows).
    $visitedComparer = if (Test-IsWindowsPlatform) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $visitedTargets = [System.Collections.Generic.HashSet[string]]::new($visitedComparer)
    for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
        $hopTarget = Get-FileSystemLinkTargetProperty -Item $currentItem
        if ([string]::IsNullOrWhiteSpace($hopTarget)) {
            break
        }

        if (-not [System.IO.Path]::IsPathRooted($hopTarget)) {
            # A relative target is resolved against the directory containing the link.
            $linkParent = Split-Path -Path ([string]$currentItem.FullName) -Parent
            if ([string]::IsNullOrWhiteSpace($linkParent)) {
                $linkParent = [System.IO.Path]::GetPathRoot([string]$currentItem.FullName)
            }
            $hopTarget = Join-Path -Path $linkParent -ChildPath $hopTarget
        }

        $resolvedPath = [System.IO.Path]::GetFullPath($hopTarget)

        if (-not $visitedTargets.Add($resolvedPath)) {
            # Cycle detected (this target was already resolved on a previous hop). The native
            # ResolveLinkTarget($true) throws "Too many levels of symbolic links" on a cycle,
            # which callers treat as unresolved; return $null here for the same final outcome.
            return $null
        }

        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            break
        }

        $nextItem = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $nextItem -or [string]::IsNullOrWhiteSpace((Get-FileSystemLinkTargetProperty -Item $nextItem))) {
            break
        }

        $currentItem = $nextItem
    }

    return $resolvedPath
}
