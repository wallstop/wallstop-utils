<#
.SYNOPSIS
    Static cross-version compatibility gate for Windows PowerShell 5.1 <-> PowerShell 7+.

.DESCRIPTION
    Runs the PSScriptAnalyzer compatibility rules (PSUseCompatibleSyntax,
    PSUseCompatibleCommands, PSUseCompatibleTypes) against repository PowerShell sources
    targeting both Windows PowerShell 5.1 (Desktop / .NET Framework) and PowerShell 7+
    (Core). Any finding that is not a known false positive fails the gate with a stable
    E_COMPAT_INCOMPATIBILITY diagnostic.

    False positives are handled in exactly two sanctioned ways:
      - Inline [Diagnostics.CodeAnalysis.SuppressMessageAttribute] with a justification,
        for guarded native calls (honored natively by PSScriptAnalyzer).
      - The AllowedCommands list in compatibility-allowlist.psd1, for external
        executables and runtime-installed module commands (for example Pester 5).

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
    [string]$OutputFormat = 'text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
# Repo root is three levels up: Scripts/Utils/Quality -> repo root.
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $scriptRoot -ChildPath "../../..")).Path

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
                if ($isModuleCommand -or ($isExternalExecutable -and -not $isParameterFinding)) {
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
}

# --- Report ----------------------------------------------------------------------------

$sortedFindings = @($realFindings | Sort-Object -Property file, line)

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
    Write-Host "  Allowed (noise) : $allowedFindingCount finding(s) filtered via allowlist/suppression"
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
    Write-Error "E_COMPAT_INCOMPATIBILITY: $($sortedFindings.Count) cross-version incompatibilit(ies) detected. Fix in code (portable idiom) or add a justified SuppressMessageAttribute / allowlist entry."
    exit 1
}

exit 0
