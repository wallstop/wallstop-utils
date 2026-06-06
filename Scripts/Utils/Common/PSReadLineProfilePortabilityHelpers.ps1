# PSReadLineProfilePortabilityHelpers.ps1
#
# Shared AST-backed checks for PowerShell profile PSReadLine setup. Profiles are copied
# from user machines, so backup and CI both need to reject unguarded PSReadLine 2.2+
# options that break Windows PowerShell 5.1 or redirected hosts.

function Test-PSReadLineAstExtentContainsAst {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ContainerAst,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ChildAst
    )

    return ($ContainerAst.Extent.StartOffset -le $ChildAst.Extent.StartOffset -and
        $ContainerAst.Extent.EndOffset -ge $ChildAst.Extent.EndOffset)
}

function Test-PSReadLineAstContainsVariableName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $matches = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath -ieq $Name
            }, $true))

    return ($matches.Count -gt 0)
}

function Test-PSReadLineAstContainsStandaloneVariableName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $matches = @($Ast.FindAll({
                param($node)
                if (-not (Test-PSReadLineAstIsVariableName -Ast $node -Name $Name)) {
                    return $false
                }

                return (-not ($node.Parent -is [System.Management.Automation.Language.MemberExpressionAst]))
            }, $true))

    return ($matches.Count -gt 0)
}

function Test-PSReadLineAstIsVariableName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return ($Ast -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $Ast.VariablePath.UserPath -ieq $Name)
}

function Test-PSReadLineAstIsStringMemberName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $Ast.Value -ieq $Name)
}

function Test-PSReadLineAstIsTypeMemberAccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$TypeName,

        [Parameter(Mandatory = $true)]
        [string]$MemberName
    )

    if (-not ($Ast -is [System.Management.Automation.Language.MemberExpressionAst])) {
        return $false
    }
    if (-not ($Ast.Expression -is [System.Management.Automation.Language.TypeExpressionAst])) {
        return $false
    }
    if ($Ast.Expression.TypeName.Name -ine $TypeName -and $Ast.Expression.TypeName.FullName -ine $TypeName) {
        return $false
    }

    return (Test-PSReadLineAstIsStringMemberName -Ast $Ast.Member -Name $MemberName)
}

function Test-PSReadLineAstContainsTypeMemberAccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$TypeName,

        [Parameter(Mandatory = $true)]
        [string]$MemberName
    )

    $matches = @($Ast.FindAll({
                param($node)
                Test-PSReadLineAstIsTypeMemberAccess -Ast $node -TypeName $TypeName -MemberName $MemberName
            }, $true))

    return ($matches.Count -gt 0)
}

function Get-PSReadLineUnwrappedExpressionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $current = $Ast
    while ($current -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $current = $current.Expression
    }

    return $current
}

function Get-PSReadLineAndExpressionLeafAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $expressionAst = Get-PSReadLineUnwrappedExpressionAst -Ast $Ast
    if ($expressionAst -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $expressionAst.Operator -eq [System.Management.Automation.Language.TokenKind]::And) {
        $leftLeaves = @(Get-PSReadLineAndExpressionLeafAst -Ast $expressionAst.Left)
        $rightLeaves = @(Get-PSReadLineAndExpressionLeafAst -Ast $expressionAst.Right)
        return @($leftLeaves + $rightLeaves) # array-unwrap-safe: callers wrap in @(...).
    }

    return @($expressionAst) # array-unwrap-safe: callers wrap in @(...).
}

function Test-PSReadLineAstIsFalseLiteral {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $expressionAst = Get-PSReadLineUnwrappedExpressionAst -Ast $Ast
    return (Test-PSReadLineAstIsVariableName -Ast $expressionAst -Name 'false')
}

function Test-PSReadLineAstIsHostUISupportsVirtualTerminalProbe {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $expressionAst = Get-PSReadLineUnwrappedExpressionAst -Ast $Ast
    if ($expressionAst -is [System.Management.Automation.Language.ConvertExpressionAst]) {
        $expressionAst = $expressionAst.Child
    }

    return (Test-PSReadLineAstContainsHostUISupportsVirtualTerminalAccess -Ast $expressionAst)
}

function Test-PSReadLineAstIsSafePredictionHostGuardExpression {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $leaves = @(Get-PSReadLineAndExpressionLeafAst -Ast $Ast)
    if ($leaves.Count -ne 3) {
        return $false
    }

    $matchedUserInteractive = 0
    $matchedOutputRedirection = 0
    $matchedVirtualTerminal = 0
    foreach ($leaf in $leaves) {
        if (Test-PSReadLineAstIsTypeMemberAccess -Ast $leaf -TypeName 'Environment' -MemberName 'UserInteractive') {
            $matchedUserInteractive++
            continue
        }
        if ($leaf -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            $leaf.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Not -and
            (Test-PSReadLineAstIsTypeMemberAccess -Ast $leaf.Child -TypeName 'Console' -MemberName 'IsOutputRedirected')) {
            $matchedOutputRedirection++
            continue
        }
        if (Test-PSReadLineAstIsVariableName -Ast $leaf -Name 'supportsVirtualTerminal') {
            $matchedVirtualTerminal++
            continue
        }

        return $false
    }

    return ($matchedUserInteractive -eq 1 -and $matchedOutputRedirection -eq 1 -and $matchedVirtualTerminal -eq 1)
}

function Test-PSReadLineAstContainsHostUISupportsVirtualTerminalAccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $matches = @($Ast.FindAll({
                param($node)
                if (-not ($node -is [System.Management.Automation.Language.MemberExpressionAst])) {
                    return $false
                }
                if (-not (Test-PSReadLineAstIsStringMemberName -Ast $node.Member -Name 'SupportsVirtualTerminal')) {
                    return $false
                }
                if (-not ($node.Expression -is [System.Management.Automation.Language.MemberExpressionAst])) {
                    return $false
                }

                $innerMemberAst = $node.Expression
                return ((Test-PSReadLineAstIsStringMemberName -Ast $innerMemberAst.Member -Name 'UI') -and
                    (Test-PSReadLineAstIsVariableName -Ast $innerMemberAst.Expression -Name 'Host'))
            }, $true))

    return ($matches.Count -gt 0)
}

function Test-PSReadLineAstContainsPSReadLineOptionParameterGuard {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$ParameterName
    )

    $matches = @($Ast.FindAll({
                param($node)
                if (-not ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst])) {
                    return $false
                }
                if (-not ($node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst])) {
                    return $false
                }
                if ($node.Member.Value -ine 'ContainsKey') {
                    return $false
                }
                if (-not ($node.Expression -is [System.Management.Automation.Language.MemberExpressionAst])) {
                    return $false
                }

                $memberAccessAst = $node.Expression
                if (-not (Test-PSReadLineAstIsStringMemberName -Ast $memberAccessAst.Member -Name 'Parameters')) {
                    return $false
                }
                if (-not (Test-PSReadLineAstIsVariableName -Ast $memberAccessAst.Expression -Name 'setPSReadLineOption')) {
                    return $false
                }

                foreach ($argument in @($node.Arguments)) {
                    if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $argument.Value -ieq $ParameterName) {
                        return $true
                    }
                }

                return $false
            }, $true))

    return ($matches.Count -gt 0)
}

function Get-PSReadLineAssignmentAstForVariable {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.AssignmentStatementAst[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                (Test-PSReadLineAstIsVariableName -Ast $node.Left -Name $Name)
            }, $true))

    return @($assignments) # array-unwrap-safe: callers wrap in @(...).
}

function Get-PSReadLineAstRoot {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $current = $Ast
    while ($null -ne $current.Parent) {
        $current = $current.Parent
    }

    return $current
}

function Test-PSReadLineAstHasSafePredictionHostGuard {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $false)]
        [int]$BeforeOffset = [int]::MaxValue
    )

    $hasSupportsVirtualTerminalDefault = $false
    $hasSupportsVirtualTerminalProbe = $false
    $sawSupportsVirtualTerminalProbe = $false
    foreach ($assignment in @(Get-PSReadLineAssignmentAstForVariable -Ast $Ast -Name 'supportsVirtualTerminal')) {
        if ($assignment.Extent.StartOffset -ge $BeforeOffset) {
            continue
        }

        if (Test-PSReadLineAstIsFalseLiteral -Ast $assignment.Right) {
            $hasSupportsVirtualTerminalDefault = $true
            continue
        }

        if (Test-PSReadLineAstIsHostUISupportsVirtualTerminalProbe -Ast $assignment.Right) {
            $hasSupportsVirtualTerminalProbe = $true
            $sawSupportsVirtualTerminalProbe = $true
            continue
        }

        if ($sawSupportsVirtualTerminalProbe) {
            return $false
        }
    }

    if (-not ($hasSupportsVirtualTerminalDefault -and $hasSupportsVirtualTerminalProbe)) {
        return $false
    }

    $lastPredictionGuardAssignment = $null
    foreach ($assignment in @(Get-PSReadLineAssignmentAstForVariable -Ast $Ast -Name 'canConfigurePSReadLinePrediction')) {
        if ($assignment.Extent.StartOffset -ge $BeforeOffset) {
            continue
        }

        $lastPredictionGuardAssignment = $assignment
    }

    if ($null -eq $lastPredictionGuardAssignment) {
        return $false
    }

    return (Test-PSReadLineAstIsSafePredictionHostGuardExpression -Ast $lastPredictionGuardAssignment.Right)
}

function Get-PSReadLineGuardConditionAstForCommand {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst
    )

    $conditions = New-Object System.Collections.Generic.List[System.Management.Automation.Language.Ast]
    $current = $CommandAst.Parent
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in @($current.Clauses)) {
                $conditionAst = $clause.Item1
                $bodyAst = $clause.Item2
                if ($null -ne $bodyAst -and (Test-PSReadLineAstExtentContainsAst -ContainerAst $bodyAst -ChildAst $CommandAst)) {
                    $conditions.Add($conditionAst) | Out-Null
                }
            }
        }
        $current = $current.Parent
    }

    return @($conditions.ToArray()) # array-unwrap-safe: callers wrap in @(...).
}

function Test-PSReadLineCommandHasParameter {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [Parameter(Mandatory = $true)]
        [string]$ParameterName
    )

    foreach ($element in @($CommandAst.CommandElements)) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $element.ParameterName -ieq $ParameterName) {
            return $true
        }
    }

    return $false
}

function Test-PSReadLineCommandGuardedForPredictionParameter {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PredictionSource', 'PredictionViewStyle')]
        [string]$ParameterName
    )

    $rootAst = Get-PSReadLineAstRoot -Ast $CommandAst
    if (-not (Test-PSReadLineAstHasSafePredictionHostGuard -Ast $rootAst -BeforeOffset $CommandAst.Extent.StartOffset)) {
        return $false
    }

    $conditions = @(Get-PSReadLineGuardConditionAstForCommand -CommandAst $CommandAst)
    if ($conditions.Count -eq 0) {
        return $false
    }

    $hasHostGuard = $false
    $hasCommandProbeGuard = $false
    $hasParameterGuard = $false
    foreach ($condition in $conditions) {
        if (Test-PSReadLineAstContainsStandaloneVariableName -Ast $condition -Name 'canConfigurePSReadLinePrediction') {
            $hasHostGuard = $true
        }
        if (Test-PSReadLineAstContainsStandaloneVariableName -Ast $condition -Name 'setPSReadLineOption') {
            $hasCommandProbeGuard = $true
        }
        if (Test-PSReadLineAstContainsPSReadLineOptionParameterGuard -Ast $condition -ParameterName $ParameterName) {
            $hasParameterGuard = $true
        }
    }

    return ($hasHostGuard -and $hasCommandProbeGuard -and $hasParameterGuard)
}

function Test-PSReadLineCommandGuardedForKeyHandler {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$CommandAst
    )

    $conditions = @(Get-PSReadLineGuardConditionAstForCommand -CommandAst $CommandAst)
    foreach ($condition in $conditions) {
        if (Test-PSReadLineAstContainsVariableName -Ast $condition -Name 'setPSReadLineKeyHandler') {
            return $true
        }
    }

    return $false
}

function Get-PSReadLineProfilePortabilityViolation {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $parsePreview = @($parseErrors | Select-Object -First 3 | ForEach-Object { $_.Message }) -join '; '
        throw "E_PSREADLINE_PROFILE_PARSE_FAILED: Failed to parse PowerShell profile '$Path'. errors=$parsePreview"
    }
    if ($null -eq $ast) {
        return @() # array-unwrap-safe: callers wrap in @(...).
    }

    $violations = New-Object System.Collections.Generic.List[string]
    $commandAsts = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))

    foreach ($commandAst in $commandAsts) {
        $commandName = $commandAst.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            continue
        }

        if ($commandName -ieq 'Set-PSReadLineOption') {
            foreach ($predictionParameterName in @('PredictionSource', 'PredictionViewStyle')) {
                if (-not (Test-PSReadLineCommandHasParameter -CommandAst $commandAst -ParameterName $predictionParameterName)) {
                    continue
                }
                if (-not (Test-PSReadLineCommandGuardedForPredictionParameter -CommandAst $commandAst -ParameterName $predictionParameterName)) {
                    $violations.Add("unguarded-$predictionParameterName") | Out-Null
                }
            }

            if ($commandAst.Extent.Text -cmatch '\bInLineView\b') {
                $violations.Add('noncanonical-InLineView') | Out-Null
            }
        }

        if ($commandName -ieq 'Set-PSReadLineKeyHandler' -and
            -not (Test-PSReadLineCommandGuardedForKeyHandler -CommandAst $commandAst)) {
            $violations.Add('unguarded-Set-PSReadLineKeyHandler') | Out-Null
        }
    }

    return @($violations.ToArray()) # array-unwrap-safe: callers wrap in @(...).
}

function Test-PSReadLineCompatibilityFindingGuarded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Line,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PredictionSource', 'PredictionViewStyle')]
        [string]$ParameterName
    )

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast -or $parseErrors.Count -gt 0) {
        return $false
    }

    $commandAsts = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))

    foreach ($commandAst in $commandAsts) {
        $commandName = $commandAst.GetCommandName()
        if ($commandName -ine 'Set-PSReadLineOption') {
            continue
        }
        if ($commandAst.Extent.StartLineNumber -gt $Line -or $commandAst.Extent.EndLineNumber -lt $Line) {
            continue
        }
        if (-not (Test-PSReadLineCommandHasParameter -CommandAst $commandAst -ParameterName $ParameterName)) {
            continue
        }

        return (Test-PSReadLineCommandGuardedForPredictionParameter -CommandAst $commandAst -ParameterName $ParameterName)
    }

    return $false
}
