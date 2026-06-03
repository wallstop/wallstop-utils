# Shared secret-hygiene primitives for backup orchestration and behavior tests.

$script:BackupSecretHygieneTextCache = @{}
$script:BackupSecretHygieneDecodeFailureCache = @{}

function Reset-BackupSecretHygieneState {
    $script:BackupSecretHygieneTextCache = @{}
    $script:BackupSecretHygieneDecodeFailureCache = @{}
}

function Read-BackupSecretHygieneSampleBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65536)]
        [int]$ByteCount = 4096
    )

    $buffer = New-Object byte[] $ByteCount
    $stream = $null

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $bytesRead = $stream.Read($buffer, 0, $ByteCount)

        return [pscustomobject]@{
            Buffer       = $buffer
            BytesRead    = $bytesRead
            ReadFailed   = $false
            ErrorMessage = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Buffer       = @()
            BytesRead    = 0
            ReadFailed   = $true
            ErrorMessage = [string]$_.Exception.Message
        }
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-BackupSecretHygieneBomEncodingInfo {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Buffer,

        [Parameter(Mandatory = $true)]
        [int]$BytesRead
    )

    if ($BytesRead -ge 4 -and $Buffer[0] -eq 0x00 -and $Buffer[1] -eq 0x00 -and $Buffer[2] -eq 0xFE -and $Buffer[3] -eq 0xFF) {
        return [pscustomobject]@{
            Name     = 'utf-32-be'
            Encoding = [System.Text.UTF32Encoding]::new($true, $true, $true)
        }
    }

    if ($BytesRead -ge 4 -and $Buffer[0] -eq 0xFF -and $Buffer[1] -eq 0xFE -and $Buffer[2] -eq 0x00 -and $Buffer[3] -eq 0x00) {
        return [pscustomobject]@{
            Name     = 'utf-32-le'
            Encoding = [System.Text.UTF32Encoding]::new($false, $true, $true)
        }
    }

    if ($BytesRead -ge 3 -and $Buffer[0] -eq 0xEF -and $Buffer[1] -eq 0xBB -and $Buffer[2] -eq 0xBF) {
        return [pscustomobject]@{
            Name     = 'utf-8-bom'
            Encoding = [System.Text.UTF8Encoding]::new($true, $true)
        }
    }

    if ($BytesRead -ge 2 -and $Buffer[0] -eq 0xFE -and $Buffer[1] -eq 0xFF) {
        return [pscustomobject]@{
            Name     = 'utf-16-be'
            Encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
        }
    }

    if ($BytesRead -ge 2 -and $Buffer[0] -eq 0xFF -and $Buffer[1] -eq 0xFE) {
        return [pscustomobject]@{
            Name     = 'utf-16-le'
            Encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
        }
    }

    return $null
}

function Get-BackupSecretHygieneUtf16NoBomEncodingInfo {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Buffer,

        [Parameter(Mandatory = $true)]
        [int]$BytesRead
    )

    if ($BytesRead -lt 8) {
        return $null
    }

    $pairCount = [Math]::Floor([double]$BytesRead / 2.0)
    if ($pairCount -lt 4) {
        return $null
    }

    $evenZeroCount = 0
    $oddZeroCount = 0
    $bothZeroCount = 0
    $evenPrintableCount = 0
    $oddPrintableCount = 0

    for ($pairIndex = 0; $pairIndex -lt $pairCount; $pairIndex++) {
        $evenByte = [int]$Buffer[$pairIndex * 2]
        $oddByte = [int]$Buffer[($pairIndex * 2) + 1]

        if ($evenByte -eq 0) {
            $evenZeroCount++
        }

        if ($oddByte -eq 0) {
            $oddZeroCount++
        }

        if ($evenByte -eq 0 -and $oddByte -eq 0) {
            $bothZeroCount++
        }

        if ($evenByte -ge 32 -and $evenByte -le 126) {
            $evenPrintableCount++
        }

        if ($oddByte -ge 32 -and $oddByte -le 126) {
            $oddPrintableCount++
        }
    }

    $pairCountAsDouble = [double]$pairCount
    $evenZeroRatio = [double]$evenZeroCount / $pairCountAsDouble
    $oddZeroRatio = [double]$oddZeroCount / $pairCountAsDouble
    $bothZeroRatio = [double]$bothZeroCount / $pairCountAsDouble
    $evenPrintableRatio = [double]$evenPrintableCount / $pairCountAsDouble
    $oddPrintableRatio = [double]$oddPrintableCount / $pairCountAsDouble

    if ($bothZeroRatio -gt 0.10) {
        return $null
    }

    if ($oddZeroRatio -ge 0.30 -and $evenZeroRatio -le 0.10 -and $evenPrintableRatio -ge 0.60) {
        return [pscustomobject]@{
            Name     = 'utf-16-le-no-bom'
            Encoding = [System.Text.UnicodeEncoding]::new($false, $false, $true)
        }
    }

    if ($evenZeroRatio -ge 0.30 -and $oddZeroRatio -le 0.10 -and $oddPrintableRatio -ge 0.60) {
        return [pscustomobject]@{
            Name     = 'utf-16-be-no-bom'
            Encoding = [System.Text.UnicodeEncoding]::new($true, $false, $true)
        }
    }

    return $null
}

function Get-BackupSecretHygieneFileProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65536)]
        [int]$SampleBytes = 4096
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            IsMissing    = $true
            IsBinary     = $false
            ReadFailed   = $false
            ErrorMessage = ''
            BomInfo      = $null
            BytesRead    = 0
        }
    }

    $sample = Read-BackupSecretHygieneSampleBytes -Path $Path -ByteCount $SampleBytes
    if ($sample.ReadFailed) {
        return [pscustomobject]@{
            IsMissing    = $false
            IsBinary     = $false
            ReadFailed   = $true
            ErrorMessage = [string]$sample.ErrorMessage
            BomInfo      = $null
            BytesRead    = 0
        }
    }

    if ($sample.BytesRead -le 0) {
        return [pscustomobject]@{
            IsMissing    = $false
            IsBinary     = $false
            ReadFailed   = $false
            ErrorMessage = ''
            BomInfo      = $null
            BytesRead    = 0
        }
    }

    $bomInfo = Get-BackupSecretHygieneBomEncodingInfo -Buffer $sample.Buffer -BytesRead $sample.BytesRead
    if ($null -ne $bomInfo) {
        return [pscustomobject]@{
            IsMissing    = $false
            IsBinary     = $false
            ReadFailed   = $false
            ErrorMessage = ''
            BomInfo      = $bomInfo
            BytesRead    = $sample.BytesRead
        }
    }

    $nullByteCount = 0
    $nonTextByteCount = 0
    for ($index = 0; $index -lt $sample.BytesRead; $index++) {
        $currentByte = [int]$sample.Buffer[$index]

        if ($currentByte -eq 0) {
            $nullByteCount++
        }

        if (($currentByte -lt 9) -or (($currentByte -gt 13) -and ($currentByte -lt 32))) {
            $nonTextByteCount++
        }
    }

    if ($nullByteCount -gt 0) {
        $utf16NoBomInfo = Get-BackupSecretHygieneUtf16NoBomEncodingInfo -Buffer $sample.Buffer -BytesRead $sample.BytesRead
        if ($null -ne $utf16NoBomInfo) {
            return [pscustomobject]@{
                IsMissing    = $false
                IsBinary     = $false
                ReadFailed   = $false
                ErrorMessage = ''
                BomInfo      = $utf16NoBomInfo
                BytesRead    = $sample.BytesRead
            }
        }

        return [pscustomobject]@{
            IsMissing    = $false
            IsBinary     = $true
            ReadFailed   = $false
            ErrorMessage = ''
            BomInfo      = $null
            BytesRead    = $sample.BytesRead
        }
    }

    $nonTextRatio = [double]$nonTextByteCount / [double]$sample.BytesRead
    return [pscustomobject]@{
        IsMissing    = $false
        IsBinary     = ($nonTextRatio -gt 0.30)
        ReadFailed   = $false
        ErrorMessage = ''
        BomInfo      = $null
        BytesRead    = $sample.BytesRead
    }
}

function Test-BackupSecretHygieneLikelyBinaryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $probe = Get-BackupSecretHygieneFileProbe -Path $Path
    return [bool]$probe.IsBinary
}

function Get-BackupSecretHygieneTextContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $probe = Get-BackupSecretHygieneFileProbe -Path $Path
    if ($probe.IsMissing) {
        return [pscustomobject]@{
            IsMissing      = $true
            IsBinary       = $false
            DecodeFailed   = $false
            FailureReason  = ''
            FailureMessage = ''
            Text           = ''
        }
    }

    if ($probe.IsBinary) {
        return [pscustomobject]@{
            IsMissing      = $false
            IsBinary       = $true
            DecodeFailed   = $false
            FailureReason  = ''
            FailureMessage = ''
            Text           = ''
        }
    }

    if ($probe.ReadFailed) {
        return [pscustomobject]@{
            IsMissing      = $false
            IsBinary       = $false
            DecodeFailed   = $true
            FailureReason  = 'sample-read-failed'
            FailureMessage = [string]$probe.ErrorMessage
            Text           = ''
        }
    }

    $encoding = if ($null -ne $probe.BomInfo) {
        $probe.BomInfo.Encoding
    }
    else {
        [System.Text.UTF8Encoding]::new($false, $true)
    }

    try {
        $fileText = [System.IO.File]::ReadAllText($Path, $encoding)
        return [pscustomobject]@{
            IsMissing      = $false
            IsBinary       = $false
            DecodeFailed   = $false
            FailureReason  = ''
            FailureMessage = ''
            Text           = $fileText
        }
    }
    catch {
        return [pscustomobject]@{
            IsMissing      = $false
            IsBinary       = $false
            DecodeFailed   = $true
            FailureReason  = 'text-read-failed'
            FailureMessage = [string]$_.Exception.Message
            Text           = ''
        }
    }
}

function Get-BackupSecretHygieneKnownSecretFieldPattern {
    return '(?im)(?<prefix>["'']?(?:token|access_token|refresh_token|api_key|apikey|secret|client_secret|password|pat|github_token|bearer_token)["'']?\s*[:=]\s*)(?<value>"[^"\r\n]*"|''[^''\r\n]*''|[^\s,\r\n#;]+)'
}

function Get-BackupSecretHygieneUnknownSecretPatterns {
    return @(
        [pscustomobject]@{
            Name  = 'github-classic-pat'
            Regex = '(?i)\bghp_[A-Za-z0-9]{30,}\b'
        },
        [pscustomobject]@{
            Name  = 'github-fine-grained-pat'
            Regex = '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b'
        },
        [pscustomobject]@{
            Name  = 'authorization-header-bearer-token'
            Regex = '(?im)(?:^|[\s{,;])(?:"|'')?Authorization(?:"|'')?\s*[:=]\s*(?:"|'')?(?:Bearer|token)\s+[A-Za-z0-9._~+\/=\-]{20,}(?:"|'')?'
        }
    )
}

function Invoke-BackupSecretHygieneSanitizeKnownSecrets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativePaths = @()
    )

    Reset-BackupSecretHygieneState

    $secretFieldPattern = Get-BackupSecretHygieneKnownSecretFieldPattern
    $redactedFiles = New-Object System.Collections.Generic.List[string]
    $skippedBinaryFiles = New-Object System.Collections.Generic.List[string]
    $decodeFailureFiles = New-Object System.Collections.Generic.List[string]

    foreach ($relativePath in @($RelativePaths)) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $fullPath = Join-Path -Path $RepositoryRoot -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            continue
        }

        $textResult = Get-BackupSecretHygieneTextContent -Path $fullPath
        if ($textResult.IsBinary) {
            [void]$skippedBinaryFiles.Add($relativePath)
            continue
        }

        if ($textResult.DecodeFailed) {
            [void]$decodeFailureFiles.Add($relativePath)
            $script:BackupSecretHygieneDecodeFailureCache[$relativePath] = [pscustomobject]@{
                FailureReason  = [string]$textResult.FailureReason
                FailureMessage = [string]$textResult.FailureMessage
            }
            continue
        }

        $fileText = [string]$textResult.Text
        $redactedText = [System.Text.RegularExpressions.Regex]::Replace(
            $fileText,
            $secretFieldPattern,
            {
                param($match)

                $rawValue = [string]$match.Groups['value'].Value
                if ($rawValue -eq '[REDACTED]' -or $rawValue -eq '"[REDACTED]"' -or $rawValue -eq "'[REDACTED]'") {
                    return $match.Value
                }

                $replacementValue = '[REDACTED]'
                if ($rawValue.Length -ge 2 -and $rawValue.StartsWith('"') -and $rawValue.EndsWith('"')) {
                    $replacementValue = '"[REDACTED]"'
                }
                elseif ($rawValue.Length -ge 2 -and $rawValue.StartsWith("'") -and $rawValue.EndsWith("'")) {
                    $replacementValue = "'[REDACTED]'"
                }

                return ($match.Groups['prefix'].Value + $replacementValue)
            }
        )

        if ($redactedText -ne $fileText) {
            [System.IO.File]::WriteAllText($fullPath, $redactedText, [System.Text.UTF8Encoding]::new($false))
            [void]$redactedFiles.Add($relativePath)
        }

        $script:BackupSecretHygieneTextCache[$relativePath] = $redactedText
    }

    return [pscustomobject]@{
        RedactedFiles      = $redactedFiles.ToArray()
        SkippedBinaryFiles = $skippedBinaryFiles.ToArray()
        DecodeFailureFiles = $decodeFailureFiles.ToArray()
        InputFileCount     = @($RelativePaths).Count
    }
}

function Find-BackupSecretHygieneUnknownSecretFindings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativePaths = @()
    )

    $secretPatterns = @(Get-BackupSecretHygieneUnknownSecretPatterns)
    $findings = New-Object System.Collections.Generic.List[object]
    $seenPaths = New-Object System.Collections.Generic.HashSet[string]

    foreach ($candidatePath in @($RelativePaths)) {
        $relativePath = [string]$candidatePath
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $relativePath = $relativePath.Trim()
        if (-not $seenPaths.Add($relativePath)) {
            continue
        }

        if ($script:BackupSecretHygieneDecodeFailureCache.ContainsKey($relativePath)) {
            [void]$findings.Add([pscustomobject]@{
                    FilePath    = $relativePath
                    LineNumber  = 1
                    PatternName = 'text-decode-failed'
                })
            continue
        }

        $fileText = ''
        if ($script:BackupSecretHygieneTextCache.ContainsKey($relativePath)) {
            $fileText = [string]$script:BackupSecretHygieneTextCache[$relativePath]
        }
        else {
            $fullPath = Join-Path -Path $RepositoryRoot -ChildPath $relativePath
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                continue
            }

            $textResult = Get-BackupSecretHygieneTextContent -Path $fullPath
            if ($textResult.IsBinary) {
                continue
            }

            if ($textResult.DecodeFailed) {
                $script:BackupSecretHygieneDecodeFailureCache[$relativePath] = [pscustomobject]@{
                    FailureReason  = [string]$textResult.FailureReason
                    FailureMessage = [string]$textResult.FailureMessage
                }

                [void]$findings.Add([pscustomobject]@{
                        FilePath    = $relativePath
                        LineNumber  = 1
                        PatternName = 'text-decode-failed'
                    })
                continue
            }

            $fileText = [string]$textResult.Text
            $script:BackupSecretHygieneTextCache[$relativePath] = $fileText
        }

        $fileLines = [System.Text.RegularExpressions.Regex]::Split($fileText, "\r?\n")
        for ($lineIndex = 0; $lineIndex -lt $fileLines.Length; $lineIndex++) {
            $lineText = [string]$fileLines[$lineIndex]
            foreach ($secretPattern in $secretPatterns) {
                if ([System.Text.RegularExpressions.Regex]::IsMatch($lineText, [string]$secretPattern.Regex)) {
                    [void]$findings.Add([pscustomobject]@{
                            FilePath    = $relativePath
                            LineNumber  = $lineIndex + 1
                            PatternName = [string]$secretPattern.Name
                        })
                }
            }
        }
    }

    return $findings.ToArray()
}
