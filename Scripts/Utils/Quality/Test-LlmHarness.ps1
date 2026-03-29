[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RootPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 2000)]
    [int]$MaxLines = 300,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 2000)]
    [int]$WarningLines = 280
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$llmWrapperHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/LlmWrapperContractHelpers.ps1"
if (-not (Test-Path -Path $llmWrapperHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: LLM wrapper helper file not found at '$llmWrapperHelpersPath'."
}

. $llmWrapperHelpersPath

function Get-RepositoryRoot {
    param(
        [Parameter(Mandatory = $false)]
        [string]$CandidateRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($CandidateRoot)) {
        return (Resolve-Path -Path $CandidateRoot -ErrorAction Stop).Path
    }

    return (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../../..')).Path
}

function ConvertTo-MarkdownAnchor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HeadingText,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, int]]$AnchorCounts
    )

    $normalizedHeading = [regex]::Replace($HeadingText, '\[([^\]]+)\]\([^\)]+\)', '$1')
    $normalizedHeading = [regex]::Replace($normalizedHeading, '<[^>]+>', '')
    $normalizedHeading = $normalizedHeading -replace '`', ''
    $normalizedHeading = $normalizedHeading.ToLowerInvariant()
    $normalizedHeading = [regex]::Replace($normalizedHeading, '[^a-z0-9 _-]', '')
    $normalizedHeading = [regex]::Replace($normalizedHeading, '\s+', '-')
    $normalizedHeading = [regex]::Replace($normalizedHeading, '-{2,}', '-')
    $normalizedHeading = $normalizedHeading.Trim('-')

    if ([string]::IsNullOrWhiteSpace($normalizedHeading)) {
        return ''
    }

    $existingCount = 0
    if ($AnchorCounts.TryGetValue($normalizedHeading, [ref]$existingCount)) {
        $nextCount = $existingCount + 1
        $AnchorCounts[$normalizedHeading] = $nextCount
        return "$normalizedHeading-$nextCount"
    }

    $AnchorCounts[$normalizedHeading] = 0
    return $normalizedHeading
}

function Get-MarkdownHeadingAnchors {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MarkdownPath
    )

    $anchors = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $anchorCounts = New-Object 'System.Collections.Generic.Dictionary[string, int]' ([System.StringComparer]::Ordinal)
    $inFencedCodeBlock = $false

    foreach ($line in [System.IO.File]::ReadLines($MarkdownPath, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*(```|~~~)') {
            $inFencedCodeBlock = -not $inFencedCodeBlock
            continue
        }

        if ($inFencedCodeBlock) {
            continue
        }

        $headingMatch = [regex]::Match($line, '^\s{0,3}#{1,6}\s+(?<heading>.+?)\s*$')
        if (-not $headingMatch.Success) {
            continue
        }

        $headingText = $headingMatch.Groups['heading'].Value.Trim()
        $headingText = [regex]::Replace($headingText, '\s+#+\s*$', '')

        $anchor = ConvertTo-MarkdownAnchor -HeadingText $headingText -AnchorCounts $anchorCounts
        if (-not [string]::IsNullOrWhiteSpace($anchor)) {
            $anchors.Add($anchor) | Out-Null
        }
    }

    return , $anchors
}

function Test-IsPathWithinDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$CandidatePath
    )

    $relativePath = [System.IO.Path]::GetRelativePath($BasePath, $CandidatePath)
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -eq '.') {
        return $true
    }

    if ($relativePath -eq '..') {
        return $false
    }

    $parentWithDirectorySeparator = "..$([System.IO.Path]::DirectorySeparatorChar)"
    $parentWithAltDirectorySeparator = "..$([System.IO.Path]::AltDirectorySeparatorChar)"

    return -not (
        $relativePath.StartsWith($parentWithDirectorySeparator, [System.StringComparison]::Ordinal) -or
        $relativePath.StartsWith($parentWithAltDirectorySeparator, [System.StringComparison]::Ordinal)
    )
}

function ConvertTo-PortablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ''
    }

    return ($PathValue -replace '[\\/]+', '/')
}

function Test-UsesCanonicalTriOsPhrase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $hasWindows = $Text -match '(?i)\bwindows\b'
    $hasMacOs = $Text -match '(?i)\bmacos\b'
    $hasLinux = $Text -match '(?i)\blinux\b'
    if (-not ($hasWindows -and $hasMacOs -and $hasLinux)) {
        return $true
    }

    return $Text -match '(?i)\bwindows,\s*macos,\s*and\s+linux\b'
}

$repoRoot = Get-RepositoryRoot -CandidateRoot $RootPath
$errors = New-Object System.Collections.Generic.List[string]
$diagnostics = New-Object System.Collections.Generic.List[string]

$contextPath = Join-Path -Path $repoRoot -ChildPath '.llm/context.md'
$skillsIndexPath = Join-Path -Path $repoRoot -ChildPath '.llm/skills-index.md'
$skillsDir = Join-Path -Path $repoRoot -ChildPath '.llm/skills'
$skillDetailsDir = Join-Path -Path $repoRoot -ChildPath '.llm/skill-details'
$updateScriptPath = Join-Path -Path $repoRoot -ChildPath 'Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1'
$dependabotConfigPath = Join-Path -Path $repoRoot -ChildPath '.github/dependabot.yml'
$crossPlatformDetailsPath = Join-Path -Path $repoRoot -ChildPath '.llm/skill-details/cross-platform-powershell.md'

if (-not (Test-Path -Path $contextPath -PathType Leaf)) {
    $errors.Add("Missing required context file: .llm/context.md") | Out-Null
}

if (-not (Test-Path -Path $skillsIndexPath -PathType Leaf)) {
    $errors.Add("Missing required generated index file: .llm/skills-index.md") | Out-Null
}

if (-not (Test-Path -Path $skillsDir -PathType Container)) {
    $errors.Add("Missing required skills directory: .llm/skills") | Out-Null
}

if (-not (Test-Path -Path $skillDetailsDir -PathType Container)) {
    $errors.Add("Missing required skill details directory: .llm/skill-details") | Out-Null
}

$requiredWrappers = @()
if (Test-Path -Path $contextPath -PathType Leaf) {
    $requiredWrappers = @(Get-WrapperContractEntries -ContextFilePath $contextPath)
    if ($requiredWrappers.Count -eq 0) {
        $errors.Add("Wrapper Contract section in .llm/context.md lists no wrapper files.") | Out-Null
    }
}

$diagnostics.Add((
        "Wrapper contract diagnostics: wrapperCount={0}; wrappers={1}" -f
        $requiredWrappers.Count,
        ($requiredWrappers -join ',')
    )) | Out-Null

foreach ($wrapper in $requiredWrappers) {
    $wrapperPath = Join-Path -Path $repoRoot -ChildPath $wrapper
    if (-not (Test-Path -Path $wrapperPath -PathType Leaf)) {
        $errors.Add("Missing required wrapper file: $wrapper") | Out-Null
        continue
    }

    $wrapperContent = [System.IO.File]::ReadAllText($wrapperPath, [System.Text.Encoding]::UTF8)
    if ($wrapperContent -notmatch '(?i)\.llm/context\.md') {
        $errors.Add("Wrapper file '$wrapper' does not point to .llm/context.md") | Out-Null
    }
}

$llmMarkdownFiles = @()
if (Test-Path -Path (Join-Path -Path $repoRoot -ChildPath '.llm') -PathType Container) {
    $llmScanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $llmMarkdownFiles = @(
        Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath '.llm') -Filter '*.md' -File -Recurse -ErrorAction Stop |
        Sort-Object FullName
    )
    $llmScanStopwatch.Stop()
    $diagnostics.Add((
            "LLM markdown scan diagnostics: files={0}; elapsedMs={1}; maxLines={2}; warningLines={3}" -f
            $llmMarkdownFiles.Count,
            $llmScanStopwatch.ElapsedMilliseconds,
            $MaxLines,
            $WarningLines
        )) | Out-Null
}

if ($llmMarkdownFiles.Count -eq 0) {
    $errors.Add('No markdown files found under .llm directory.') | Out-Null
}

foreach ($file in $llmMarkdownFiles) {
    $lineCount = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8).Length
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)

    if ($lineCount -gt $MaxLines) {
        $errors.Add("$relativePath exceeds max line limit ($lineCount > $MaxLines)") | Out-Null
        continue
    }

    if ($lineCount -gt $WarningLines) {
        $diagnostics.Add("$relativePath is near the line limit ($lineCount lines)") | Out-Null
    }
}

$skillFiles = @()
if (Test-Path -Path $skillsDir -PathType Container) {
    $skillFiles = @(
        Get-ChildItem -Path $skillsDir -Filter '*.md' -File -Recurse -ErrorAction Stop |
        Sort-Object FullName
    )
}

if ($skillFiles.Count -lt 1) {
    $errors.Add("At least one skill card is required in .llm/skills (found $($skillFiles.Count)).") | Out-Null
}
elseif ($skillFiles.Count -lt 8 -or $skillFiles.Count -gt 10) {
    $diagnostics.Add("Skill count is outside the recommended range of 8-10 (found $($skillFiles.Count)).") | Out-Null
}

$diagnostics.Add("Skill metadata diagnostics: skillFiles=$($skillFiles.Count)") | Out-Null

$triggerPattern = '<!--\s*trigger:\s*(?<keywords>[^|]+?)\s*\|\s*(?<description>[^|]+?)\s*\|\s*(?<category>[^|>]+?)\s*\|\s*(?<details>[^>]+?)\s*-->'
$anchorLinkPattern = '\[[^\]]+\]\(\.\./skill-details/(?<detailsPath>(?:[^/#)\s]+/)*[^/#)\s]+\.md)#(?<anchor>[^)\s]+)\)'
$detailsAnchorsByPath = @{}
foreach ($skillFile in $skillFiles) {
    $skillContent = [System.IO.File]::ReadAllText($skillFile.FullName, [System.Text.Encoding]::UTF8)
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $skillFile.FullName)

    $match = [regex]::Match($skillContent, $triggerPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        $errors.Add("$relativePath is missing trigger metadata comment.") | Out-Null
        continue
    }

    $triggerDescription = $match.Groups['description'].Value.Trim()
    if (-not (Test-UsesCanonicalTriOsPhrase -Text $triggerDescription)) {
        $errors.Add("$relativePath trigger description must use the canonical phrase 'Windows, macOS, and Linux' when listing all three operating systems.") | Out-Null
    }

    $skillLineCount = [System.IO.File]::ReadAllLines($skillFile.FullName, [System.Text.Encoding]::UTF8).Length
    if ($skillLineCount -gt 80) {
        $errors.Add("$relativePath should remain lightweight (<= 80 lines, found $skillLineCount).") | Out-Null
    }

    if ($skillContent -notmatch '\(\.\./skill-details/.+?\.md\)') {
        $errors.Add("$relativePath must link to an expanded guide in ../skill-details.") | Out-Null
    }

    $detailsPathValue = $match.Groups['details'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($detailsPathValue)) {
        $errors.Add("$relativePath trigger metadata must include a details path field.") | Out-Null
        continue
    }

    $normalizedDetails = ConvertTo-PortablePath -PathValue $detailsPathValue
    if ($normalizedDetails.StartsWith('.llm/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedDetails = $normalizedDetails.Substring(5)
    }

    $detailsAbsolutePath = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath '.llm') -ChildPath $normalizedDetails
    if (-not (Test-Path -Path $detailsAbsolutePath -PathType Leaf)) {
        $errors.Add("$relativePath references missing details file '$detailsPathValue'.") | Out-Null
    }

    $anchorMatches = [regex]::Matches($skillContent, $anchorLinkPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($anchorMatch in $anchorMatches) {
        $detailsPath = [System.Uri]::UnescapeDataString($anchorMatch.Groups['detailsPath'].Value.Trim())
        $detailsPath = ConvertTo-PortablePath -PathValue $detailsPath
        $detailsRelativePath = "../skill-details/$detailsPath"
        $detailsAnchor = [System.Uri]::UnescapeDataString($anchorMatch.Groups['anchor'].Value.Trim())

        if ([string]::IsNullOrWhiteSpace($detailsAnchor)) {
            $errors.Add("$relativePath contains an empty heading anchor for '$detailsRelativePath'.") | Out-Null
            continue
        }

        $detailsPathSegments = @($detailsPath -split '/')
        if ($detailsPathSegments -contains '.' -or $detailsPathSegments -contains '..') {
            $errors.Add("$relativePath E_LLM_SKILL_ANCHOR_SCOPE_VIOLATION: anchor link details path '$detailsRelativePath' must stay within ../skill-details.") | Out-Null
            continue
        }

        $detailsLinkAbsolutePath = [System.IO.Path]::GetFullPath((Join-Path -Path $skillDetailsDir -ChildPath $detailsPath))
        if (-not (Test-IsPathWithinDirectory -BasePath $skillDetailsDir -CandidatePath $detailsLinkAbsolutePath)) {
            $errors.Add("$relativePath E_LLM_SKILL_ANCHOR_SCOPE_VIOLATION: anchor link details path '$detailsRelativePath' must stay within ../skill-details.") | Out-Null
            continue
        }

        if (-not (Test-Path -Path $detailsLinkAbsolutePath -PathType Leaf)) {
            $errors.Add("$relativePath references missing details file '$detailsRelativePath' in an anchor link.") | Out-Null
            continue
        }

        if (-not $detailsAnchorsByPath.ContainsKey($detailsLinkAbsolutePath)) {
            $detailsAnchorsByPath[$detailsLinkAbsolutePath] = Get-MarkdownHeadingAnchors -MarkdownPath $detailsLinkAbsolutePath
        }

        $knownAnchors = $detailsAnchorsByPath[$detailsLinkAbsolutePath]
        if (-not $knownAnchors.Contains($detailsAnchor)) {
            $errors.Add("$relativePath E_LLM_SKILL_ANCHOR_MISSING: links to missing heading '#$detailsAnchor' in '$detailsRelativePath'.") | Out-Null
        }
    }
}

if (Test-Path -Path $contextPath -PathType Leaf) {
    $contextContent = [System.IO.File]::ReadAllText($contextPath, [System.Text.Encoding]::UTF8)
    if ($contextContent -notmatch '\(\./skills-index\.md\)') {
        $errors.Add('.llm/context.md must link to .llm/skills-index.md.') | Out-Null
    }

    if (Test-Path -Path $dependabotConfigPath -PathType Leaf) {
        $dependabotContent = ([System.IO.File]::ReadAllText($dependabotConfigPath, [System.Text.Encoding]::UTF8)) -replace "`r", ''
        $normalizedContext = $contextContent -replace "`r", ''
        $ecosystemMatches = [System.Text.RegularExpressions.Regex]::Matches(
            $dependabotContent,
            '(?m)^\s*-\s*package-ecosystem:\s*"?(?<name>[A-Za-z0-9-]+)"?\s*$'
        )
        $configuredEcosystems = @(
            $ecosystemMatches |
            ForEach-Object { $_.Groups['name'].Value } |
            Sort-Object -Unique
        )

        $scheduleDiagnostics = @{
            IntervalWeeklyCount = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent, '(?m)^\s*interval:\s*(?:"weekly"|weekly)\s*$')).Count
            DayMondayCount      = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent, '(?m)^\s*day:\s*(?:"monday"|monday)\s*$')).Count
            Time0300Count       = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent, '(?m)^\s*time:\s*(?:"03:00"|03:00)\s*$')).Count
            TimezoneUtcCount    = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent, '(?m)^\s*timezone:\s*(?:"UTC"|UTC)\s*$')).Count
        }
        $usesPerUpdateTypeGroups = (
            $dependabotContent -match '(?m)^\s*applies-to:\s*(?:"version-updates"|version-updates)\s*$' -and
            $dependabotContent -match '(?m)^\s*applies-to:\s*(?:"security-updates"|security-updates)\s*$'
        )

        $dependabotDiagnostic = (
            "Dependabot/context diagnostics: ecosystems={0}; schedule={1}/{2}/{3}/{4}; groupedByUpdateType={5}" -f
            ($configuredEcosystems -join ','),
            $scheduleDiagnostics.IntervalWeeklyCount,
            $scheduleDiagnostics.DayMondayCount,
            $scheduleDiagnostics.Time0300Count,
            $scheduleDiagnostics.TimezoneUtcCount,
            $usesPerUpdateTypeGroups
        )
        $diagnostics.Add($dependabotDiagnostic) | Out-Null

        foreach ($ecosystem in $configuredEcosystems) {
            $ecosystemPattern = '(?i)(?<![A-Za-z0-9-])' + [System.Text.RegularExpressions.Regex]::Escape($ecosystem) + '(?![A-Za-z0-9-])'
            if ($normalizedContext -notmatch $ecosystemPattern) {
                $errors.Add(".llm/context.md must mention Dependabot ecosystem '$ecosystem' declared in .github/dependabot.yml") | Out-Null
            }
        }

        if ($usesPerUpdateTypeGroups -and $normalizedContext -notmatch '(?i)per\s+update\s+type') {
            $errors.Add('.llm/context.md must state that grouped Dependabot PRs are per update type when both version-updates and security-updates groups are configured.') | Out-Null
        }

        $isUniformCanonicalSchedule = (
            $configuredEcosystems.Count -gt 0 -and
            $scheduleDiagnostics.IntervalWeeklyCount -eq $configuredEcosystems.Count -and
            $scheduleDiagnostics.DayMondayCount -eq $configuredEcosystems.Count -and
            $scheduleDiagnostics.Time0300Count -eq $configuredEcosystems.Count -and
            $scheduleDiagnostics.TimezoneUtcCount -eq $configuredEcosystems.Count
        )
        if ($isUniformCanonicalSchedule -and $normalizedContext -notmatch '(?i)monday\D+03:00\D+utc') {
            $errors.Add('.llm/context.md must document the canonical Dependabot cadence (Monday 03:00 UTC) while that schedule remains configured.') | Out-Null
        }
    }
}

if (Test-Path -Path $crossPlatformDetailsPath -PathType Leaf) {
    $crossPlatformContent = ([System.IO.File]::ReadAllText($crossPlatformDetailsPath, [System.Text.Encoding]::UTF8)) -replace "`r", ''
    $windowsOnlySectionMatch = [System.Text.RegularExpressions.Regex]::Match(
        $crossPlatformContent,
        '(?ms)^##\s+Avoiding\s+Windows-Only\s+APIs\s+And\s+Commands\s*$\n(?<section>.*?)(?=^##\s|\z)'
    )
    $windowsOnlySection = if ($windowsOnlySectionMatch.Success) { $windowsOnlySectionMatch.Groups['section'].Value } else { '' }
    $legacyNoExistHeader = $windowsOnlySection -match '(?im)^Commands and APIs that do not exist on Linux/macOS:\s*$'
    $hasGetWmiWindowsOnly = $windowsOnlySection -match '(?im)^\|\s*`Get-WmiObject`[^|\r\n]*Windows-only[^|\r\n]*\|'
    $hasGetCimProviderLanguage = $windowsOnlySection -match '(?im)^\|\s*`Get-CimInstance`[^|\r\n]*(provider-dependent|limited)[^|\r\n]*\|[^|\r\n]*(provider-dependent|providers?/data\s+are\s+often\s+limited|providers?\s+are\s+often\s+limited|provider[^|\r\n]*(limited|availability|support))'
    $hasCimProviderCaveat = $hasGetWmiWindowsOnly -and $hasGetCimProviderLanguage
    $hasCombinedWmiCimTableRow = $windowsOnlySection -match '(?im)^\|\s*`Get-WmiObject`\s*/\s*`Get-CimInstance`\s*\|'
    $diagnostics.Add((
            "Cross-platform command availability diagnostics: hasWindowsOnlySection={0}; legacyNoExistHeader={1}; hasGetWmiWindowsOnly={2}; hasGetCimProviderLanguage={3}; hasCimProviderCaveat={4}; hasCombinedWmiCimTableRow={5}" -f
            $windowsOnlySectionMatch.Success,
            $legacyNoExistHeader,
            $hasGetWmiWindowsOnly,
            $hasGetCimProviderLanguage,
            $hasCimProviderCaveat,
            $hasCombinedWmiCimTableRow
        )) | Out-Null

    if (-not $windowsOnlySectionMatch.Success) {
        $errors.Add('.llm/skill-details/cross-platform-powershell.md is missing the Avoiding Windows-Only APIs And Commands section expected by portability policy.') | Out-Null
    }

    if ($legacyNoExistHeader) {
        $errors.Add('.llm/skill-details/cross-platform-powershell.md uses overly broad availability wording. Prefer Windows-only or Windows-specific behavior wording with caveats.') | Out-Null
    }

    if (-not $hasCimProviderCaveat) {
        $errors.Add('.llm/skill-details/cross-platform-powershell.md must clarify that Get-WmiObject is Windows-only and Get-CimInstance on non-Windows is provider-dependent/limited.') | Out-Null
    }

    if ($hasCombinedWmiCimTableRow) {
        $errors.Add('.llm/skill-details/cross-platform-powershell.md must not combine Get-WmiObject and Get-CimInstance in the same Windows-only table row; document separate guidance to avoid availability ambiguity.') | Out-Null
    }

    if ($crossPlatformContent -match '(?i)default\s+HFS\+') {
        $errors.Add('.llm/skill-details/cross-platform-powershell.md uses outdated macOS default filesystem wording (default HFS+). Use APFS default wording instead.') | Out-Null
    }

    $caseSensitivitySectionMatch = [System.Text.RegularExpressions.Regex]::Match(
        $crossPlatformContent,
        '(?ms)^##\s+Case\s+Sensitivity\s+And\s+File\s+System\s+Differences\s*$\n(?<section>.*?)(?=^##\s|\z)'
    )
    if (-not $caseSensitivitySectionMatch.Success) {
        $errors.Add('.llm/skill-details/cross-platform-powershell.md is missing the Case Sensitivity And File System Differences section expected by portability policy.') | Out-Null
    }
    else {
        $caseSensitivitySection = $caseSensitivitySectionMatch.Groups['section'].Value
        if ($caseSensitivitySection -notmatch '(?i)\bAPFS\b') {
            $errors.Add('.llm/skill-details/cross-platform-powershell.md must reference APFS in the Case Sensitivity And File System Differences section for modern macOS guidance.') | Out-Null
        }
    }
}

if (Test-Path -Path $skillsIndexPath -PathType Leaf) {
    $indexContent = [System.IO.File]::ReadAllText($skillsIndexPath, [System.Text.Encoding]::UTF8)
    $beginCount = [regex]::Matches($indexContent, '<!-- BEGIN GENERATED SKILLS INDEX -->').Count
    $endCount = [regex]::Matches($indexContent, '<!-- END GENERATED SKILLS INDEX -->').Count

    if ($beginCount -ne 1 -or $endCount -ne 1) {
        $errors.Add('.llm/skills-index.md must contain exactly one BEGIN/END generated index sentinel pair.') | Out-Null
    }
}

if (-not (Test-Path -Path $updateScriptPath -PathType Leaf)) {
    $errors.Add('Missing required index generator script: Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1') | Out-Null
}
else {
    try {
        & $updateScriptPath -RootPath $repoRoot -Check
    }
    catch {
        $errors.Add("Index check failed: $($_.Exception.Message)") | Out-Null
    }
}

foreach ($diagnostic in $diagnostics) {
    Write-Verbose $diagnostic
}

if ($errors.Count -gt 0) {
    throw ("E_LLM_HARNESS_VALIDATION_FAILED: {0}" -f ($errors -join '; '))
}

Write-Host 'LLM harness validation passed.'
