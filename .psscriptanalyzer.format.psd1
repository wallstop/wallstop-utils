@{
    IncludeRules = @(
        'PSUseConsistentIndentation'
    )
    Rules        = @{
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
    }
}
