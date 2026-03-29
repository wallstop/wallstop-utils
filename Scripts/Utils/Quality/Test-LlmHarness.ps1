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

    $normalizedHeading = [regex]::Replace($HeadingText, '\[[^\]]+\]\([^\)]+\)', '$1')
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

function Get-WrapperContractEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContextFilePath
    )

    $entries = @()
    $inSection = $false

    foreach ($line in [System.IO.File]::ReadLines($ContextFilePath, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s{0,3}##\s+Wrapper Contract\s*$') {
            $inSection = $true
            continue
        }

        if ($inSection -and $line -match '^\s{0,3}##\s') {
            break
        }

        if ($inSection -and $line -match '^\s*-\s+`([^`]+)`') {
            $entries += $Matches[1]
        }
    }

    return $entries
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

$repoRoot = Get-RepositoryRoot -CandidateRoot $RootPath
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

$contextPath = Join-Path -Path $repoRoot -ChildPath '.llm/context.md'
$skillsIndexPath = Join-Path -Path $repoRoot -ChildPath '.llm/skills-index.md'
$skillsDir = Join-Path -Path $repoRoot -ChildPath '.llm/skills'
$skillDetailsDir = Join-Path -Path $repoRoot -ChildPath '.llm/skill-details'
$updateScriptPath = Join-Path -Path $repoRoot -ChildPath 'Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1'

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
    $llmMarkdownFiles = @(
        Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath '.llm') -Filter '*.md' -File -Recurse -ErrorAction Stop |
        Sort-Object FullName
    )
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
        $warnings.Add("$relativePath is near the line limit ($lineCount lines)") | Out-Null
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
    $warnings.Add("Skill count is outside the recommended range of 8-10 (found $($skillFiles.Count)).") | Out-Null
}

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

foreach ($warning in $warnings) {
    Write-Warning $warning
}

if ($errors.Count -gt 0) {
    throw ("E_LLM_HARNESS_VALIDATION_FAILED: {0}" -f ($errors -join '; '))
}

Write-Host 'LLM harness validation passed.'
