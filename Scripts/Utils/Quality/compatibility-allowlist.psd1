@{
    # Findings reported by PSUseCompatibleCommands that are NOT real Windows PowerShell 5.1
    # incompatibilities, split by category so the gate can suppress them precisely.
    #
    # ExternalExecutables: native programs invoked by name. The analyzer compares against
    #   built-in PowerShell command profiles, so any external program reads as "command not
    #   available". ONLY the command-absence finding is suppressed for these; a parameter
    #   finding (which cannot occur for a native program) would still surface.
    #
    # ModuleCommands: commands provided by a runtime-installed module (Pester 5 DSL). These
    #   work on both editions once the module is installed but are absent from the built-in
    #   platform profiles, so BOTH the command-absence AND any parameter findings for them
    #   are false positives and suppressed.
    #
    # Neither list may contain a real built-in PowerShell cmdlet whose parameters/behavior
    # actually differ across editions (for example ConvertTo-Json, New-Item). Genuine
    # incompatibilities are fixed in code or suppressed inline with a justified
    # SuppressMessageAttribute, never hidden here. Enforced by
    # Tests/Utils/CompatibilityConventions.Tests.ps1.
    ExternalExecutables = @(
        'node'
        'npm'
        'npx'
        'git'
        'gh'
        'dotnet'
        'pwsh'
        'powershell'
        'pandoc'
        'robocopy'
        'scoop'
        'winget'
        'komorebic'
        'pshazz'
        'pre-commit'
        'shfmt'
        'shellcheck'
        'stylua'
        'actionlint'
        'pbcopy'
        'xclip'
        'xsel'
        'wl-copy'
    )

    ModuleCommands = @(
        'Invoke-Pester'
        'Describe'
        'Context'
        'It'
        'Should'
        'BeforeAll'
        'AfterAll'
        'BeforeEach'
        'AfterEach'
        'BeforeDiscovery'
        'Mock'
        'Assert-MockCalled'
        'Assert-VerifiableMock'
        'New-PesterConfiguration'
        'New-MockObject'
        'Set-ItResult'
        'InModuleScope'
        'Add-ShouldOperator'
        'Get-MockDynamicParameter'
    )
}
