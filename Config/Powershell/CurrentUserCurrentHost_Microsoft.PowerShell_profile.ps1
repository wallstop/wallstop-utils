[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '', Justification = 'Set-PSReadLineOption -PredictionSource/-PredictionViewStyle are invoked only after a runtime parameter capability probe; Windows PowerShell 5.1 safely skips unsupported options.')]
param()

Import-Module PSReadLine -ErrorAction SilentlyContinue

$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
}
if ($setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
}
if ($setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('EditMode')) {
    Set-PSReadLineOption -EditMode Windows -ErrorAction SilentlyContinue
}

try { $null = gcm pshazz -ea stop; pshazz init 'default' } catch { }
