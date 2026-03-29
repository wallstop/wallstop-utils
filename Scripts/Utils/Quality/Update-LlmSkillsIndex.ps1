[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Check,

    [Parameter(Mandatory = $false)]
    [string]$RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-RepositoryRoot {
    param(
        [Parameter(Mandatory = $false)]
        [string]$CandidateRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($CandidateRoot)) {
        return (Resolve-Path -Path $CandidateRoot -ErrorAction Stop).Path
    }

    return (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../../..")).Path
}

function ConvertTo-SkillTitle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $tokens = @($FileName -split '[-_]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tokens.Count -eq 0) {
        return $FileName
    }

    $textInfo = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    $parts = @()
    foreach ($token in $tokens) {
        $parts += $textInfo.ToTitleCase($token.ToLowerInvariant())
    }

    return ($parts -join ' ')
}

function ConvertTo-MarkdownTableValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return (($Value -replace '\|', '\\|').Trim())
}

function ConvertTo-PortablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ''
    }

    # Normalize all separators to POSIX-style so generated markdown is deterministic across OSes.
    return ($PathValue -replace '[\\/]+', '/')
}

function Normalize-ComparisonContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    if ($normalized.Length -eq 0) {
        return "`n"
    }

    # Keep a single trailing newline so comparisons do not depend on file EOF style.
    return ($normalized.TrimEnd("`n") + "`n")
}

function Get-StringSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
    }
}

function Find-FirstDifferentLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Actual
    )

    $expectedLines = @($Expected -split "`n", -1)
    $actualLines = @($Actual -split "`n", -1)
    $lineCount = [Math]::Max($expectedLines.Count, $actualLines.Count)

    for ($index = 0; $index -lt $lineCount; $index++) {
        $expectedLine = if ($index -lt $expectedLines.Count) { $expectedLines[$index] } else { '<missing>' }
        $actualLine = if ($index -lt $actualLines.Count) { $actualLines[$index] } else { '<missing>' }

        if ($expectedLine -cne $actualLine) {
            return [pscustomobject]@{
                LineNumber = $index + 1
                Expected   = $expectedLine
                Actual     = $actualLine
            }
        }
    }

    return $null
}

function ConvertTo-DiagnosticPreview {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $false)]
        [int]$MaxLength = 140
    )

    $preview = $Value.Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n')
    if ($preview.Length -le $MaxLength) {
        return $preview
    }

    return ($preview.Substring(0, $MaxLength) + '...')
}

function Get-SkillMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkillPath,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $content = [System.IO.File]::ReadAllText($SkillPath, [System.Text.Encoding]::UTF8)
    $triggerPattern = '<!--\s*trigger:\s*(?<keywords>[^|]+?)\s*\|\s*(?<description>[^|]+?)\s*\|\s*(?<category>[^|>]+?)\s*\|\s*(?<details>[^>]+?)\s*-->'
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $content,
        $triggerPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $SkillPath)
        throw "E_LLM_TRIGGER_METADATA_MISSING: Missing trigger metadata comment in '$relative'."
    }

    $category = $match.Groups['category'].Value.Trim()

    $relativePath = ConvertTo-PortablePath -PathValue ([System.IO.Path]::GetRelativePath($Root, $SkillPath))
    $skillLinkPath = $relativePath
    if ($skillLinkPath.StartsWith('.llm/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $skillLinkPath = $skillLinkPath.Substring(5)
    }

    $detailsPath = $match.Groups['details'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($detailsPath)) {
        $detailsPath = $skillLinkPath
    }
    $detailsPath = ConvertTo-PortablePath -PathValue $detailsPath
    if ($detailsPath.StartsWith('.llm/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $detailsPath = $detailsPath.Substring(5)
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SkillPath)

    return [pscustomobject]@{
        Name          = ConvertTo-SkillTitle -FileName $baseName
        RelativePath  = $relativePath
        SkillCardLink = "./$skillLinkPath"
        DetailsLink   = "./$detailsPath"
        Keywords      = ConvertTo-MarkdownTableValue -Value $match.Groups['keywords'].Value
        Description   = ConvertTo-MarkdownTableValue -Value $match.Groups['description'].Value
        Category      = ConvertTo-MarkdownTableValue -Value $category
    }
}

function New-GeneratedIndexLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Skills
    )

    $categoryOrder = @('Core', 'Quality', 'Platform', 'GitHub')
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('# Skills Index') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('This file is generated. Do not edit generated sections manually.') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('<!-- BEGIN GENERATED SKILLS INDEX -->') | Out-Null
    $lines.Add('<!-- Generated by Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1. Do not edit by hand. -->') | Out-Null

    $categories = @($Skills | ForEach-Object { $_.Category } | Sort-Object -Unique -Culture $script:InvariantCulture)
    $orderedCategories = New-Object System.Collections.Generic.List[string]

    foreach ($name in $categoryOrder) {
        if ($categories -contains $name) {
            $orderedCategories.Add($name) | Out-Null
        }
    }

    foreach ($name in $categories) {
        if ($orderedCategories -notcontains $name) {
            $orderedCategories.Add($name) | Out-Null
        }
    }

    $isFirstCategory = $true
    foreach ($category in $orderedCategories) {
        $categorySkills = @($Skills | Where-Object { $_.Category -eq $category } | Sort-Object Name, RelativePath -Culture $script:InvariantCulture)
        if ($categorySkills.Count -eq 0) {
            continue
        }

        if ($isFirstCategory) {
            $lines.Add('') | Out-Null
            $isFirstCategory = $false
        }
        $lines.Add("## $category") | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add('| Skill Card | Expanded Guide | Trigger Keywords | Usage |') | Out-Null
        $lines.Add('| --- | --- | --- | --- |') | Out-Null

        foreach ($skill in $categorySkills) {
            $lines.Add("| [$($skill.Name)]($($skill.SkillCardLink)) | [Expanded Guide]($($skill.DetailsLink)) | $($skill.Keywords) | $($skill.Description) |") | Out-Null
        }

        $lines.Add('') | Out-Null
    }

    if ($lines[$lines.Count - 1] -ne '') {
        $lines.Add('') | Out-Null
    }
    $lines.Add('<!-- END GENERATED SKILLS INDEX -->') | Out-Null

    return @($lines)
}

$repoRoot = Get-RepositoryRoot -CandidateRoot $RootPath
$indexPath = Join-Path -Path $repoRoot -ChildPath '.llm/skills-index.md'
$skillsRoot = Join-Path -Path $repoRoot -ChildPath '.llm/skills'

if (-not (Test-Path -Path $indexPath -PathType Leaf)) {
    throw "E_LLM_SKILLS_INDEX_MISSING: Required file not found at '$indexPath'."
}

if (-not (Test-Path -Path $skillsRoot -PathType Container)) {
    throw "E_LLM_SKILLS_DIR_MISSING: Required directory not found at '$skillsRoot'."
}

$skillFiles = @(
    Get-ChildItem -Path $skillsRoot -Filter '*.md' -File -Recurse -ErrorAction Stop |
    Sort-Object FullName -Culture $script:InvariantCulture
)

$skillEntries = New-Object System.Collections.Generic.List[object]
foreach ($skillFile in $skillFiles) {
    $skillEntries.Add((Get-SkillMetadata -SkillPath $skillFile.FullName -Root $repoRoot)) | Out-Null
}

$generatedLines = New-GeneratedIndexLines -Skills $skillEntries
$newIndexContent = (($generatedLines -join "`n") + "`n")
$currentIndexContent = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)

# Normalize line endings for cross-platform comparison (Windows checkout may add CR).
$normalizedNew = Normalize-ComparisonContent -Content $newIndexContent
$normalizedCurrent = Normalize-ComparisonContent -Content $currentIndexContent

if ($Check) {
    # Use ordinal equality to avoid culture-sensitive comparison drift across platforms.
    if (-not [string]::Equals($normalizedNew, $normalizedCurrent, [System.StringComparison]::Ordinal)) {
        $generatedHash = Get-StringSha256 -Value $normalizedNew
        $currentHash = Get-StringSha256 -Value $normalizedCurrent
        Write-Warning "W_LLM_INDEX_STALE_DIAGNOSTICS: normalized hashes differ (generated=$generatedHash current=$currentHash)."

        $generatedBackslashLinkCount = [regex]::Matches($normalizedNew, '\]\(\./[^)\r\n]*\\[^)\r\n]*\)').Count
        $currentBackslashLinkCount = [regex]::Matches($normalizedCurrent, '\]\(\./[^)\r\n]*\\[^)\r\n]*\)').Count
        Write-Warning "W_LLM_INDEX_LINK_SEPARATOR_DIAGNOSTICS: generatedBackslashLinks=$generatedBackslashLinkCount currentBackslashLinks=$currentBackslashLinkCount"

        $generatedHasBom = ($normalizedNew.Length -gt 0) -and ([int][char]$normalizedNew[0] -eq 0xFEFF)
        $currentHasBom = ($normalizedCurrent.Length -gt 0) -and ([int][char]$normalizedCurrent[0] -eq 0xFEFF)
        Write-Warning "W_LLM_INDEX_BOM_DIAGNOSTICS: generatedHasUtf8Bom=$generatedHasBom currentHasUtf8Bom=$currentHasBom"

        $mismatchSummary = ''
        $mismatch = Find-FirstDifferentLine -Expected $normalizedNew -Actual $normalizedCurrent
        if ($null -ne $mismatch) {
            $expectedPreview = ConvertTo-DiagnosticPreview -Value $mismatch.Expected
            $actualPreview = ConvertTo-DiagnosticPreview -Value $mismatch.Actual
            Write-Warning ("W_LLM_INDEX_STALE_FIRST_MISMATCH: line={0}; generated='{1}'; current='{2}'." -f $mismatch.LineNumber, $expectedPreview, $actualPreview)
            $mismatchSummary = (" firstMismatchLine={0}" -f $mismatch.LineNumber)
        }

        throw ("E_LLM_INDEX_STALE: Generated skills index is stale. Run Update-LlmSkillsIndex.ps1 and commit .llm/skills-index.md. generatedHash={0} currentHash={1}{2}" -f $generatedHash, $currentHash, $mismatchSummary)
    }

    Write-Host 'LLM skills index is up to date.'
    return
}

if ([string]::Equals($normalizedNew, $normalizedCurrent, [System.StringComparison]::Ordinal)) {
    Write-Host 'LLM skills index is already up to date.'
    return
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($indexPath, $newIndexContent, $utf8NoBom)
Write-Host "Updated generated skills index in $indexPath"
