Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
    $script:contextPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/context.md'
    $script:skillsIndexPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/skills-index.md'
    $script:skillsDir = Join-Path -Path $script:repoRoot -ChildPath '.llm/skills'
    $script:skillDetailsDir = Join-Path -Path $script:repoRoot -ChildPath '.llm/skill-details'
    $script:validatorPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Test-LlmHarness.ps1'
    $script:indexUpdaterPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1'

    # Helper: remove temp directories reliably on Windows where file handles may linger.
    $script:RemoveTempRoot = {
        param([string]$Path)
        if (-not (Test-Path -Path $Path)) { return }
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        }
        catch {
            # Windows may hold file handles after script execution; wait for GC and retry.
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 200
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Derive wrapper list from context.md (single source of truth) instead of hardcoding.
    $script:wrapperFiles = @()
    $inSection = $false
    foreach ($line in [System.IO.File]::ReadLines($script:contextPath)) {
        if ($line -match '^\s{0,3}##\s+Wrapper Contract\s*$') {
            $inSection = $true
            continue
        }
        if ($inSection -and $line -match '^\s{0,3}##\s') {
            break
        }
        if ($inSection -and $line -match '^\s*-\s+`([^`]+)`') {
            $script:wrapperFiles += $Matches[1]
        }
    }

    # Helper: generate fixture context.md content with Wrapper Contract section.
    $script:fixtureContextContent = "# Context`n`nSee [Skills Index](./skills-index.md).`n`n## Wrapper Contract`n`nThe following wrapper files are thin pointers and must remain non-authoritative:`n`n"
    foreach ($w in $script:wrapperFiles) {
        $script:fixtureContextContent += "- ``$w```n"
    }
    $script:fixtureContextContent += "`n## End`n"
}

Describe "LLM harness structure" {
    It "keeps authoritative context that points to dedicated skills index" {
        Test-Path -Path $script:contextPath -PathType Leaf | Should -BeTrue
        Test-Path -Path $script:skillsIndexPath -PathType Leaf | Should -BeTrue

        $content = Get-Content -Path $script:contextPath -Raw
        $content | Should -Match '\(\./skills-index\.md\)'

        $indexContent = Get-Content -Path $script:skillsIndexPath -Raw
        ([regex]::Matches($indexContent, '<!-- BEGIN GENERATED SKILLS INDEX -->')).Count | Should -Be 1
        ([regex]::Matches($indexContent, '<!-- END GENERATED SKILLS INDEX -->')).Count | Should -Be 1
    }

    It "keeps wrapper files as pointers to .llm/context.md" {
        $script:wrapperFiles.Count | Should -BeGreaterOrEqual 1 -Because "Wrapper Contract section must list at least one file"
        foreach ($wrapper in $script:wrapperFiles) {
            $wrapperPath = Join-Path -Path $script:repoRoot -ChildPath $wrapper
            Test-Path -Path $wrapperPath -PathType Leaf | Should -BeTrue -Because "$wrapper must exist"

            $content = Get-Content -Path $wrapperPath -Raw
            $content | Should -Match '(?i)\.llm/context\.md' -Because "$wrapper must point to .llm/context.md"
        }
    }

    It "keeps lightweight skill cards with trigger metadata and expanded guides" {
        $skillFiles = @(
            Get-ChildItem -Path $script:skillsDir -Filter '*.md' -File -Recurse -ErrorAction Stop |
            Sort-Object FullName
        )
        $skillDetailFiles = @(
            Get-ChildItem -Path $script:skillDetailsDir -Filter '*.md' -File -Recurse -ErrorAction Stop |
            Sort-Object FullName
        )

        $skillFiles.Count | Should -BeGreaterOrEqual 1
        $skillDetailFiles.Count | Should -BeGreaterOrEqual $skillFiles.Count

        $triggerPattern = '<!--\s*trigger:\s*(?<keywords>[^|]+?)\s*\|\s*(?<description>[^|]+?)\s*\|\s*(?<category>[^|>]+?)\s*\|\s*(?<details>[^>]+?)\s*-->'
        foreach ($skillFile in $skillFiles) {
            $content = Get-Content -Path $skillFile.FullName -Raw
            $match = [regex]::Match($content, $triggerPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $match.Success | Should -BeTrue -Because "$($skillFile.Name) must include trigger metadata"
            $content | Should -Match '\(\.\./skill-details/.+?\.md\)' -Because "$($skillFile.Name) must link to expanded guide"

            $lineCount = [System.IO.File]::ReadAllLines($skillFile.FullName).Length
            $lineCount | Should -BeLessOrEqual 80 -Because "$($skillFile.Name) must remain lightweight"

            $detailsPath = $match.Groups['details'].Value.Trim().Replace('\\', '/')
            if ($detailsPath.StartsWith('.llm/', [System.StringComparison]::OrdinalIgnoreCase)) {
                $detailsPath = $detailsPath.Substring(5)
            }

            $detailsAbsolutePath = Join-Path -Path (Join-Path -Path $script:repoRoot -ChildPath '.llm') -ChildPath $detailsPath
            Test-Path -Path $detailsAbsolutePath -PathType Leaf | Should -BeTrue -Because "$($skillFile.Name) details path must exist"
        }

        foreach ($detailsFile in $skillDetailFiles) {
            $lineCount = [System.IO.File]::ReadAllLines($detailsFile.FullName).Length
            $lineCount | Should -BeLessOrEqual 300 -Because "$($detailsFile.Name) must remain within 300 lines"
        }
    }

    It "keeps generated index markdown structure deterministic" {
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $indexContent = (Get-Content -Path $script:skillsIndexPath -Raw) -replace "`r", ''

        $indexContent | Should -Match '(?m)^# Skills Index$'
        $indexContent | Should -Match '(?m)^##\s+Core$'
        $indexContent | Should -Match '(?m)^\| Skill Card \| Expanded Guide \| Trigger Keywords \| Usage \|$'
        $indexContent | Should -Match '(?m)^\| --- \| --- \| --- \| --- \|$'
        $indexContent | Should -Match '(?m)^\| \[.+\]\(\./skills/.+\.md\) \| \[Expanded Guide\]\(\./skill-details/.+\.md\) \|'

        $trailingWhitespace = @($indexContent -split "`n" | Where-Object { $_ -match '\s+$' })
        $trailingWhitespace.Count | Should -Be 0 -Because 'generated index should not include trailing whitespace'
    }
}

Describe "LLM harness automation" {
    It "keeps generated index check passing" {
        { & $script:indexUpdaterPath -RootPath $script:repoRoot -Check } | Should -Not -Throw
    }

    It "keeps validator passing with hard line limits" {
        { & $script:validatorPath -RootPath $script:repoRoot -MaxLines 300 -WarningLines 280 } | Should -Not -Throw
    }

    It "fails validation when a skill card anchor does not resolve to a details heading" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("llm-harness-{0}" -f ([System.Guid]::NewGuid().ToString('N')))
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        try {
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath '.llm/skills') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath '.llm/skill-details') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath 'Scripts/Utils/Quality') -ItemType Directory -Force | Out-Null

            foreach ($wrapper in $script:wrapperFiles) {
                $wrapperPath = Join-Path -Path $tempRoot -ChildPath $wrapper
                $wrapperDir = Split-Path -Path $wrapperPath -Parent
                New-Item -Path $wrapperDir -ItemType Directory -Force | Out-Null
                [System.IO.File]::WriteAllText($wrapperPath, '# Wrapper`n`nSee .llm/context.md.`n', $utf8NoBom)
            }

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $tempRoot -ChildPath '.llm/context.md'),
                $script:fixtureContextContent,
                $utf8NoBom
            )
            [System.IO.File]::WriteAllText((Join-Path -Path $tempRoot -ChildPath '.llm/skills-index.md'), '# Skills Index`n', $utf8NoBom)

            $skillCardContent = @"
<!-- trigger: test anchor, deterministic validation | Validate skill anchor enforcement | Core | skill-details/example-detail.md -->
# Example Skill

- Expanded guide: [Example Detail](../skill-details/example-detail.md)

## Core concepts

- [Broken anchor](../skill-details/example-detail.md#missing-heading)
"@
            [System.IO.File]::WriteAllText((Join-Path -Path $tempRoot -ChildPath '.llm/skills/example-skill.md'), $skillCardContent, $utf8NoBom)
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $tempRoot -ChildPath '.llm/skill-details/example-detail.md'),
                "# Example Detail`n`n## Existing Heading`n",
                $utf8NoBom
            )

            $tempUpdaterPath = Join-Path -Path $tempRoot -ChildPath 'Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1'
            Copy-Item -Path $script:indexUpdaterPath -Destination $tempUpdaterPath -Force
            & $tempUpdaterPath -RootPath $tempRoot

            $validationFailure = $null
            try {
                & $script:validatorPath -RootPath $tempRoot
            }
            catch {
                $validationFailure = $_
            }

            $validationFailure | Should -Not -BeNullOrEmpty
            $validationFailure.Exception.Message | Should -Match '(?i)E_LLM_SKILL_ANCHOR_MISSING'
        }
        finally {
            & $script:RemoveTempRoot $tempRoot
        }
    }

    It "supports nested details paths in skill anchor links" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("llm-harness-{0}" -f ([System.Guid]::NewGuid().ToString('N')))
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        try {
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath '.llm/skills') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath '.llm/skill-details/nested') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath 'Scripts/Utils/Quality') -ItemType Directory -Force | Out-Null

            foreach ($wrapper in $script:wrapperFiles) {
                $wrapperPath = Join-Path -Path $tempRoot -ChildPath $wrapper
                $wrapperDir = Split-Path -Path $wrapperPath -Parent
                New-Item -Path $wrapperDir -ItemType Directory -Force | Out-Null
                [System.IO.File]::WriteAllText($wrapperPath, '# Wrapper`n`nSee .llm/context.md.`n', $utf8NoBom)
            }

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $tempRoot -ChildPath '.llm/context.md'),
                $script:fixtureContextContent,
                $utf8NoBom
            )
            [System.IO.File]::WriteAllText((Join-Path -Path $tempRoot -ChildPath '.llm/skills-index.md'), '# Skills Index`n', $utf8NoBom)

            $skillCardContent = @"
<!-- trigger: nested anchor path, deterministic validation | Validate nested skill anchor support | Core | skill-details/nested/example-detail.md -->
# Example Skill

- Expanded guide: [Example Detail](../skill-details/nested/example-detail.md)

## Core concepts

- [Nested valid anchor](../skill-details/nested/example-detail.md#existing-heading)
"@
            [System.IO.File]::WriteAllText((Join-Path -Path $tempRoot -ChildPath '.llm/skills/example-skill.md'), $skillCardContent, $utf8NoBom)
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $tempRoot -ChildPath '.llm/skill-details/nested/example-detail.md'),
                "# Example Detail`n`n## Existing Heading`n",
                $utf8NoBom
            )

            $tempUpdaterPath = Join-Path -Path $tempRoot -ChildPath 'Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1'
            Copy-Item -Path $script:indexUpdaterPath -Destination $tempUpdaterPath -Force
            & $tempUpdaterPath -RootPath $tempRoot

            { & $script:validatorPath -RootPath $tempRoot } | Should -Not -Throw
        }
        finally {
            & $script:RemoveTempRoot $tempRoot
        }
    }

    It "rejects anchor links that escape skill-details scope" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("llm-harness-{0}" -f ([System.Guid]::NewGuid().ToString('N')))
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        try {
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath '.llm/skills') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath '.llm/skill-details/safe') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path -Path $tempRoot -ChildPath 'Scripts/Utils/Quality') -ItemType Directory -Force | Out-Null

            foreach ($wrapper in $script:wrapperFiles) {
                $wrapperPath = Join-Path -Path $tempRoot -ChildPath $wrapper
                $wrapperDir = Split-Path -Path $wrapperPath -Parent
                New-Item -Path $wrapperDir -ItemType Directory -Force | Out-Null
                [System.IO.File]::WriteAllText($wrapperPath, '# Wrapper`n`nSee .llm/context.md.`n', $utf8NoBom)
            }

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $tempRoot -ChildPath '.llm/context.md'),
                $script:fixtureContextContent,
                $utf8NoBom
            )
            [System.IO.File]::WriteAllText((Join-Path -Path $tempRoot -ChildPath '.llm/skills-index.md'), '# Skills Index`n', $utf8NoBom)

            $skillCardContent = @"
<!-- trigger: scope check, deterministic validation | Reject skill anchor traversal paths | Core | skill-details/safe/example-detail.md -->
# Example Skill

- Expanded guide: [Example Detail](../skill-details/safe/example-detail.md)

## Core concepts

- [Traversal anchor](../skill-details/../context.md#context)
"@
            [System.IO.File]::WriteAllText((Join-Path -Path $tempRoot -ChildPath '.llm/skills/example-skill.md'), $skillCardContent, $utf8NoBom)
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $tempRoot -ChildPath '.llm/skill-details/safe/example-detail.md'),
                "# Example Detail`n`n## Existing Heading`n",
                $utf8NoBom
            )

            $tempUpdaterPath = Join-Path -Path $tempRoot -ChildPath 'Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1'
            Copy-Item -Path $script:indexUpdaterPath -Destination $tempUpdaterPath -Force
            & $tempUpdaterPath -RootPath $tempRoot

            $validationFailure = $null
            try {
                & $script:validatorPath -RootPath $tempRoot
            }
            catch {
                $validationFailure = $_
            }

            $validationFailure | Should -Not -BeNullOrEmpty
            $validationFailure.Exception.Message | Should -Match '(?i)E_LLM_SKILL_ANCHOR_SCOPE_VIOLATION'
        }
        finally {
            & $script:RemoveTempRoot $tempRoot
        }
    }
}
