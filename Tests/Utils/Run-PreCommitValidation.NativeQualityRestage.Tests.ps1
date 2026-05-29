Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
    $script:preCommitContent = (Get-Content -Path $script:preCommitPath -Raw) -replace "`r", ""
}

Describe "Run-PreCommitValidation native-quality restage all-mode hash-snapshot guard" {
    It "snapshots native pre-format dirty file hashes in all-mode" {
        $script:preCommitContent | Should -Match 'preNativeQualityDiffOutput'
        $script:preCommitContent | Should -Match 'preNativeQualityDirtyFileHashes\s*=\s*Get-RelativeFileHashSnapshot'
    }

    It "compares pre/post native hashes to flag only formatter-modified dirty files" {
        $script:preCommitContent | Should -Match 'postNativeQualityDirtyFileHashes\s*=\s*Get-RelativeFileHashSnapshot'
        $script:preCommitContent | Should -Match 'allModeFormatterModifiedDirtyFiles'
        $script:preCommitContent | Should -Match 'nativeFormatterChangedFiles'
    }

    It "guards native restage throw behind formatter-changed file count in all-mode" {
        $script:preCommitContent | Should -Match '(?s)nativeFormatterChangedFiles\.Count\s*-gt\s*0.*?E_PRECOMMIT_NATIVE_QUALITY_RESTAGE_REQUIRED'
    }

    It "uses Compare-Object newly-dirty union for native all-mode detection" {
        $script:preCommitContent | Should -Match '(?s)Compare-Object\s+-ReferenceObject\s+\$preNativeQualityDiffOutput\s+-DifferenceObject\s+\$formattedNativeQualityFiles'
    }

    It "distinguishes pre-existing-dirty-but-unchanged from formatter-modified via before/after hash comparison" {
        # Core bug-fix distinguisher: pre-existing dirty files must only be flagged when the
        # formatter actually changed their content ($beforeHash -ne $afterHash). A regression
        # that flagged all pre-existing dirty files (e.g. assigning the snapshot keys directly)
        # would drop this comparison.
        $script:preCommitContent | Should -Match '\$beforeHash\s*-ne\s*\$afterHash'
    }

    It "filters newly-dirty files to the Compare-Object right side only" {
        $script:preCommitContent | Should -Match "Where-Object\s*\{\s*\`$_\.SideIndicator\s*-eq\s*'=>'\s*\}"
    }
}

Describe "Run-PreCommitValidation shell/native restage parity guard" {
    It "references Get-RelativeFileHashSnapshot in both shell and native restage blocks" {
        $script:preCommitContent | Should -Match 'preShellQualityDirtyFileHashes\s*=\s*Get-RelativeFileHashSnapshot'
        $script:preCommitContent | Should -Match 'preNativeQualityDirtyFileHashes\s*=\s*Get-RelativeFileHashSnapshot'
    }

    It "uses matching all-mode drift-snapshot diagnostics in both blocks" {
        $script:preCommitContent | Should -Match 'Shell quality all-mode drift snapshots'
        $script:preCommitContent | Should -Match 'Native quality all-mode drift snapshots'
    }

    It "keeps formatter-changed-file selection symmetric across shell and native" {
        $script:preCommitContent | Should -Match 'shellFormatterChangedFiles'
        $script:preCommitContent | Should -Match 'nativeFormatterChangedFiles'
    }

    It "asserts both shell and native blocks gate pre-existing dirty files on the before/after hash comparison" {
        # The shell block snapshots into $preShellQualityDirtyFileHashes and the native block into
        # $preNativeQualityDirtyFileHashes. Each block must perform the $beforeHash -ne $afterHash
        # comparison so neither can silently re-introduce the "flag every pre-existing dirty file" bug.
        $shellComparison = [regex]::Matches(
            $script:preCommitContent,
            '(?s)\$preShellQualityDirtyFileHashes\[\$relativePath\].*?\$beforeHash\s*-ne\s*\$afterHash'
        )
        $nativeComparison = [regex]::Matches(
            $script:preCommitContent,
            '(?s)\$preNativeQualityDirtyFileHashes\[\$relativePath\].*?\$beforeHash\s*-ne\s*\$afterHash'
        )

        $shellComparison.Count | Should -BeGreaterThan 0 -Because 'the shell restage block must compare before/after hashes'
        $nativeComparison.Count | Should -BeGreaterThan 0 -Because 'the native restage block must compare before/after hashes'

        # Parity: the comparison must appear at least twice across the file (once per block) so
        # the two blocks cannot diverge again.
        ([regex]::Matches($script:preCommitContent, '\$beforeHash\s*-ne\s*\$afterHash')).Count |
            Should -BeGreaterOrEqual 2 -Because 'both the shell and native restage blocks must retain the hash-comparison distinguisher'
    }
}
