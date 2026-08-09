BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:backupScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/BackupDxMessaging.ps1"
    $script:tokens = $null
    $script:parseErrors = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:backupScriptPath,
        [ref]$script:tokens,
        [ref]$script:parseErrors
    )

    function Get-AssignmentAst {
        param([Parameter(Mandatory = $true)][string]$Name)

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq $Name
                }, $true))
    }

    function Get-AstArgumentTokens {
        param([Parameter(Mandatory = $true)]$Node)

        return @($Node.FindAll({
                    param($child)
                    $child -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $child -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true) | Sort-Object { $_.Extent.StartOffset } | ForEach-Object {
                if ($_ -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    '$' + $_.VariablePath.UserPath
                }
                else {
                    $_.Value
                }
            })
    }

    function Get-CommandParameterArgument {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$Command,
            [Parameter(Mandatory = $true)][string]$ParameterName
        )

        for ($index = 0; $index -lt $Command.CommandElements.Count; $index++) {
            $element = $Command.CommandElements[$index]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq $ParameterName) {
                if ($index + 1 -ge $Command.CommandElements.Count) {
                    return $null
                }
                return $Command.CommandElements[$index + 1]
            }
        }
        return $null
    }

    function Get-BackupProcessInvocation {
        param([Parameter(Mandatory = $true)][string]$Description)

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Invoke-BackupProcess'
                }, $true) | Where-Object {
                $descriptionArgument = Get-CommandParameterArgument -Command $_ -ParameterName 'Description'
                $null -ne $descriptionArgument -and $descriptionArgument.Value -eq $Description
            })
    }

    function Get-GuardAst {
        param([Parameter(Mandatory = $true)][string]$ConditionPattern)

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses.Count -gt 0 -and
                    $node.Clauses[0].Item1.Extent.Text -match $ConditionPattern
                }, $true))
    }
}

Describe "BackupDxMessaging reliability conventions" {
    It "parses without errors" {
        $script:parseErrors.Count | Should -Be 0
    }

    It "ties exclusions and junction protection to the staging invocation" {
        $excludedDirs = @(Get-AstArgumentTokens -Node (Get-AssignmentAst -Name 'excludedDirs')[0].Right)
        foreach ($required in @('.artifacts', '.venv', '.codex-home', 'node_modules', '__pycache__')) {
            $excludedDirs | Should -Contain $required
        }
        @(Get-AstArgumentTokens -Node (Get-AssignmentAst -Name 'excludedFiles')[0].Right) | Should -Contain 'nul'

        $foreachAsts = @($script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))
        ($foreachAsts | Where-Object { $_.Variable.VariablePath.UserPath -eq 'dir' }).Body.Extent.Text |
            Should -Match '\$robocopyArgs\s*\+=\s*["'']?/XD["'']?\s*,\s*\$dir'
        ($foreachAsts | Where-Object {
            $_.Variable.VariablePath.UserPath -eq 'file' -and $_.Body.Extent.Text -match '\$robocopyArgs'
        }).Body.Extent.Text |
            Should -Match '\$robocopyArgs\s*\+=\s*["'']?/XF["'']?\s*,\s*\$file'

        $stagingTokens = @(Get-AstArgumentTokens -Node (Get-AssignmentAst -Name 'robocopyArgs')[0].Right)
        foreach ($junctionFlag in @('/XJ', '/XJD', '/XJF')) {
            $stagingTokens | Should -Contain $junctionFlag
        }
        $stagingInvocation = @(Get-BackupProcessInvocation -Description 'staging copy')
        $stagingInvocation.Count | Should -Be 1
        (Get-CommandParameterArgument -Command $stagingInvocation[0] -ParameterName 'ArgumentList').Extent.Text | Should -Be '$robocopyArgs'

        $guard = @(Get-GuardAst -ConditionPattern '\$robocopyExitCode\s+-ge\s+8')
        $guard.Count | Should -Be 1
        $guard[0].Extent.Text | Should -Match 'E_DXMSG_BACKUP_STAGING_COPY_FAILED'
    }

    It "creates and verifies the archive through the intended tar invocations" {
        @(Get-AstArgumentTokens -Node (Get-AssignmentAst -Name 'archiveArgs')[0].Right) |
            Should -Be @('-a', '-c', '-f', '$zipFilePath', '-C', '$tempStagePath', '.')
        @(Get-AstArgumentTokens -Node (Get-AssignmentAst -Name 'verifyArgs')[0].Right) |
            Should -Be @('-t', '-f', '$zipFilePath', '$requiredArchiveEntry')
        @(Get-AstArgumentTokens -Node (Get-AssignmentAst -Name 'requiredArchiveEntry')[0].Right) |
            Should -Be @('./Packages/com.wallstop-studios.dxmessaging/package.json')

        foreach ($case in @(
                @{ Description = 'ZIP archive creation'; Arguments = '$archiveArgs' },
                @{ Description = 'ZIP archive verification'; Arguments = '$verifyArgs' }
            )) {
            $invocation = @(Get-BackupProcessInvocation -Description $case.Description)
            $invocation.Count | Should -Be 1
            (Get-CommandParameterArgument -Command $invocation[0] -ParameterName 'FilePath').Extent.Text | Should -Be '$tarCommand.Source'
            (Get-CommandParameterArgument -Command $invocation[0] -ParameterName 'ArgumentList').Extent.Text | Should -Be $case.Arguments
        }

        $archiveGuard = @(Get-GuardAst -ConditionPattern '\$archiveExitCode\s+-ne\s+0')
        $archiveGuard.Count | Should -Be 1
        $archiveGuard[0].Extent.Text | Should -Match 'E_DXMSG_BACKUP_ARCHIVE_FAILED'
        $verifyGuard = @(Get-GuardAst -ConditionPattern '\$verifyExitCode\s+-ne\s+0')
        $verifyGuard.Count | Should -Be 1
        $verifyGuard[0].Extent.Text | Should -Match 'E_DXMSG_BACKUP_ARCHIVE_VERIFY_FAILED'

        @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Compress-Archive'
                }, $true)).Count | Should -Be 0
    }

    It "publishes only a verified partial and preserves recovery artifacts" {
        (Get-AssignmentAst -Name 'partialZipFileName')[0].Right.Extent.Text | Should -Match 'dxmsg-\$runId\.partial\.zip'
        (Get-AssignmentAst -Name 'rollbackZipFileName')[0].Right.Extent.Text | Should -Match 'dxmsg-\$runId\.rollback\.zip'

        $transferTokens = @(Get-AstArgumentTokens -Node (Get-AssignmentAst -Name 'robocopyMoveArgs')[0].Right)
        $transferTokens | Should -Contain '$partialZipFileName'
        @($transferTokens | Where-Object { $_ -in @('/MOV', '/MOVE') }).Count | Should -Be 0
        $transferInvocation = @(Get-BackupProcessInvocation -Description 'backup transfer')
        $transferInvocation.Count | Should -Be 1
        (Get-CommandParameterArgument -Command $transferInvocation[0] -ParameterName 'ArgumentList').Extent.Text | Should -Be '$robocopyMoveArgs'

        foreach ($guardCase in @(
                @{ Pattern = '\$moveExitCode\s+-ge\s+8'; Code = 'E_DXMSG_BACKUP_TRANSFER_FAILED' },
                @{ Pattern = '\$networkPartialPath\s+-PathType\s+Leaf'; Code = 'E_DXMSG_BACKUP_TRANSFER_VERIFY_FAILED' }
            )) {
            $guard = @(Get-GuardAst -ConditionPattern $guardCase.Pattern | Where-Object { $_.Extent.Text -match $guardCase.Code })
            $guard.Count | Should -Be 1
            $guard[0].Extent.Text | Should -Match $guardCase.Code
        }

        $publishTry = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $node.Body.Extent.Text -match '\[System\.IO\.File\]::Replace' -and
                    $node.Body.Extent.Text -match '\[System\.IO\.File\]::Move' -and
                    $node.CatchClauses.Count -eq 1 -and
                    $node.CatchClauses[0].Extent.Text -match 'E_DXMSG_BACKUP_PUBLISH_FAILED'
                }, $true))
        $publishTry.Count | Should -Be 1
        $publishTry[0].Body.Extent.Text | Should -Match '\[System\.IO\.File\]::Replace\(\$networkPartialPath\s*,\s*\$networkFinalPath\s*,\s*\$networkRollbackPath\s*,\s*\$true\)'
        $publishTry[0].Body.Extent.Text | Should -Match '\[System\.IO\.File\]::Move\(\$networkPartialPath\s*,\s*\$networkFinalPath\)'
        $publishTry[0].CatchClauses[0].Extent.Text | Should -Match 'E_DXMSG_BACKUP_PUBLISH_FAILED'
        $transferVerifyGuard = @(Get-GuardAst -ConditionPattern '\$networkPartialPath\s+-PathType\s+Leaf' |
                Where-Object { $_.Extent.Text -match 'E_DXMSG_BACKUP_TRANSFER_VERIFY_FAILED' })[0]
        $transferVerifyGuard.Extent.StartOffset | Should -BeLessThan $publishTry[0].Extent.StartOffset

        $publishedTrue = @(Get-AssignmentAst -Name 'backupPublished' | Where-Object { $_.Right.Extent.Text -eq '$true' })
        $publishedTrue.Count | Should -Be 1
        $publishedTrue[0].Extent.StartOffset | Should -BeGreaterThan $publishTry[0].Extent.EndOffset

        $outerTry = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $null -ne $node.Finally -and $node.Finally.Extent.Text -match '\$tempStagePath'
                }, $true))
        $outerTry.Count | Should -Be 1
        $publishedCleanup = @($outerTry[0].Finally.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses.Count -gt 0 -and $node.Clauses[0].Item1.Extent.Text -match '\$backupPublished'
                }, $true))
        $publishedCleanup.Count | Should -Be 1
        $publishedCleanup[0].Clauses[0].Item2.Extent.Text | Should -Match 'Remove-Item\s+-LiteralPath\s+\$zipFilePath'
        $publishedCleanup[0].ElseClause.Extent.Text | Should -Match 'W_DXMSG_BACKUP_RECOVERY_ARCHIVE_RETAINED'

        $backupListings = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-ChildItem' -and $node.Extent.Text -match '\$backupDir'
                }, $true))
        $backupListings.Count | Should -BeGreaterOrEqual 2
        foreach ($listing in $backupListings) {
            (Get-CommandParameterArgument -Command $listing -ParameterName 'Filter').Value | Should -Be '????-??-??.zip'
        }
    }

    It "terminates timed-out process trees and always disposes the process" {
        $functionAst = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BackupProcess'
                }, $true))
        $functionAst.Count | Should -Be 1
        $functionText = $functionAst[0].Extent.Text
        $functionText | Should -Match 'Stop-ProcessTreePortably\s+-Process\s+\$process'
        $functionText | Should -Match 'WaitForExit\(10000\)'
        $functionText | Should -Match 'E_DXMSG_BACKUP_PROCESS_TERMINATION_FAILED'
        $functionText | Should -Match 'E_DXMSG_BACKUP_PROCESS_TIMEOUT'
        $functionText | Should -Not -Match 'WaitForExit\(\s*\)'
        $functionAst[0].Body.Extent.Text | Should -Match 'finally\s*\{[\s\S]*\$process\.Dispose\(\)'
    }

    It "preserves stable backup error codes at the script boundary" {
        $outerTry = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $null -ne $node.Finally -and $node.Finally.Extent.Text -match '\$tempStagePath'
                }, $true))[0]
        $catchText = $outerTry.CatchClauses[0].Extent.Text
        $catchText | Should -Match '\$failureMessage\s*=\s*\$_\.Exception\.Message'
        $catchText | Should -Match '\$failureMessage\s+-match\s+[''\"]\^E_DXMSG_BACKUP_'
        $catchText | Should -Match 'Write-Error\s+\$failureMessage'
        $catchText | Should -Match 'E_DXMSG_BACKUP_UNEXPECTED'
    }

    It "guards empty executable discovery before selecting deterministic candidates" {
        foreach ($case in @(
                @{ List = 'robocopyCommands'; Selected = 'robocopyCommand'; Executable = 'Robocopy.exe'; Code = 'E_DXMSG_BACKUP_ROBOCOPY_NOT_AVAILABLE' },
                @{ List = 'tarCommands'; Selected = 'tarCommand'; Executable = 'tar.exe'; Code = 'E_DXMSG_BACKUP_TAR_NOT_AVAILABLE' }
            )) {
            $listAssignment = @(Get-AssignmentAst -Name $case.List)
            $selectedAssignment = @(Get-AssignmentAst -Name $case.Selected)
            $listAssignment.Count | Should -Be 1
            $selectedAssignment.Count | Should -Be 1
            $listAssignment[0].Right.Extent.Text | Should -Match ('Get-Command\s+-Name\s+["'']{0}["'']' -f [regex]::Escape($case.Executable))

            $guard = @(Get-GuardAst -ConditionPattern ('\${0}\.Count\s+-eq\s+0' -f $case.List))
            $guard.Count | Should -Be 1
            $guard[0].Extent.Text | Should -Match $case.Code
            $guard[0].Extent.Text | Should -Match 'exit\s+1'
            $guard[0].Extent.StartOffset | Should -BeLessThan $selectedAssignment[0].Extent.StartOffset
            $selectedAssignment[0].Right.Extent.Text | Should -Match ('\${0}\s*\[\s*0\s*\]' -f $case.List)
        }
    }
}
