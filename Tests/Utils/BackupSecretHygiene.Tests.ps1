Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:secretHygieneHelpersPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/BackupSecretHygieneHelpers.ps1"
    $script:diagnosticsHelpersPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/DiagnosticsHelpers.ps1"

    . $script:secretHygieneHelpersPath
    . $script:diagnosticsHelpersPath
}

Describe "Backup secret hygiene helper behaviors" {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("backup-secret-hygiene-tests-" + [System.Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($script:testRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path -Path $script:testRoot -ChildPath "Config")) | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot -PathType Container) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It "sanitizes known secret keys from UTF-16 BOM text files" {
        $relativePath = "Config/utf16-secret.txt"
        $fullPath = Join-Path -Path $script:testRoot -ChildPath $relativePath
        $secretValue = "Utf16FixtureSecretValue1234567890"

        $utf16Encoding = [System.Text.UnicodeEncoding]::new($false, $true)
        $fileContent = "token = `"$secretValue`"`nname = `"fixture`""
        [System.IO.File]::WriteAllText($fullPath, $fileContent, $utf16Encoding)

        $sanitizationResult = Invoke-BackupSecretHygieneSanitizeKnownSecrets -RepositoryRoot $script:testRoot -RelativePaths @($relativePath)

        @($sanitizationResult.RedactedFiles) | Should -Contain $relativePath
        @($sanitizationResult.DecodeFailureFiles).Count | Should -Be 0

        $sanitizedText = [System.IO.File]::ReadAllText($fullPath, [System.Text.UTF8Encoding]::new($false, $true))
        $sanitizedText | Should -Match '\[REDACTED\]'
        $sanitizedText | Should -Not -Match [regex]::Escape($secretValue)
    }

    It "does not silently bypass UTF-16 without BOM files that contain secrets" {
        $relativePath = "Config/utf16-no-bom-secret.txt"
        $fullPath = Join-Path -Path $script:testRoot -ChildPath $relativePath
        $secretValue = "Utf16NoBomFixtureSecretValue1234567890"

        $utf16NoBomEncoding = [System.Text.UnicodeEncoding]::new($false, $false)
        $fileContent = "token = `"$secretValue`"`nname = `"fixture`""
        [System.IO.File]::WriteAllText($fullPath, $fileContent, $utf16NoBomEncoding)

        $sanitizationResult = Invoke-BackupSecretHygieneSanitizeKnownSecrets -RepositoryRoot $script:testRoot -RelativePaths @($relativePath)
        $wasRedacted = @($sanitizationResult.RedactedFiles) -contains $relativePath
        $wasDecodeFailure = @($sanitizationResult.DecodeFailureFiles) -contains $relativePath

        ($wasRedacted -or $wasDecodeFailure) | Should -BeTrue

        $findings = @(Find-BackupSecretHygieneUnknownSecretFindings -RepositoryRoot $script:testRoot -RelativePaths @($relativePath))
        if ($wasRedacted) {
            $sanitizedText = [System.IO.File]::ReadAllText($fullPath, [System.Text.UTF8Encoding]::new($false, $true))
            $sanitizedText | Should -Match '\[REDACTED\]'
            $sanitizedText | Should -Not -Match [regex]::Escape($secretValue)
            @($findings | Where-Object { $_.PatternName -eq "text-decode-failed" }).Count | Should -Be 0
        }
        else {
            @($findings | Where-Object { $_.PatternName -eq "text-decode-failed" -and $_.FilePath -eq $relativePath }).Count | Should -Be 1
        }
    }

    It "fails closed for unknown-secret scanning when text decode is unsafe" {
        $relativePath = "Config/invalid-utf8.txt"
        $fullPath = Join-Path -Path $script:testRoot -ChildPath $relativePath

        $invalidUtf8Bytes = [byte[]](0x41, 0x42, 0xC3, 0x28, 0x43)
        [System.IO.File]::WriteAllBytes($fullPath, $invalidUtf8Bytes)

        $sanitizationResult = Invoke-BackupSecretHygieneSanitizeKnownSecrets -RepositoryRoot $script:testRoot -RelativePaths @($relativePath)
        @($sanitizationResult.DecodeFailureFiles) | Should -Contain $relativePath

        $findings = @(Find-BackupSecretHygieneUnknownSecretFindings -RepositoryRoot $script:testRoot -RelativePaths @($relativePath))
        @($findings | Where-Object { $_.PatternName -eq "text-decode-failed" }).Count | Should -Be 1
    }

    It "detects quoted JSON Authorization bearer tokens with high-confidence pattern" {
        $relativePath = "Config/auth.json"
        $fullPath = Join-Path -Path $script:testRoot -ChildPath $relativePath
        $authorizationToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9TokenPayloadSignature"

        $fileContent = @"
{
  "Authorization": "Bearer $authorizationToken"
}
"@
        [System.IO.File]::WriteAllText($fullPath, $fileContent, [System.Text.UTF8Encoding]::new($false))

        $null = Invoke-BackupSecretHygieneSanitizeKnownSecrets -RepositoryRoot $script:testRoot -RelativePaths @($relativePath)
        $findings = @(Find-BackupSecretHygieneUnknownSecretFindings -RepositoryRoot $script:testRoot -RelativePaths @($relativePath))

        @($findings | Where-Object { $_.PatternName -eq "authorization-header-bearer-token" }).Count | Should -Be 1
        @($findings | Where-Object { $_.FilePath -eq $relativePath }).Count | Should -BeGreaterThan 0
    }

    It "keeps secret scan preview diagnostics redacted" {
        $relativePath = "Config/auth-preview.json"
        $fullPath = Join-Path -Path $script:testRoot -ChildPath $relativePath
        $authorizationToken = "tok_live_preview_token_should_not_appear_1234567890"

        $fileContent = @"
{
  "Authorization": "Bearer $authorizationToken"
}
"@
        [System.IO.File]::WriteAllText($fullPath, $fileContent, [System.Text.UTF8Encoding]::new($false))

        $null = Invoke-BackupSecretHygieneSanitizeKnownSecrets -RepositoryRoot $script:testRoot -RelativePaths @($relativePath)
        $findings = @(Find-BackupSecretHygieneUnknownSecretFindings -RepositoryRoot $script:testRoot -RelativePaths @($relativePath))

        $findings.Count | Should -BeGreaterThan 0

        $previewLines = @(
            $findings |
                Select-Object -First 10 |
                ForEach-Object {
                    "{0}:{1} pattern={2} [REDACTED]" -f $_.FilePath, $_.LineNumber, $_.PatternName
                }
        )

        $preview = Get-OutputPreview -OutputLines $previewLines -MaxLines 5 -MaxCharacters 640 -HeadTailWhenTruncated
        $preview | Should -Match '\[REDACTED\]'
        $preview | Should -Not -Match [regex]::Escape($authorizationToken)
    }
}
