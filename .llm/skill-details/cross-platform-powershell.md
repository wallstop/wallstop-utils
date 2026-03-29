# Cross-Platform PowerShell (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/cross-platform-powershell.md`.
Applies to shared scripts (e.g., `Scripts/Utils/`); platform-specific directories like `Scripts/Komorebi/` are exempt.

## Path Handling And Separator Safety

Use `Join-Path`, `Split-Path`, and `[System.IO.Path]` methods instead of string concatenation with `/` or `\`.

```powershell
# Correct: platform-safe path construction
$configPath = Join-Path -Path $HOME -ChildPath 'config' | Join-Path -ChildPath 'settings.json'
$parent = [System.IO.Path]::GetDirectoryName($filePath)

# Wrong: hardcoded separator
$configPath = "$HOME\config\settings.json"
```

When generating output for markdown, logs, or cross-platform comparison, normalize separators:

```powershell
$portablePath = $rawPath -replace '[\\/]+', '/'
```

Avoid hardcoded drive letters (`C:\`) or Unix-only root paths (`/usr/local`).
Use `$HOME`, `[System.IO.Path]::GetTempPath()`, and `$PSScriptRoot` for anchored paths.
Do not use `$env:TEMP` directly; it is unset on Linux/macOS.

## OS Detection And Conditional Logic

Use PowerShell 7+ automatic variables for OS detection:

```powershell
if ($IsWindows) {
    # Windows-specific logic
} elseif ($IsMacOS) {
    # macOS-specific logic
} elseif ($IsLinux) {
    # Linux-specific logic
}
```

Do not use `[System.Runtime.InteropServices.RuntimeInformation]` or `$env:OS` checks when the automatic variables are available. They are cleaner and more reliable in PowerShell 7+.

For commands that differ by platform, use a lookup pattern:

```powershell
$openCmd = if ($IsWindows) { 'start' } elseif ($IsMacOS) { 'open' } else { 'xdg-open' }
```

## Line Ending And Encoding Safety

This repository enforces LF via `.gitattributes`. Always normalize when using regex or comparison:

```powershell
$content = (Get-Content -Path $path -Raw) -replace "\r", ''
```

For file writes, use explicit UTF-8 without BOM:

```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedPath, $content, $utf8NoBom)
```

Avoid `Out-File` and `Set-Content` default encoding which varies by platform and PowerShell version.
Prefer `[System.IO.File]` methods for deterministic encoding control.

## Case Sensitivity And File System Differences

Linux file systems are typically case-sensitive; Windows NTFS and default macOS APFS volumes are usually case-insensitive, though macOS can be configured as case-sensitive.

```powershell
# Wrong: may find "Config.json" on Windows but fail on Linux
Test-Path "Config.json"

# Correct: use exact casing that matches the file on disk
Test-Path "config.json"
```

When comparing file names or paths, use `[System.StringComparison]::OrdinalIgnoreCase` explicitly to document intent:

```powershell
if ($fileName.Equals('README.md', [System.StringComparison]::OrdinalIgnoreCase)) { ... }
```

When creating files programmatically, use consistent lowercase or match existing conventions exactly.
File permission differences: Unix requires `chmod +x` for executable scripts; use platform checks before setting permissions.

Environment variable `$env:PATH` uses `;` as separator on Windows and `:` on Unix:

```powershell
$pathSep = if ($IsWindows) { ';' } else { ':' }
$entries = $env:PATH -split [regex]::Escape($pathSep)
```

## Performance And Pipeline Optimization

These are general best practices that improve script speed on all platforms.

Prefer .NET methods over cmdlets for hot paths:

```powershell
# Fast: direct .NET
$lines = [System.IO.File]::ReadAllLines($path)
$exists = [System.IO.File]::Exists($path)

# Slower: cmdlet overhead
$lines = Get-Content -Path $path
$exists = Test-Path -Path $path
```

Avoid `Where-Object` and `ForEach-Object` in tight loops. Use `foreach` statement and `.Where()` method:

```powershell
# Fast: foreach statement
foreach ($item in $collection) { ... }

# Fast: method syntax (PS 7+)
$filtered = $collection.Where({ $_.Status -eq 'Active' })

# Slower: pipeline cmdlets in tight loops
$collection | Where-Object { $_.Status -eq 'Active' }
```

Avoid `+=` on arrays; use `[System.Collections.Generic.List[T]]` or collect from `foreach` output.
Use `-join` operator or `StringBuilder` for string assembly instead of `+=` concatenation.
Suppress unneeded method return values with `$null = $list.Add($x)` or `[void]$list.Add($x)` (faster than `Out-Null`).
Prefer `[pscustomobject]@{}` over `New-Object` for dynamic object creation.

Avoid `Invoke-Expression`; it is slow, unsafe, and breaks static analysis.

## Avoiding Windows-Only APIs And Commands

Commands and APIs that are Windows-only, or whose behavior is Windows-specific:

| Command / API                                       | Cross-Platform Guidance                                                 |
| --------------------------------------------------- | ----------------------------------------------------------------------- |
| `Get-WmiObject` (Windows-only)                      | Prefer `Get-CimInstance` on Windows; on non-Windows use native OS tools |
| `Get-CimInstance` (non-Windows: provider-dependent) | Available in PowerShell 7+, but CIM providers/data are often limited    |
| `Registry` provider (`HKLM:\`)                      | Config files or environment variables                                   |
| `Start-Process -Verb RunAs`                         | `sudo` on Unix (but prompt-interactive)                                 |
| `[System.Windows.Forms]`                            | Windows UI only; use CLI alternatives                                   |
| `Get-Clipboard` / `Set-Clipboard`                   | Platform-specific: `pbcopy/pbpaste`, `xclip`, `clip.exe`                |
| `$env:APPDATA`, `$env:LOCALAPPDATA`                 | `$HOME/.config`, `$HOME/.local/share` (XDG)                             |
| `$env:TEMP`                                         | `[System.IO.Path]::GetTempPath()`                                       |
| `$env:PATH` split by `;`                            | Split by `;` on Windows, `:` on Unix                                    |

`Get-CimInstance` is available in PowerShell 7+ on non-Windows, but CIM data is provider-dependent and often limited compared to Windows.

Mark Windows-only scripts clearly in file paths (e.g., `Scripts/Komorebi/`, `Scripts/WinGet/`).
Shared utility scripts under `Scripts/Utils/` must remain cross-platform.

For `Start-Process` cross-platform pitfalls (exit code race conditions and argument mangling),
see the dedicated sections in `.llm/context.md`.

## Error Handling And Reliability

Always set strict mode and error preference at script top:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
```

Guard `$LASTEXITCODE` access under strict mode (see `powershell-strict-mode-helpers` skill):

```powershell
$lecValue = Get-Variable -Name 'LASTEXITCODE' -ValueOnly -ErrorAction SilentlyContinue
$exitCode = if ($null -ne $lecValue) { [int]$lecValue } else { -1 }
```

Use `try/finally` with `Push-Location`/`Pop-Location` to ensure directory state is restored.

Return empty arrays safely with the comma operator: `return , @()`.

Use `CmdletBinding` and parameter validation on all functions.
Prefer `[Parameter(Mandatory)]` over manual null checks.

Emit structured error codes (`E_PREFIX_DETAIL`) for actionable diagnostics.

## Workflow

1. Use `Join-Path` and `[System.IO.Path]` for all path construction.
2. Use `$IsWindows`, `$IsMacOS`, `$IsLinux` for platform branching.
3. Normalize line endings before regex or string comparison.
4. Use exact file name casing; test on case-sensitive file systems.
5. Write files with explicit UTF-8 no-BOM encoding.
6. Prefer .NET methods over cmdlets in performance-sensitive code.
7. Mark platform-specific scripts by directory; keep shared utilities portable.
8. See `context.md` for `Start-Process` safety and file-handle patterns.

## References

- `Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1` (path normalization example)
- `Scripts/Utils/Quality/Invoke-FullValidation.ps1` (strict mode, error handling)
- `Scripts/Utils/Common/StrictModeHelpers.ps1` (shared helper patterns)
- `.gitattributes` (line ending enforcement)
- `.llm/context.md` (Start-Process safety, file-handle safety, empty array return)
