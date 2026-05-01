function Get-FormatStringPlaceholderMaxIndex {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$FormatText
    )

    if ([string]::IsNullOrEmpty($FormatText)) {
        return -1
    }

    $placeholderMatches = [regex]::Matches($FormatText, '(?<!\{)\{(\d+)(?:[^}]*)\}')
    if ($placeholderMatches.Count -eq 0) {
        return -1
    }

    $maxPlaceholderIndex = -1
    foreach ($placeholderMatch in @($placeholderMatches)) {
        $matchIndex = [int]$placeholderMatch.Groups[1].Value
        if ($matchIndex -gt $maxPlaceholderIndex) {
            $maxPlaceholderIndex = $matchIndex
        }
    }

    return $maxPlaceholderIndex
}

function ConvertTo-PortableFormatOperatorPath {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ""
    }

    return ($PathValue -replace '[\\/]+', '/')
}

function Get-FormatOperatorContinuationCommaToken {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Management.Automation.Language.Token[]]$Tokens,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Management.Automation.Language.Ast]$RightExpression
    )

    if ($null -eq $RightExpression) {
        return $null
    }

    $rightExpressionEndOffset = $RightExpression.Extent.EndOffset
    $rightExpressionEndLine = $RightExpression.Extent.EndLineNumber

    foreach ($token in @($Tokens)) {
        if ($token.Extent.StartOffset -lt $rightExpressionEndOffset) {
            continue
        }

        if ($token.Kind -eq [System.Management.Automation.Language.TokenKind]::NewLine -or
            $token.Kind -eq [System.Management.Automation.Language.TokenKind]::LineContinuation -or
            $token.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) {
            continue
        }

        if ($token.Kind -ne [System.Management.Automation.Language.TokenKind]::Comma) {
            return $null
        }

        if ($token.Extent.StartLineNumber -ne $rightExpressionEndLine) {
            return $null
        }

        return $token
    }

    return $null
}

function Get-FormatOperatorContinuationViolations {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativeRoots = @("Scripts", "Tests")
    )

    $resolvedRootPath = (Resolve-Path -LiteralPath $RootPath -ErrorAction Stop).Path
    $violationList = New-Object System.Collections.Generic.List[object]

    foreach ($relativeRoot in @($RelativeRoots)) {
        if ([string]::IsNullOrWhiteSpace($relativeRoot)) {
            continue
        }

        $scanRootPath = Join-Path -Path $resolvedRootPath -ChildPath $relativeRoot
        if (-not (Test-Path -LiteralPath $scanRootPath -PathType Container)) {
            continue
        }

        $scriptFiles = @(Get-ChildItem -LiteralPath $scanRootPath -Recurse -File -Filter '*.ps1' -ErrorAction Stop)

        foreach ($scriptFile in @($scriptFiles)) {
            $scriptContent = (Get-Content -LiteralPath $scriptFile.FullName -Raw) -replace "`r", ''
            $scriptLines = @($scriptContent -split "`n")

            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) {
                $relativeParsePath = ConvertTo-PortableFormatOperatorPath -PathValue ([System.IO.Path]::GetRelativePath($resolvedRootPath, $scriptFile.FullName))
                $firstParseError = [string]$parseErrors[0]
                Write-Verbose (
                    "Format-operator safety parse diagnostics: file='{0}'; parseErrorCount={1}; firstError='{2}'" -f
                    $relativeParsePath,
                    @($parseErrors).Count,
                    $firstParseError
                )
            }

            if ($null -eq $ast) {
                continue
            }

            $formatExpressions = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                        $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Format
                    }, $true))

            foreach ($formatExpression in @($formatExpressions)) {
                $placeholderMaxIndex = Get-FormatStringPlaceholderMaxIndex -FormatText $formatExpression.Left.Extent.Text
                if ($placeholderMaxIndex -lt 1) {
                    continue
                }

                $rightExpression = $formatExpression.Right
                if ($null -eq $rightExpression) {
                    continue
                }

                # ArrayLiteralAst indicates PowerShell already bound comma-separated values to -f.
                # The under-binding risk is the opposite case: first argument binds alone and the
                # trailing comma continues in an outer invocation context.
                if ($rightExpression -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    continue
                }

                $leftExpressionEndLine = $formatExpression.Left.Extent.EndLineNumber
                $rightExpressionStartLine = $rightExpression.Extent.StartLineNumber
                if ($rightExpressionStartLine -le $leftExpressionEndLine) {
                    continue
                }

                $continuationCommaToken = Get-FormatOperatorContinuationCommaToken -Tokens $tokens -RightExpression $rightExpression
                if ($null -eq $continuationCommaToken) {
                    continue
                }

                $continuationLineNumber = $continuationCommaToken.Extent.StartLineNumber
                $continuationLineIndex = $continuationLineNumber - 1
                if ($continuationLineIndex -lt 0 -or $continuationLineIndex -ge $scriptLines.Count) {
                    continue
                }

                $rightExpressionLine = $scriptLines[$continuationLineIndex]

                $relativePath = ConvertTo-PortableFormatOperatorPath -PathValue ([System.IO.Path]::GetRelativePath($resolvedRootPath, $scriptFile.FullName))
                $violationList.Add([pscustomobject]@{
                        Path                = $relativePath
                        Line                = $rightExpressionStartLine
                        ContinuationLine    = $continuationLineNumber
                        PlaceholderMaxIndex = $placeholderMaxIndex
                        RightOperandAstType = $rightExpression.GetType().Name
                        Snippet             = $rightExpressionLine.Trim()
                    }) | Out-Null
            }
        }
    }

    return @($violationList.ToArray())
}

function Assert-NoFormatOperatorContinuationViolations {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativeRoots = @("Scripts", "Tests"),

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ErrorCode = "E_CONFIG_ERROR",

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ContextLabel = "PowerShell format-operator safety"
    )

    $violations = @(Get-FormatOperatorContinuationViolations -RootPath $RootPath -RelativeRoots $RelativeRoots)
    if ($violations.Count -eq 0) {
        Write-Verbose (
            "Format-operator safety diagnostics: context='{0}'; root='{1}'; status=ok" -f
            $ContextLabel,
            $RootPath
        )
        return
    }

    $previewLines = @($violations | Select-Object -First 20 | ForEach-Object {
            "- {0}:{1}; continuationLine={2}; placeholderMaxIndex={3}; rightOperandAstType={4}; line='{5}'" -f @(
                $_.Path
                $_.Line
                $_.ContinuationLine
                $_.PlaceholderMaxIndex
                $_.RightOperandAstType
                $_.Snippet
            )
        })
    if ($violations.Count -gt 20) {
        $previewLines += "- ... ({0} more violation(s))" -f ($violations.Count - 20)
    }

    throw (
        "{0}: {1} failed. Found {2} multiline '-f' continuation pattern(s) that can under-bind format arguments at runtime.`n{3}`nRemediation: keep '-f' and the first argument on the same line, or pass explicit argument arrays via '-f @(... )'." -f @(
            $ErrorCode
            $ContextLabel
            $violations.Count
            ($previewLines -join [Environment]::NewLine)
        )
    )
}
