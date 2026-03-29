# PowerShell Strict Mode Helpers (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/powershell-strict-mode-helpers.md`.

## Strict-Mode-Safe LASTEXITCODE Access

Keep PowerShell utilities safe under strict mode and robust in fresh shell sessions.

Bare LASTEXITCODE access can throw in strict mode before any native command runs.

Use guarded variable reads:

```powershell
$lecValue = Get-Variable -Name 'LASTEXITCODE' -ValueOnly -ErrorAction SilentlyContinue
$exitCode = if ($null -ne $lecValue) { [int]$lecValue } else { -1 }
```

## Optional Module Resolution Helpers

Resolve optional quality dependencies through helper-based imports before failing configuration checks.

This keeps autoload-disabled shells usable when dependencies are installed.

## Stable Diagnostics For Policy Tests

Keep error identifiers and validation messages deterministic so policy tests remain reliable.

Prefer helper reuse over duplicated snippets that drift over time.

## Workflow

1. Enable strict mode and stop-on-error in utility scripts.
2. Use optional module import helpers before failing config checks.
3. Read native exit-code state with strict-safe guard logic.

## References

- `Scripts/Utils/Run-PreCommitValidation.ps1`
- `Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1`
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
