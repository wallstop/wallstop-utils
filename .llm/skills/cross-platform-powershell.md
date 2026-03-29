<!-- trigger: cross-platform, powershell portability, path separator, os detection, line endings, platform compatibility, case sensitivity | Write portable PowerShell that runs on Windows macOS and Linux | Platform | skill-details/cross-platform-powershell.md -->

# Cross-Platform PowerShell

Lightweight skill card for writing portable PowerShell 7+ scripts across Windows, macOS, and Linux.

- Expanded guide: [Cross-Platform PowerShell (Expanded)](../skill-details/cross-platform-powershell.md)
- Scope: applies to shared scripts (e.g., `Scripts/Utils/`); not for platform-specific directories like `Scripts/Komorebi/` or `Scripts/WinGet/`.

## Core concepts

- [Path handling and separator safety](../skill-details/cross-platform-powershell.md#path-handling-and-separator-safety)
- [OS detection and conditional logic](../skill-details/cross-platform-powershell.md#os-detection-and-conditional-logic)
- [Line ending and encoding safety](../skill-details/cross-platform-powershell.md#line-ending-and-encoding-safety)
- [Case sensitivity and file system differences](../skill-details/cross-platform-powershell.md#case-sensitivity-and-file-system-differences)
- [Performance and pipeline optimization](../skill-details/cross-platform-powershell.md#performance-and-pipeline-optimization)
- [Avoiding Windows-only APIs and commands](../skill-details/cross-platform-powershell.md#avoiding-windows-only-apis-and-commands)
- [Error handling and reliability](../skill-details/cross-platform-powershell.md#error-handling-and-reliability)
- Quick check: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1`
