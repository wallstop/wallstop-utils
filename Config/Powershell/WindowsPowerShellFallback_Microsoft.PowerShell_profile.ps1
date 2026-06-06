Import-Module PSReadLine -ErrorAction SilentlyContinue

# -PredictionSource/-PredictionViewStyle require PSReadLine 2.2+, which is absent from
# stock Windows PowerShell 5.1. Probe capability before invoking so old PSReadLine no-ops.
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
}
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
}
if ($setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('EditMode')) {
    Set-PSReadLineOption -EditMode Windows -ErrorAction SilentlyContinue
}

$setPSReadLineKeyHandler = Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue
if ($setPSReadLineKeyHandler) {
    Set-PSReadLineKeyHandler -Key Tab -Function Complete -ErrorAction SilentlyContinue
}

try { $null = gcm pshazz -ea stop; pshazz init 'default' } catch { }
