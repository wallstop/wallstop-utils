[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '', Justification = 'Set-PSReadLineOption -PredictionSource/-PredictionViewStyle are invoked only when a runtime Get-Command capability probe confirms the parameters exist; stock Windows PowerShell 5.1 (PSReadLine 2.0) skips them safely.')]
param()

Import-Module PSReadLine -ErrorAction SilentlyContinue

# -PredictionSource/-PredictionViewStyle require PSReadLine 2.2+, which is absent from
# stock Windows PowerShell 5.1. Probe capability before invoking so old PSReadLine no-ops.
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
}
if ($setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
}
Set-PSReadLineOption -EditMode Windows
Set-PSReadlineKeyHandler -Key Tab -Function Complete

try { $null = gcm pshazz -ea stop; pshazz init 'default' } catch { }
