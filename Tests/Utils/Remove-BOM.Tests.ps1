Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:removeBomScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Remove-BOM.ps1"
    $script:gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue

    . $script:removeBomScriptPath
}

Describe "Remove-BOM file discovery" {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("remove-bom-tests-" + [System.Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($script:testRoot) | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot -PathType Container) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It "uses git-native semantics to exclude dot-prefixed ignored directories" {
        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        & $script:gitCommand.Source -C $script:testRoot init | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "E_TEST_SETUP_FAILED: git init failed for '$script:testRoot'."
        }

        @(
            ".venv/",
            ".tmp_logs/",
            "*.log"
        ) | Set-Content -LiteralPath (Join-Path -Path $script:testRoot -ChildPath ".gitignore") -Encoding utf8

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".venv")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".tmp_logs")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "src")) | Out-Null

        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".venv/ignored.txt"), "ignored")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".tmp_logs/ignored.txt"), "ignored")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "trace.log"), "ignored")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "keep.txt"), "keep")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "src/keep2.txt"), "keep")

        $scanPlan = Get-ScannableFiles -scanRoot $script:testRoot
        $relativeFiles = @(
            $scanPlan.Files |
                ForEach-Object { [System.IO.Path]::GetRelativePath($script:testRoot, $_.FullName) -replace '\\', '/' } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $relativeFiles | Should -Contain "keep.txt"
        $relativeFiles | Should -Contain "src/keep2.txt"
        $relativeFiles | Should -Not -Contain ".venv/ignored.txt"
        $relativeFiles | Should -Not -Contain ".tmp_logs/ignored.txt"
        $relativeFiles | Should -Not -Contain "trace.log"
    }

    It "limits git-discovered files to the requested scan root" {
        if ($null -eq $script:gitCommand) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        & $script:gitCommand.Source -C $script:testRoot init | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "E_TEST_SETUP_FAILED: git init failed for '$script:testRoot'."
        }

        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "left")) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "right")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "left/a.txt"), "left")
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath "right/b.txt"), "right")

        $scanRoot = Join-Path -Path $script:testRoot -ChildPath "left"
        $scanPlan = Get-ScannableFiles -scanRoot $scanRoot
        $relativeFiles = @(
            $scanPlan.Files |
                ForEach-Object { [System.IO.Path]::GetRelativePath($script:testRoot, $_.FullName) -replace '\\', '/' } |
                Sort-Object -Unique
        )

        $scanPlan.Mode | Should -Be "git-ls-files"
        $relativeFiles | Should -Be @("left/a.txt")
    }

    It "fails safely when .gitignore exists but git discovery is unavailable" {
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".gitignore"), ".venv/`n")
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath ".venv")) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:testRoot -ChildPath ".venv/ignored.txt"), "ignored")

        Mock -CommandName Get-Command -MockWith { $null }

        {
            Get-ScannableFiles -scanRoot $script:testRoot
        } | Should -Throw "E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED*"
    }
}

Describe "Remove-BOM core behavior" {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("remove-bom-core-tests-" + [System.Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($script:testRoot) | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot -PathType Container) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It "removes a UTF-8 BOM and writes back as UTF-8 without BOM" {
        $filePath = Join-Path -Path $script:testRoot -ChildPath "bom.txt"
        [System.IO.File]::WriteAllText($filePath, "hello world", [System.Text.UTF8Encoding]::new($true))

        $changed = Remove-BOMFromFile -filePath $filePath
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)

        $changed | Should -BeTrue
        $bytes.Length | Should -BeGreaterThan 0
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $content | Should -Be "hello world"
    }

    It "does not modify files that do not have a UTF-8 BOM" {
        $filePath = Join-Path -Path $script:testRoot -ChildPath "no-bom.txt"
        [System.IO.File]::WriteAllText($filePath, "plain text", [System.Text.UTF8Encoding]::new($false))
        $bytesBefore = [System.IO.File]::ReadAllBytes($filePath)

        $changed = Remove-BOMFromFile -filePath $filePath
        $bytesAfter = [System.IO.File]::ReadAllBytes($filePath)

        $changed | Should -BeFalse
        $bytesAfter | Should -Be $bytesBefore
    }

    It "treats files with null bytes as binary and skips BOM removal" {
        $filePath = Join-Path -Path $script:testRoot -ChildPath "binary.bin"
        [System.IO.File]::WriteAllBytes($filePath, [byte[]](0x00, 0x01, 0x02, 0x03, 0x00))

        $isBinary = Test-IsBinaryFile -filePath $filePath
        $changed = Remove-BOMFromFile -filePath $filePath

        $isBinary | Should -BeTrue
        $changed | Should -BeFalse
    }
}
