<!-- trigger: cross-platform, powershell portability, path separator, os detection, line endings, platform compatibility, case sensitivity, git bash, bash_env, processstartinfo path, fake-command harness | Write portable PowerShell that runs on Windows PowerShell 5.1 and PowerShell 7+ across Windows, macOS, and Linux | Platform | skill-details/cross-platform-powershell.md -->

# Cross-Platform PowerShell

Lightweight skill card for writing portable PowerShell that runs on Windows PowerShell 5.1 and PowerShell 7+ across Windows, macOS, and Linux.

- Expanded guide: [Cross-Platform PowerShell (Expanded)](../skill-details/cross-platform-powershell.md)
- Scope: applies to shared scripts (e.g., `Scripts/Utils/`); not for platform-specific directories like `Scripts/Komorebi/` or `Scripts/WinGet/`.

## Core concepts

- [Path handling and separator safety](../skill-details/cross-platform-powershell.md#path-handling-and-separator-safety)
- [Literal paths, validation, and canonicalization](../skill-details/cross-platform-powershell.md#literal-paths-validation-and-canonicalization)
- [Directory traversal, providers, and symlinks](../skill-details/cross-platform-powershell.md#directory-traversal-providers-and-symlinks)
- [OS detection and conditional logic](../skill-details/cross-platform-powershell.md#os-detection-and-conditional-logic)
- [Line ending and encoding safety](../skill-details/cross-platform-powershell.md#line-ending-and-encoding-safety)
- [Case sensitivity and file system differences](../skill-details/cross-platform-powershell.md#case-sensitivity-and-file-system-differences)
- [Process and Git Bash environment isolation](../skill-details/cross-platform-powershell.md#process-and-git-bash-environment-isolation)
- [Performance and pipeline optimization](../skill-details/cross-platform-powershell.md#performance-and-pipeline-optimization)
- [Avoiding Windows-only APIs and commands](../skill-details/cross-platform-powershell.md#avoiding-windows-only-apis-and-commands)
- [Error handling and reliability](../skill-details/cross-platform-powershell.md#error-handling-and-reliability)
- Quick check: `pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1`
