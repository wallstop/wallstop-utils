# Cross-Platform PowerShell (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/cross-platform-powershell.md`.
Applies to shared scripts (e.g., `Scripts/Utils/`); platform-specific directories like `Scripts/Komorebi/` are exempt.
Shared repository PowerShell must run on both Windows PowerShell 5.1 and PowerShell 7+.

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

## Literal Paths, Validation, And Canonicalization

Use `-LiteralPath` for user-supplied or config-driven paths so wildcard characters are not expanded accidentally.

```powershell
# Safe: literal handling for special characters
Test-Path -LiteralPath '[archive] report.txt' -PathType Leaf
Get-Item -LiteralPath '[archive] report.txt'
```

Use `Test-Path` for existence checks and `-PathType` for explicit file/directory intent.
Use `Resolve-Path` for canonicalization of existing paths before comparisons.

```powershell
if (Test-Path -LiteralPath $path -PathType Container) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
}
```

`Resolve-Path` only resolves paths that already exist. For paths that may not exist yet,
validate intent with `Test-Path` and handle creation separately.

## Directory Traversal, Providers, And Symlinks

`Get-ChildItem` behavior varies by provider. FileSystem-specific guidance does not always apply
to providers like Registry or Certificate.

For FileSystem scans, prefer `-Filter` when possible because it is applied by the provider.

```powershell
# Provider-side filtering (preferred for large trees)
Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File
```

Use `-Depth` as an optional bound for deep or untrusted trees; do not require it for every recursion.

```powershell
# Optional bounded recursion for large trees
Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Filter '*.log' -File
```

By default, `Get-ChildItem -Recurse` does not recurse into directory symlink targets.
Use `-FollowSymlink` only when that behavior is explicitly intended.

## OS Detection And Conditional Logic

Use the repository compatibility helpers for OS detection. `$IsWindows`, `$IsMacOS`,
and `$IsLinux` do not exist on Windows PowerShell 5.1 and throw under strict mode.

```powershell
if (Test-IsWindowsPlatform) {
    # Windows-specific logic
} elseif (Test-IsMacOSPlatform) {
    # macOS-specific logic
} elseif (Test-IsLinuxPlatform) {
    # Linux-specific logic
}
```

Dot-source `Scripts/Utils/Common/CompatibilityHelpers.ps1` before using these helpers.
Do not use `[System.Runtime.InteropServices.RuntimeInformation]`, `$env:OS`, or bare
PowerShell 7+ automatic variables for OS detection in shared scripts. For other runtime
facts that require .NET APIs, follow the compatibility guard and justified
`SuppressMessageAttribute` guidance in `.llm/context.md`.

For commands that differ by platform, use a lookup pattern:

```powershell
$openCmd = if (Test-IsWindowsPlatform) { 'start' } elseif (Test-IsMacOSPlatform) { 'open' } else { 'xdg-open' }
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
When reading redirected native process stderr from a temp file, use `Read-RedirectedProcessText`
from `CompatibilityHelpers.ps1` instead of fixed UTF-8 `ReadAllText`; Windows PowerShell 5.1
can write UTF-16LE with a BOM while PowerShell 7+ normally writes UTF-8.

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

PowerShell command names, parameter names, variable names, type/member names, and member
invocation are generally case-insensitive. AST-backed policy checks that model PowerShell
language behavior should use case-insensitive comparisons (`-ieq`/`-ine`, helper functions,
or case-insensitive collections) for those identifiers, while keeping file/path comparisons
platform-appropriate.

When creating files programmatically, use consistent lowercase or match existing conventions exactly.
File permission differences: Unix requires `chmod +x` for executable scripts; use platform checks before setting permissions.
When resolving POSIX/native tools from PowerShell (`chmod`, `readlink`, `test`), use
`Get-Command -CommandType Application` and invoke `.Path` with `.Source` fallback; do not
allow functions, aliases, or Pester helpers to shadow the external executable.

Environment variable `$env:PATH` uses `;` as separator on Windows and `:` on Unix:

```powershell
$pathSep = if (Test-IsWindowsPlatform) { ';' } else { ':' }
$entries = $env:PATH -split [regex]::Escape($pathSep)
```

## Process And Git Bash Environment Isolation

When tests launch Git Bash from PowerShell on Windows, do not assume a `ProcessStartInfo`
`PATH` replacement becomes Bash's exact runtime `PATH`. Git Bash/MSYS startup can add
or reorder entries such as `/mingw64/bin` before the command runs.

For fake-command harnesses, use a non-login shell (`--noprofile --norc`) and make the
test bin directory win inside Bash after startup, for example with a Bash-visible
`BASH_ENV` file that prepends the converted fake-bin path. Assert command precedence
with `command -v`/`type -a` diagnostics rather than assuming the whole `PATH` string
is identical to the PowerShell environment value.

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

# Fast: PowerShell collection method syntax
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

| Command / API                                           | Cross-Platform Guidance                                                                                        |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `Get-WmiObject` (Windows-only)                          | Prefer `Get-CimInstance` on Windows; on non-Windows use native OS tools                                        |
| `Get-CimInstance` (cross-platform; non-Windows limited) | Available in PowerShell 7+; Windows has broad coverage, while non-Windows CIM providers/data are often limited |
| `Registry` provider (`HKLM:\`)                          | Config files or environment variables                                                                          |
| `Start-Process -Verb RunAs`                             | `sudo` on Unix (but prompt-interactive)                                                                        |
| `[System.Windows.Forms]`                                | Windows UI only; use CLI alternatives                                                                          |
| `Get-Clipboard` / `Set-Clipboard`                       | Platform-specific: `pbcopy/pbpaste`, `xclip`, `clip.exe`                                                       |
| `$env:APPDATA`, `$env:LOCALAPPDATA`                     | `$HOME/.config`, `$HOME/.local/share` (XDG)                                                                    |
| `$env:TEMP`                                             | `[System.IO.Path]::GetTempPath()`                                                                              |
| `$env:PATH` split by `;`                                | Split by `;` on Windows, `:` on Unix                                                                           |

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

For nested workflows, use a named stack to avoid collisions with outer scope location management.

```powershell
Push-Location -LiteralPath $workDir -StackName 'Validation'
try {
    # perform work in $workDir
} finally {
    Pop-Location -StackName 'Validation' -ErrorAction SilentlyContinue
}
```

Return empty arrays safely with the comma operator: `return , @()`.

Use `CmdletBinding` and parameter validation on all functions.
Prefer `[Parameter(Mandatory)]` over manual null checks.

Emit structured error codes (`E_PREFIX_DETAIL`) for actionable diagnostics.

## Workflow

1. Use `Join-Path` and `[System.IO.Path]` for all path construction.
2. Use `Test-IsWindowsPlatform`, `Test-IsMacOSPlatform`, and `Test-IsLinuxPlatform` for platform branching.
3. Normalize line endings before regex or string comparison.
4. Use exact file name casing; test on case-sensitive file systems.
5. Write files with explicit UTF-8 no-BOM encoding.
6. Prefer .NET methods over cmdlets in performance-sensitive code.
7. Use `-LiteralPath` for external paths and `Test-Path -PathType` for existence/type validation.
8. Canonicalize existing paths before comparison or persistence.
9. Mark platform-specific scripts by directory; keep shared utilities portable.
10. See `context.md` for `Start-Process` safety and file-handle patterns.

## References

- `Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1` (path normalization example)
- `Scripts/Utils/Quality/Invoke-FullValidation.ps1` (strict mode, error handling)
- `Scripts/Utils/Common/StrictModeHelpers.ps1` (shared helper patterns)
- `.gitattributes` (line ending enforcement)
- `.llm/context.md` (Start-Process safety, file-handle safety, empty array return)
- [Get-ChildItem (PowerShell 7.5)](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-childitem?view=powershell-7.5)
- [Set-Location (PowerShell 7.5)](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/set-location?view=powershell-7.5)
- [Test-Path (PowerShell 7.5)](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/test-path?view=powershell-7.5)
- [Resolve-Path (PowerShell 7.5)](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/resolve-path?view=powershell-7.5)
- [about_Providers (PowerShell 7.5)](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_providers?view=powershell-7.5)
