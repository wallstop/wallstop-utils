BeforeAll {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
    $scriptPath = Join-Path -Path $repoRoot -ChildPath 'Scripts/Scoop/ScoopUpdate.ps1'
}

Describe 'Scoop update automation' {
    It 'runs the all-app update exactly once' {
        $content = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8) -replace "`r", ''

        @([regex]::Matches($content, '(?m)^\s*scoop\s+update\s+\*\s*$')).Count | Should -Be 1
        $content | Should -Match '\$scoopExitCode\s*=\s*\$LASTEXITCODE'
        $content | Should -Match 'exit\s+\$scoopExitCode'
        $content | Should -Not -Match '(?m)^\s*scoop\s+update\s+java\s+\*\s*$'
    }
}
