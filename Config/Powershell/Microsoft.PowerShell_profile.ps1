Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource History -ErrorAction SilentlyContinue
Set-PSReadLineOption -PredictionViewStyle InLineView
Set-PSReadLineOption -EditMode Windows

try { $null = gcm pshazz -ea stop; pshazz init 'default' } catch { }