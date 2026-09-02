[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RootPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1,2000)]
    [int]$MaxLines = 300,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1,2000)]
    [int]$WarningLines = 280
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$llmWrapperHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/LlmWrapperContractHelpers.ps1"
if (-not (Test-Path -Path $llmWrapperHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: LLM wrapper helper file not found at '$llmWrapperHelpersPath'."
}

.$llmWrapperHelpersPath

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -Path $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath'."
}

.$compatibilityHelpersPath

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

    $normalizedHeading = [regex]::Replace($HeadingText,'\[([^\]]+)\]\([^\)]+\)','$1')
    $normalizedHeading = [regex]::Replace($normalizedHeading,'</?[A-Za-z][^>]*>','')
    $normalizedHeading = $normalizedHeading -replace '`',''
    $normalizedHeading = $normalizedHeading.ToLowerInvariant()
    $normalizedHeading = [regex]::Replace($normalizedHeading,'[^a-z0-9 _-]','')
    $normalizedHeading = [regex]::Replace($normalizedHeading,'\s+','-')
    $normalizedHeading = [regex]::Replace($normalizedHeading,'-{2,}','-')
    $normalizedHeading = $normalizedHeading.Trim('-')

    if ([string]::IsNullOrWhiteSpace($normalizedHeading)) {
        return ''
    }

    $existingCount = 0
    if ($AnchorCounts.TryGetValue($normalizedHeading,[ref]$existingCount)) {
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

    foreach ($line in [System.IO.File]::ReadLines($MarkdownPath,[System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*(```|~~~)') {
            $inFencedCodeBlock = -not $inFencedCodeBlock
            continue
        }

        if ($inFencedCodeBlock) {
            continue
        }

        $headingMatch = [regex]::Match($line,'^\s{0,3}#{1,6}\s+(?<heading>.+?)\s*$')
        if (-not $headingMatch.Success) {
            continue
        }

        $headingText = $headingMatch.Groups['heading'].Value.Trim()
        $headingText = [regex]::Replace($headingText,'\s+#+\s*$','')

        $anchor = ConvertTo-MarkdownAnchor -HeadingText $headingText -AnchorCounts $anchorCounts
        if (-not [string]::IsNullOrWhiteSpace($anchor)) {
            $anchors.Add($anchor) | Out-Null
        }
    }

    return ,$anchors
}

function Test-IsPathWithinDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$CandidatePath
    )

    $relativePath = Get-RelativePathCompat -BasePath $BasePath -TargetPath $CandidatePath
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -eq '.') {
        return $true
    }

    if ($relativePath -eq '..') {
        return $false
    }

    $parentWithDirectorySeparator = "..$([System.IO.Path]::DirectorySeparatorChar)"
    $parentWithAltDirectorySeparator = "..$([System.IO.Path]::AltDirectorySeparatorChar)"

    return -not (
        $relativePath.StartsWith($parentWithDirectorySeparator,[System.StringComparison]::Ordinal) -or
        $relativePath.StartsWith($parentWithAltDirectorySeparator,[System.StringComparison]::Ordinal)
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

    return ($PathValue -replace '[\\/]+','/')
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

    $wrapperContent = [System.IO.File]::ReadAllText($wrapperPath,[System.Text.Encoding]::UTF8)
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
    $lineCount = [System.IO.File]::ReadAllLines($file.FullName,[System.Text.Encoding]::UTF8).Length
    $relativePath = Get-RelativePathCompat -BasePath $repoRoot -TargetPath $file.FullName

    if ($lineCount -gt $MaxLines) {
        $errors.Add("$relativePath exceeds max line limit ($lineCount > $MaxLines)") | Out-Null
        continue
    }

    if ($lineCount -gt $WarningLines) {
        $diagnostics.Add("$relativePath is near the line limit ($lineCount lines)") | Out-Null
    }
}

# Doc reference resolution policy: every repo-root-relative `.llm/...` inline path and every
# file-relative markdown link in .llm guidance docs must resolve on disk. The SKILL.md
# migration previously left stale `.llm/skills/<name>.md` references behind; this invariant
# keeps that class of drift from recurring silently. Scan scope is `.llm/**` only; wrapper
# files and README are not gated. Reference-style link definitions (`[a]: path`) and heading
# fragments on non-card links are intentionally out of scope. Inline code spans suppress
# link scans only when their content has no whitespace, so prose between stray backticks
# stays scanned. Accepted fail-open limitation: a comment marker inside an inline code span
# still flips comment state until the next `-->`.
$inlineLlmReferencePattern = '`(\.llm/[^`\r\n]+)`'
$markdownLinkPattern = '\]\((?<target>[^)\r\n]+)\)'
$inlineCodeSpanPattern = '`[^`\r\n]+`'
foreach ($file in $llmMarkdownFiles) {
    $relativePath = Get-RelativePathCompat -BasePath $repoRoot -TargetPath $file.FullName
    $fileDirectory = Split-Path -Path $file.FullName -Parent
    $inFencedCodeBlock = $false
    $inHtmlComment = $false
    $lineIndex = 0

    foreach ($line in [System.IO.File]::ReadLines($file.FullName,[System.Text.Encoding]::UTF8)) {
        $lineIndex++

        if ($line -match '^\s*(```|~~~)') {
            $inFencedCodeBlock = -not $inFencedCodeBlock
            continue
        }

        if ($inFencedCodeBlock) {
            continue
        }

        # Commented-out content is prose, not live references; track multi-line comments.
        $scannableLine = $line
        if ($inHtmlComment) {
            $commentEndIndex = $scannableLine.IndexOf('-->',[System.StringComparison]::Ordinal)
            if ($commentEndIndex -lt 0) {
                continue
            }

            $scannableLine = $scannableLine.Substring($commentEndIndex + 3)
            $inHtmlComment = $false
        }

        while ($true) {
            $commentStartIndex = $scannableLine.IndexOf('<!--',[System.StringComparison]::Ordinal)
            if ($commentStartIndex -lt 0) {
                break
            }

            $commentEndIndex = $scannableLine.IndexOf('-->',$commentStartIndex + 4,[System.StringComparison]::Ordinal)
            if ($commentEndIndex -lt 0) {
                $scannableLine = $scannableLine.Substring(0,$commentStartIndex)
                $inHtmlComment = $true
                break
            }

            $scannableLine = (
                $scannableLine.Substring(0,$commentStartIndex) +
                $scannableLine.Substring($commentEndIndex + 3)
            )
        }

        # Inline code spans stay in the line for the inline-path scan (they are
        # backtick-delimited) but suppress link scans when they contain no whitespace.
        $inlineCodeSpans = @(
            [regex]::Matches($scannableLine,$inlineCodeSpanPattern) |
                Where-Object { $_.Value.Substring(1,$_.Value.Length - 2) -notmatch '\s' }
        )

        foreach ($referenceMatch in [regex]::Matches($scannableLine,$inlineLlmReferencePattern)) {
            $referenceTarget = ConvertTo-PortablePath -PathValue $referenceMatch.Groups[1].Value.Trim()
            # Trim sentence punctuation that commonly lands inside closing backticks
            # (for example a comma in `` `.llm/foo.md`, ``). A trailing ')' is kept verbatim
            # so refs targeting paths that end with ')' (for example `` `.llm/foo (draft)` ``)
            # keep reporting their full target.
            $referenceTarget = ($referenceTarget -split '#')[0].Trim().TrimEnd('.,;:')
            if ($referenceTarget -match '[\*\$\[<]') {
                # Glob patterns and placeholder expressions are prose, not resolvable references.
                continue
            }

            if ([string]::IsNullOrWhiteSpace($referenceTarget)) {
                continue
            }

            if (-not (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $referenceTarget))) {
                $errors.Add("${relativePath}:$lineIndex E_LLM_DOC_REFERENCE_MISSING: inline path '$referenceTarget' does not exist.") | Out-Null
            }
        }

        foreach ($linkMatch in [regex]::Matches($scannableLine,$markdownLinkPattern)) {
            $isInsideInlineCode = $false
            foreach ($codeSpan in $inlineCodeSpans) {
                if ($linkMatch.Index -ge $codeSpan.Index -and
                    $linkMatch.Index -lt ($codeSpan.Index + $codeSpan.Length)) {
                    $isInsideInlineCode = $true
                    break
                }
            }

            if ($isInsideInlineCode) {
                continue
            }

            $linkTarget = $linkMatch.Groups['target'].Value.Trim()

            # Split the optional link title before unwrapping angle targets so the combined
            # `[label](<path> "title")` form resolves its path instead of failing on '<'.
            # Decoration stripping precedes the external-URI/anchor skip so wrapped URIs
            # like `[label](<https://example.com>)` stay out of filesystem resolution.
            $titleSeparatorIndex = $linkTarget.IndexOf(' "',[System.StringComparison]::Ordinal)
            if ($titleSeparatorIndex -ge 0) {
                $linkTarget = $linkTarget.Substring(0,$titleSeparatorIndex).Trim()
            }

            if ($linkTarget.StartsWith('<',[System.StringComparison]::Ordinal) -and $linkTarget.EndsWith('>',[System.StringComparison]::Ordinal)) {
                $linkTarget = $linkTarget.Substring(1,$linkTarget.Length - 2).Trim()
            }

            if ($linkTarget -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $linkTarget.StartsWith('#',[System.StringComparison]::Ordinal)) {
                # External URIs and same-document anchors are out of resolution scope.
                continue
            }

            $rawLinkTarget = ($linkTarget -split '#')[0].Trim()
            try {
                $linkTarget = ConvertTo-PortablePath -PathValue ([System.Uri]::UnescapeDataString($rawLinkTarget))
            }
            catch {
                # Undecodable escapes are malformed targets, not gate crashes.
                $errors.Add("${relativePath}:$lineIndex E_LLM_DOC_REFERENCE_MISSING: link target '$rawLinkTarget' does not exist.") | Out-Null
                continue
            }

            if ([string]::IsNullOrWhiteSpace($linkTarget)) {
                continue
            }

            if ($linkTarget.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
                # Decoded control/invalid characters are unresolvable by definition; fail
                # closed instead of silently skipping or aborting the scan.
                $errors.Add("${relativePath}:$lineIndex E_LLM_DOC_REFERENCE_MISSING: link target '$linkTarget' does not exist.") | Out-Null
                continue
            }

            try {
                $linkAbsolutePath = [System.IO.Path]::GetFullPath((Join-Path -Path $fileDirectory -ChildPath $linkTarget))
            }
            catch {
                # Platforms may reject characters their own path grammar disallows.
                $errors.Add("${relativePath}:$lineIndex E_LLM_DOC_REFERENCE_MISSING: link target '$linkTarget' does not exist.") | Out-Null
                continue
            }

            if (-not (Test-Path -LiteralPath $linkAbsolutePath)) {
                $errors.Add("${relativePath}:$lineIndex E_LLM_DOC_REFERENCE_MISSING: link target '$linkTarget' does not exist.") | Out-Null
            }
        }
    }
}

$skillFiles = @()
if (Test-Path -Path $skillsDir -PathType Container) {
    $skillFiles = @(
        Get-ChildItem -Path $skillsDir -Filter '*.md' -File -ErrorAction Stop |
            Sort-Object FullName
    )
}

$skillDirectories = @()
if (Test-Path -Path $skillsDir -PathType Container) {
    $skillDirectories = @(Get-ChildItem -Path $skillsDir -Directory -ErrorAction Stop | Sort-Object FullName)
}

# Agent Skills standard entrypoints are authoritative for discovery. Legacy cards are
# retained only as an optional compatibility input for old temporary harness fixtures.
$standardSkillFiles = @(
    $skillDirectories |
        ForEach-Object { Join-Path -Path $_.FullName -ChildPath 'SKILL.md' } |
        Where-Object { Test-Path -Path $_ -PathType Leaf } |
        Sort-Object
)
$missingStandardSkillDirectories = @(
    $skillDirectories |
        Where-Object { -not (Test-Path -Path (Join-Path -Path $_.FullName -ChildPath 'SKILL.md') -PathType Leaf) }
)
foreach ($missingDirectory in $missingStandardSkillDirectories) {
    $missingRelativePath = Get-RelativePathCompat -BasePath $repoRoot -TargetPath $missingDirectory.FullName
    $errors.Add("E_LLM_STANDARD_SKILL_ENTRYPOINT_MISSING: '$missingRelativePath' must contain SKILL.md.") | Out-Null
}
$skillCount = if ($skillDirectories.Count -gt 0) { $skillDirectories.Count } else { $skillFiles.Count }
if ($skillCount -lt 1) {
    $errors.Add("At least one standard skill entrypoint is required in .llm/skills (found $skillCount).") | Out-Null
}
elseif ($skillCount -lt 8 -or $skillCount -gt 20) {
    $diagnostics.Add("Skill count is outside the recommended range of 8-20 (found $skillCount).") | Out-Null
}
$diagnostics.Add("Skill metadata diagnostics: standardSkillFiles=$($standardSkillFiles.Count); legacyCards=$($skillFiles.Count)") | Out-Null
foreach ($standardSkillPath in $standardSkillFiles) {
    $standardRelativePath = Get-RelativePathCompat -BasePath $repoRoot -TargetPath $standardSkillPath
    $standardContent = [System.IO.File]::ReadAllText($standardSkillPath,[System.Text.Encoding]::UTF8)
    $frontMatter = [regex]::Match($standardContent,'(?s)^---\s*\r?\n(?<body>.*?)\r?\n---\s*\r?\n')
    if (-not $frontMatter.Success) {
        $errors.Add("$standardRelativePath must begin with YAML front matter.") | Out-Null
        continue
    }
    $nameMatch = [regex]::Match($frontMatter.Groups['body'].Value,'(?m)^name:\s*(?<name>[^\r\n]+)\s*$')
    $descriptionMatch = [regex]::Match($frontMatter.Groups['body'].Value,'(?m)^description:\s*(?<description>[^\r\n]+)\s*$')
    $directoryName = Split-Path -Path (Split-Path -Path $standardSkillPath -Parent) -Leaf
    if (-not $nameMatch.Success -or $nameMatch.Groups['name'].Value.Trim() -cne $directoryName -or
        $directoryName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        $errors.Add("$standardRelativePath must define a valid name matching its parent directory.") | Out-Null
    }
    if (-not $descriptionMatch.Success -or [string]::IsNullOrWhiteSpace($descriptionMatch.Groups['description'].Value.Trim())) {
        $errors.Add("$standardRelativePath must define a non-empty description.") | Out-Null
    }
    $standardLineCount = [System.IO.File]::ReadAllLines($standardSkillPath,[System.Text.Encoding]::UTF8).Length
    if ($standardLineCount -gt 250) {
        $errors.Add("$standardRelativePath exceeds the Agent Skills hard limit (250 lines; found $standardLineCount).") | Out-Null
    }

    $detailsMatch = [regex]::Match($frontMatter.Groups['body'].Value,'(?m)^\s*details:\s*(?<details>[^\r\n]+)\s*$')
    if (-not $detailsMatch.Success -or [string]::IsNullOrWhiteSpace($detailsMatch.Groups['details'].Value.Trim())) {
        $errors.Add("$standardRelativePath must define a non-empty details metadata path.") | Out-Null
        continue
    }

    $detailsValue = ConvertTo-PortablePath -PathValue $detailsMatch.Groups['details'].Value.Trim().Trim('"').Trim("'")
    $detailsAbsolutePath = [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Path $standardSkillPath -Parent) -ChildPath $detailsValue))
    if (-not (Test-IsPathWithinDirectory -BasePath $skillDetailsDir -CandidatePath $detailsAbsolutePath)) {
        $errors.Add("$standardRelativePath details path '$detailsValue' must remain within .llm/skill-details.") | Out-Null
    }
    elseif (-not (Test-Path -Path $detailsAbsolutePath -PathType Leaf)) {
        $errors.Add("$standardRelativePath references missing details file '$detailsValue'.") | Out-Null
    }

    if ($standardContent -notmatch '\(\.\./\.\./skill-details/.+?\.md\)') {
        $errors.Add("$standardRelativePath must link to an expanded guide in ../../skill-details.") | Out-Null
    }
}

$triggerPattern = '<!--\s*trigger:\s*(?<keywords>[^|]+?)\s*\|\s*(?<description>[^|]+?)\s*\|\s*(?<category>[^|>]+?)\s*\|\s*(?<details>[^>]+?)\s*-->'
$anchorLinkPattern = '\[[^\]]+\]\(\.\./skill-details/(?<detailsPath>(?:[^/#)\s]+/)*[^/#)\s]+\.md)#(?<anchor>[^)\s]+)\)'
$detailsAnchorsByPath = @{}
foreach ($skillFile in $skillFiles) {
    $skillContent = [System.IO.File]::ReadAllText($skillFile.FullName,[System.Text.Encoding]::UTF8)
    $relativePath = Get-RelativePathCompat -BasePath $repoRoot -TargetPath $skillFile.FullName

    $match = [regex]::Match($skillContent,$triggerPattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        $errors.Add("$relativePath is missing trigger metadata comment.") | Out-Null
        continue
    }

    $triggerDescription = $match.Groups['description'].Value.Trim()
    if (-not (Test-UsesCanonicalTriOsPhrase -Text $triggerDescription)) {
        $errors.Add("$relativePath trigger description must use the canonical phrase 'Windows, macOS, and Linux' when listing all three operating systems.") | Out-Null
    }

    $skillLineCount = [System.IO.File]::ReadAllLines($skillFile.FullName,[System.Text.Encoding]::UTF8).Length
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
    if ($normalizedDetails.StartsWith('.llm/',[System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedDetails = $normalizedDetails.Substring(5)
    }

    $detailsAbsolutePath = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath '.llm') -ChildPath $normalizedDetails
    if (-not (Test-Path -Path $detailsAbsolutePath -PathType Leaf)) {
        $errors.Add("$relativePath references missing details file '$detailsPathValue'.") | Out-Null
    }

    $anchorMatches = [regex]::Matches($skillContent,$anchorLinkPattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
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
    $contextContent = [System.IO.File]::ReadAllText($contextPath,[System.Text.Encoding]::UTF8)
    if ($contextContent -notmatch '\(\./skills-index\.md\)') {
        $errors.Add('.llm/context.md must link to .llm/skills-index.md.') | Out-Null
    }

    if (Test-Path -Path $dependabotConfigPath -PathType Leaf) {
        $dependabotContent = ([System.IO.File]::ReadAllText($dependabotConfigPath,[System.Text.Encoding]::UTF8)) -replace "`r",''
        $normalizedContext = $contextContent -replace "`r",''
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
            IntervalWeeklyCount = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent,'(?m)^\s*interval:\s*(?:"weekly"|weekly)\s*$')).Count
            DayMondayCount = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent,'(?m)^\s*day:\s*(?:"monday"|monday)\s*$')).Count
            Time0300Count = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent,'(?m)^\s*time:\s*(?:"03:00"|03:00)\s*$')).Count
            TimezoneUtcCount = @([System.Text.RegularExpressions.Regex]::Matches($dependabotContent,'(?m)^\s*timezone:\s*(?:"UTC"|UTC)\s*$')).Count
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
    $crossPlatformContent = ([System.IO.File]::ReadAllText($crossPlatformDetailsPath,[System.Text.Encoding]::UTF8)) -replace "`r",''
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
    $indexContent = [System.IO.File]::ReadAllText($skillsIndexPath,[System.Text.Encoding]::UTF8)
    $beginCount = [regex]::Matches($indexContent,'<!-- BEGIN GENERATED SKILLS INDEX -->').Count
    $endCount = [regex]::Matches($indexContent,'<!-- END GENERATED SKILLS INDEX -->').Count

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
