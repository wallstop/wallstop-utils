@{
    Severity = @('Error', 'Warning')
    IncludeRules = @(
        'PSAvoidUsingCmdletAliases',
        'PSAvoidGlobalAliases',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingInvokeExpression'
    )
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
