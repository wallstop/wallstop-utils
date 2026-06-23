<#
.SYNOPSIS
    Static cross-version compatibility gate for Windows PowerShell 5.1 <-> PowerShell 7+.

.DESCRIPTION
    Runs the PSScriptAnalyzer compatibility rules (PSUseCompatibleSyntax,
    PSUseCompatibleCommands, PSUseCompatibleTypes) against repository PowerShell sources
    targeting both Windows PowerShell 5.1 (Desktop / .NET Framework) and PowerShell 7+
    (Core). Any finding that is not a known false positive fails the gate with a stable
    E_COMPAT_INCOMPATIBILITY diagnostic.

    False positives are handled in these sanctioned ways:
      - Inline [Diagnostics.CodeAnalysis.SuppressMessageAttribute] with a justification,
        for guarded native calls (honored natively by PSScriptAnalyzer).
      - The AllowedCommands list in compatibility-allowlist.psd1, for external
        executables and runtime-installed module commands (for example Pester 5).
      - Narrow structural filters in shared helpers for repository-owned guarded
        compatibility idioms that PSScriptAnalyzer cannot model.

    This script must itself remain runnable on Windows PowerShell 5.1: no ternary,
    null-coalescing, pipeline-chain operators, $IsWindows/$IsMacOS/$IsLinux references,
    or .NET Core-only APIs.

.PARAMETER Path
    Repository root (or any directory) to scan recursively. Defaults to the repository
    root inferred from this script's location.

.PARAMETER TargetFiles
    Optional explicit list of .ps1/.psm1 files to check instead of a recursive scan.
    Files that do not exist are skipped with a diagnostic; an input that resolves to zero
    existing targets skips cleanly without widening to a full-repo scan.

.PARAMETER OutputFormat
    'text' (default) for human-readable output, or 'json' for a machine-readable record.

.OUTPUTS
    Exit code 0 when no real incompatibilities remain; 1 otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string[]]$TargetFiles,

    [Parameter(Mandatory = $false)]
    [ValidateSet('text', 'json')]
    [string]$OutputFormat = 'text',

    [Parameter(Mandatory = $false)]
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
# Repo root is three levels up: Scripts/Utils/Quality -> repo root.
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $scriptRoot -ChildPath "../../..")).Path
$psReadLineProfilePortabilityHelpersPath = Join-Path -Path $scriptRoot -ChildPath "../Common/PSReadLineProfilePortabilityHelpers.ps1"
if (-not (Test-Path -LiteralPath $psReadLineProfilePortabilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: PSReadLine profile portability helper file not found at '$psReadLineProfilePortabilityHelpersPath'."
}

. $psReadLineProfilePortabilityHelpersPath

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = $repositoryRoot
}

function Resolve-CompatibilityProfile {
    # Picks an installed PSScriptAnalyzer compatibility profile matching a filename
    # pattern, so the gate stays robust across analyzer versions instead of pinning an
    # exact build number that may not exist in the installed module.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $profileMatches = @(Get-ChildItem -Path $ProfileDirectory -Filter $Pattern -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name)
    if ($profileMatches.Count -eq 0) {
        throw "E_COMPAT_PROFILE_MISSING: No PSScriptAnalyzer compatibility profile found for $Description (pattern '$Pattern') under '$ProfileDirectory'."
    }

    # Profile id is the file name without the .json extension.
    return [System.IO.Path]::GetFileNameWithoutExtension($profileMatches[0].FullName)
}

function Get-CompatibilityTargetProfile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($null -eq $analyzerModule) {
        throw "E_COMPAT_ANALYZER_MISSING: PSScriptAnalyzer module is not installed. Install it with 'Install-Module PSScriptAnalyzer -Scope CurrentUser'."
    }

    $profileDirectory = Join-Path -Path $analyzerModule.ModuleBase -ChildPath "compatibility_profiles"
    if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
        throw "E_COMPAT_PROFILE_DIR_MISSING: PSScriptAnalyzer compatibility_profiles directory not found at '$profileDirectory'."
    }

    $windowsPowerShell = Resolve-CompatibilityProfile -ProfileDirectory $profileDirectory -Pattern "win-*5.1*framework.json" -Description "Windows PowerShell 5.1 (Desktop)"
    $powerShellCoreWindows = Resolve-CompatibilityProfile -ProfileDirectory $profileDirectory -Pattern "win-*_7.*_core.json" -Description "PowerShell 7+ (Windows)"
    $powerShellCoreLinux = Resolve-CompatibilityProfile -ProfileDirectory $profileDirectory -Pattern "ubuntu_*_7.*_core.json" -Description "PowerShell 7+ (Linux)"

    return @($windowsPowerShell, $powerShellCoreWindows, $powerShellCoreLinux)
}

function Get-AllowedCommandData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AllowlistPath
    )

    if (-not (Test-Path -LiteralPath $AllowlistPath -PathType Leaf)) {
        throw "E_COMPAT_ALLOWLIST_MISSING: Compatibility allowlist not found at '$AllowlistPath'."
    }

    $data = Import-PowerShellDataFile -LiteralPath $AllowlistPath
    $externalExecutables = @()
    if ($data.ContainsKey('ExternalExecutables')) {
        $externalExecutables = @($data['ExternalExecutables'])
    }
    $moduleCommands = @()
    if ($data.ContainsKey('ModuleCommands')) {
        $moduleCommands = @($data['ModuleCommands'])
    }

    return @{
        ExternalExecutables = $externalExecutables
        ModuleCommands      = $moduleCommands
    }
}

function Get-CompatibilityTargetFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$ExplicitFiles
    )

    if ($null -ne $ExplicitFiles -and $ExplicitFiles.Count -gt 0) {
        $resolved = New-Object System.Collections.Generic.List[string]
        foreach ($candidate in $ExplicitFiles) {
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $resolved.Add((Resolve-Path -LiteralPath $candidate).Path)
            } else {
                Write-Warning "W_COMPAT_TARGET_MISSING: Skipping non-existent target '$candidate'."
            }
        }
        return , @($resolved.ToArray())
    }

    $found = @(Get-ChildItem -Path $RootPath -Recurse -File -Include *.ps1, *.psm1 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(\\|/)\.git(\\|/)' } |
            ForEach-Object { $_.FullName } |
            Sort-Object)
    return , @($found)
}

function Get-AutomaticVariableViolation {
    # Detects bare references to OS/style automatic variables that do not exist on
    # Windows PowerShell 5.1 ($IsWindows/$IsMacOS/$IsLinux/$PSStyle). Under StrictMode a
    # bare reference THROWS on 5.1, and PSScriptAnalyzer's compatibility rules cannot see
    # this class of incompatibility. Uses the AST so matches inside comments or string
    # literals are not flagged. The compatibility shim itself is exempt because it reads
    # these variables by name through Get-Variable, never as bare references.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $forbiddenNames = @('IsWindows', 'IsMacOS', 'IsLinux', 'IsCoreCLR', 'PSStyle')
    $violations = New-Object System.Collections.Generic.List[object]

    $fileName = Split-Path -Path $FilePath -Leaf
    if ($fileName -eq 'CompatibilityHelpers.ps1') {
        return , @($violations.ToArray())
    }

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast) {
        return , @($violations.ToArray())
    }

    $variableAsts = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)

    $relativePath = $FilePath
    if ($FilePath.StartsWith($RepositoryRoot)) {
        $relativePath = $FilePath.Substring($RepositoryRoot.Length).TrimStart([char[]]@('/', '\'))
    }
    $relativePath = $relativePath.Replace('\', '/')

    foreach ($variableAst in $variableAsts) {
        $variableName = $variableAst.VariablePath.UserPath
        if ($forbiddenNames -contains $variableName) {
            $violations.Add([pscustomobject]@{
                    file     = $relativePath
                    line     = $variableAst.Extent.StartLineNumber
                    ruleName = 'CompatAutomaticVariable'
                    severity = 'Error'
                    message  = "The automatic variable '`$$variableName' is undefined on Windows PowerShell 5.1 and throws under StrictMode. Use the Test-Is*Platform helpers from CompatibilityHelpers.ps1 instead."
                })
        }
    }

    return , @($violations.ToArray())
}

function Get-WebRequestParsingViolation {
    # Flags Invoke-WebRequest calls that omit -UseBasicParsing. On Windows PowerShell 5.1
    # the default response parser uses the Internet Explorer engine, which throws on hosts
    # where IE first-launch configuration is incomplete (servers, CI). -UseBasicParsing is a
    # harmless no-op on PowerShell 7+. PSScriptAnalyzer cannot model this default-behavior
    # divergence, so it is checked here via the AST.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $violations = New-Object System.Collections.Generic.List[object]

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast) {
        return , @($violations.ToArray())
    }

    $relativePath = $FilePath
    if ($FilePath.StartsWith($RepositoryRoot)) {
        $relativePath = $FilePath.Substring($RepositoryRoot.Length).TrimStart([char[]]@('/', '\'))
    }
    $relativePath = $relativePath.Replace('\', '/')

    $commandAsts = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)

    foreach ($commandAst in $commandAsts) {
        $commandName = $commandAst.GetCommandName()
        if ($null -eq $commandName) {
            continue
        }
        # Only the cmdlet and its built-in alias are flagged. The curl/wget aliases are
        # intentionally excluded: on Linux/macOS they resolve to the real native binaries,
        # which have nothing to do with the IE-engine parsing behavior.
        if (@('Invoke-WebRequest', 'iwr') -notcontains $commandName) {
            continue
        }

        $hasUseBasicParsing = $false
        foreach ($element in $commandAst.CommandElements) {
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                $element.ParameterName -like 'UseBasicParsing*') {
                $hasUseBasicParsing = $true
                break
            }
        }

        if (-not $hasUseBasicParsing) {
            $violations.Add([pscustomobject]@{
                    file     = $relativePath
                    line     = $commandAst.Extent.StartLineNumber
                    ruleName = 'CompatWebRequestParsing'
                    severity = 'Error'
                    message  = "Invoke-WebRequest must pass -UseBasicParsing for Windows PowerShell 5.1 compatibility (the IE parser is unavailable on many 5.1 hosts; -UseBasicParsing is a no-op on 7+)."
                })
        }
    }

    return , @($violations.ToArray())
}

function Get-CoreOnlyMemberViolation {
    # Flags member access to .NET members that exist only on .NET Core / .NET 5+ (PowerShell
    # 7+) and are ABSENT on Windows PowerShell 5.1 (.NET Framework), where the access throws
    # "The property '<name>' cannot be found on this object" at runtime. PSScriptAnalyzer's
    # PSUseCompatibleTypes models incompatible TYPES, not incompatible MEMBERS of a type that
    # exists on both editions, so this class is analyzer-invisible (it slipped past the gate
    # and only surfaced in the Windows PowerShell 5.1 runtime lane). It is checked here via the
    # AST. Each member has a tiny, explicit set of sanctioned homes: the CompatibilityHelpers
    # shim that wraps it behind a runtime capability guard (and, for ResolveLinkTarget, the
    # Remove-BOM discovery helper, whose raw use is itself capability-guarded).
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $violations = New-Object System.Collections.Generic.List[object]

    # Tests legitimately attach these member names to Add-Member mock doubles, and the dual-
    # edition Pester lanes already exercise tests on Windows PowerShell 5.1 directly, so static
    # enforcement here is scoped to production sources.
    $normalizedFilePath = $FilePath.Replace('\', '/')
    if ($normalizedFilePath -match '/Tests/') {
        return , @($violations.ToArray())
    }

    # Member name -> match rules + remediation. RequireInvocation limits a method-only member
    # to call sites; MinArgumentCount distinguishes a Core-only OVERLOAD (for example
    # Process.Kill($true), .NET Core 3.0+) from a member present on both editions (Process.Kill()).
    # A deliberate, runtime-guarded native access opts out with an inline '# compat-core-member-ok'
    # marker on the access line, mirroring the repo's other inline markers (# array-unwrap-safe,
    # # direct-json-ok). This is finer-grained and safer than whole-file allowlisting, which would
    # also exempt a future UNguarded access in the same file.
    $coreOnlyMembers = @{
        'ArgumentList'      = @{ RequireInvocation = $false; MinArgumentCount = 0; Remediation = "ProcessStartInfo.ArgumentList exists only on .NET Core 2.1+ (PowerShell 7+). Use Set-PortableProcessArguments from CompatibilityHelpers.ps1." }
        'ResolveLinkTarget' = @{ RequireInvocation = $true; MinArgumentCount = 0; Remediation = "FileSystemInfo.ResolveLinkTarget exists only on .NET 6+ (PowerShell 7.1+). Use Get-PortableLinkTarget from CompatibilityHelpers.ps1." }
        'LinkTarget'        = @{ RequireInvocation = $false; MinArgumentCount = 0; Remediation = "FileSystemInfo.LinkTarget exists only on .NET 6+ (PowerShell 7.1+). Use Get-PortableLinkTarget / Get-FileSystemLinkTargetProperty from CompatibilityHelpers.ps1." }
        'Kill'              = @{ RequireInvocation = $true; MinArgumentCount = 1; Remediation = "Process.Kill([bool]) exists only on .NET Core 3.0+ (PowerShell 7+). Use Stop-ProcessTreePortably from CompatibilityHelpers.ps1." }
    }

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast) {
        return , @($violations.ToArray())
    }

    # Read raw lines (FileShare.Read, closes immediately) to test for the opt-out marker.
    $sourceLines = [System.IO.File]::ReadAllLines($FilePath)

    $relativePath = $FilePath
    if ($FilePath.StartsWith($RepositoryRoot)) {
        $relativePath = $FilePath.Substring($RepositoryRoot.Length).TrimStart([char[]]@('/', '\'))
    }
    $relativePath = $relativePath.Replace('\', '/')

    # MemberExpressionAst covers both property access ($x.ArgumentList) and method invocation
    # ($x.ResolveLinkTarget(...)), since InvokeMemberExpressionAst derives from it. Keying on
    # the static member NAME means $var/param references named "ArgumentList" and string
    # arguments to reflection calls (GetProperty('ArgumentList')) are never flagged.
    $memberAccessAsts = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.MemberExpressionAst]
        }, $true)

    foreach ($memberAst in $memberAccessAsts) {
        $memberNameAst = $memberAst.Member
        if (-not ($memberNameAst -is [System.Management.Automation.Language.StringConstantExpressionAst])) {
            # Dynamic member name (for example $obj.$name); cannot be resolved statically.
            continue
        }

        $memberName = $memberNameAst.Value
        if (-not $coreOnlyMembers.ContainsKey($memberName)) {
            continue
        }

        $memberSpec = $coreOnlyMembers[$memberName]
        $isInvocation = ($memberAst -is [System.Management.Automation.Language.InvokeMemberExpressionAst])
        if ($memberSpec.RequireInvocation -and -not $isInvocation) {
            continue
        }
        if ($memberSpec.MinArgumentCount -gt 0) {
            if (-not $isInvocation) {
                continue
            }
            $argumentCount = 0
            if ($null -ne $memberAst.Arguments) {
                $argumentCount = @($memberAst.Arguments).Count
            }
            if ($argumentCount -lt $memberSpec.MinArgumentCount) {
                continue
            }
        }

        $lineNumber = $memberAst.Extent.StartLineNumber
        # Scan every line the member expression spans (not just its start line) for the opt-out
        # marker, so a marker on the visual member/closing-paren line of a multi-line expression
        # still applies.
        $isMarked = $false
        for ($markerLine = $memberAst.Extent.StartLineNumber; $markerLine -le $memberAst.Extent.EndLineNumber; $markerLine++) {
            if ($markerLine -ge 1 -and $markerLine -le $sourceLines.Length -and $sourceLines[$markerLine - 1].Contains('compat-core-member-ok')) {
                $isMarked = $true
                break
            }
        }
        if ($isMarked) {
            continue
        }

        $violations.Add([pscustomobject]@{
                file     = $relativePath
                line     = $lineNumber
                ruleName = 'CompatCoreOnlyMember'
                severity = 'Error'
                message  = "Access to the .NET Core-only member '.$memberName' is undefined on Windows PowerShell 5.1 and throws under StrictMode. $($memberSpec.Remediation) (If this access is deliberately runtime-guarded, annotate the line with '# compat-core-member-ok'.)"
            }) | Out-Null
    }

    return , @($violations.ToArray())
}

function Get-FindingCommandName {
    # Extracts the command name from a PSUseCompatibleCommands diagnostic message, which
    # always contains "command '<name>'".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $match = [regex]::Match($Message, "command '([^']+)'")
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return ''
}

function Get-FindingParameterName {
    # Extracts the parameter name from a PSUseCompatibleCommands diagnostic message, which
    # contains "parameter '<name>'" for parameter-level incompatibilities.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $match = [regex]::Match($Message, "parameter '([^']+)'")
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return ''
}

# --- Resolve configuration -------------------------------------------------------------

$allowlistPath = Join-Path -Path $scriptRoot -ChildPath "compatibility-allowlist.psd1"
$allowedCommandData = Get-AllowedCommandData -AllowlistPath $allowlistPath
$allowedExternalExecutables = @($allowedCommandData['ExternalExecutables'])
$allowedModuleCommands = @($allowedCommandData['ModuleCommands'])
$targetProfiles = Get-CompatibilityTargetProfile
$targets = Get-CompatibilityTargetFile -RootPath $Path -ExplicitFiles $TargetFiles

if ($targets.Count -eq 0) {
    if ($OutputFormat -eq 'json') {
        [pscustomobject]@{
            status        = 'skipped'
            reason        = 'no-targets'
            findingCount  = 0
            findings      = @()
        } | ConvertTo-Json -Depth 5
    } else {
        Write-Host "No PowerShell targets to check; skipping compatibility gate."
    }
    exit 0
}

$analyzerSettings = @{
    Rules = @{
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = $targetProfiles }
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = $targetProfiles }
    }
}

$compatibilityRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')

# --- Run analysis ----------------------------------------------------------------------

$realFindings = New-Object System.Collections.Generic.List[object]
$allowedFindingCount = 0
# Collapse the per-platform duplication PSScriptAnalyzer emits (one finding per target
# profile) into a single record keyed by file/line/rule and the platform-independent
# message prefix.
$seenKeys = New-Object System.Collections.Generic.HashSet[string]

function Add-RealFinding {
    param($Collection, $SeenKeys, $Record)

    $messagePrefix = $Record.message
    $byDefaultIndex = $messagePrefix.IndexOf(' by default in PowerShell version')
    if ($byDefaultIndex -ge 0) {
        $messagePrefix = $messagePrefix.Substring(0, $byDefaultIndex)
    }
    $key = "{0}|{1}|{2}|{3}" -f $Record.file, $Record.line, $Record.ruleName, $messagePrefix
    if ($SeenKeys.Add($key)) {
        $Collection.Add($Record)
    }
}

foreach ($target in $targets) {
    $findings = @(Invoke-ScriptAnalyzer -Path $target -IncludeRule $compatibilityRules -Settings $analyzerSettings -ErrorAction Stop)
    foreach ($finding in $findings) {
        if ($finding.RuleName -eq 'PSUseCompatibleCommands') {
            $commandName = Get-FindingCommandName -Message $finding.Message
            if (-not [string]::IsNullOrEmpty($commandName)) {
                # A parameter-level finding ("The parameter 'X' is not available for command
                # 'Y'...") is a REAL incompatibility for a built-in cmdlet, so external
                # executables only suppress the command-absence shape. Module-provided
                # commands (Pester DSL) suppress both shapes because the whole command is
                # supplied at runtime and works on both editions.
                $isParameterFinding = $finding.Message.TrimStart().StartsWith('The parameter ')
                $isModuleCommand = $allowedModuleCommands -contains $commandName
                $isExternalExecutable = $allowedExternalExecutables -contains $commandName
                $parameterName = ''
                if ($isParameterFinding) {
                    $parameterName = Get-FindingParameterName -Message $finding.Message
                }
                $isGuardedPSReadLinePredictionFinding = $false
                if ($isParameterFinding -and
                    $commandName -ieq 'Set-PSReadLineOption' -and
                    @('PredictionSource', 'PredictionViewStyle') -contains $parameterName) {
                    $isGuardedPSReadLinePredictionFinding = Test-PSReadLineCompatibilityFindingGuarded -Path $target -Line $finding.Line -ParameterName $parameterName
                }
                if ($isModuleCommand -or ($isExternalExecutable -and -not $isParameterFinding) -or $isGuardedPSReadLinePredictionFinding) {
                    $allowedFindingCount = $allowedFindingCount + 1
                    continue
                }
            }
        }

        $relativePath = $target
        if ($target.StartsWith($repositoryRoot)) {
            $relativePath = $target.Substring($repositoryRoot.Length).TrimStart([char[]]@('/', '\'))
        }
        $relativePath = $relativePath.Replace('\', '/')

        Add-RealFinding -Collection $realFindings -SeenKeys $seenKeys -Record ([pscustomobject]@{
                file     = $relativePath
                line     = $finding.Line
                ruleName = $finding.RuleName
                severity = [string]$finding.Severity
                message  = $finding.Message
            })
    }

    # Analyzer-invisible class: bare 5.1-undefined automatic variables.
    foreach ($violation in (Get-AutomaticVariableViolation -FilePath $target -RepositoryRoot $repositoryRoot)) {
        Add-RealFinding -Collection $realFindings -SeenKeys $seenKeys -Record $violation
    }

    # Analyzer-invisible class: Invoke-WebRequest missing -UseBasicParsing.
    foreach ($violation in (Get-WebRequestParsingViolation -FilePath $target -RepositoryRoot $repositoryRoot)) {
        Add-RealFinding -Collection $realFindings -SeenKeys $seenKeys -Record $violation
    }

    # Analyzer-invisible class: .NET Core-only instance members (ProcessStartInfo.ArgumentList,
    # FileSystemInfo.ResolveLinkTarget) that throw on Windows PowerShell 5.1.
    foreach ($violation in (Get-CoreOnlyMemberViolation -FilePath $target -RepositoryRoot $repositoryRoot)) {
        Add-RealFinding -Collection $realFindings -SeenKeys $seenKeys -Record $violation
    }
}

# --- Report ----------------------------------------------------------------------------

$sortedFindings = @($realFindings | Sort-Object -Property file, line)

function Stop-CompatibilityCheckProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    try {
        [Console]::Out.Flush()
        [Console]::Error.Flush()
    }
    catch {
        Write-Verbose "Compatibility check console flush failed before process exit: $($_.Exception.Message)"
    }

    $compatibilityCheckRunningOnWindows = ($PSVersionTable.PSEdition -eq 'Desktop' -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    if (-not $compatibilityCheckRunningOnWindows) {
        try {
            if ($null -eq ('WallstopCompatibilityNativeExit.Libc' -as [type])) {
                Add-Type -Namespace WallstopCompatibilityNativeExit -Name Libc -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "_exit")]
public static extern void _exit(int code);
'@
            }

            [WallstopCompatibilityNativeExit.Libc]::_exit($ExitCode)
        }
        catch {
            Write-Warning "W_COMPAT_FAST_EXIT_NATIVE_UNAVAILABLE: Fast native exit (libc _exit) is unavailable on this host; using managed exit instead. $($_.Exception.Message)"
        }
    }

    [System.Environment]::Exit($ExitCode)
}

if ($sortedFindings.Count -eq 0) {
    $resultStatus = 'pass'
} else {
    $resultStatus = 'fail'
}

if ($OutputFormat -eq 'json') {
    [pscustomobject]@{
        status              = $resultStatus
        targetCount         = $targets.Count
        targetProfiles      = $targetProfiles
        allowedFindingCount = $allowedFindingCount
        findingCount        = $sortedFindings.Count
        findings            = $sortedFindings
    } | ConvertTo-Json -Depth 6
} else {
    Write-Host "Cross-version compatibility gate (Windows PowerShell 5.1 + PowerShell 7+)"
    Write-Host "  Targets scanned : $($targets.Count)"
    Write-Host "  Profiles        : $([string]::Join(', ', $targetProfiles))"
    Write-Host "  Allowed (noise) : $allowedFindingCount finding(s) filtered via allowlist/suppression/structural guards"
    if ($sortedFindings.Count -eq 0) {
        Write-Host "  Result          : PASS - no cross-version incompatibilities detected."
    } else {
        Write-Host "  Result          : FAIL - $($sortedFindings.Count) incompatibilit(ies) detected:"
        foreach ($finding in $sortedFindings) {
            Write-Host ("    {0}:{1} [{2}] {3}" -f $finding.file, $finding.line, $finding.ruleName, $finding.message)
        }
    }
}

if ($sortedFindings.Count -gt 0) {
    $failureMessage = "E_COMPAT_INCOMPATIBILITY: $($sortedFindings.Count) cross-version incompatibilit(ies) detected. Fix in code (portable idiom) or add a justified SuppressMessageAttribute / allowlist entry."
    if ($NoExit) {
        Write-Error $failureMessage -ErrorAction Continue
        return
    }

    Write-Error $failureMessage -ErrorAction Continue
    Stop-CompatibilityCheckProcess -ExitCode 1
}

if (-not $NoExit) {
    Stop-CompatibilityCheckProcess -ExitCode 0
}
