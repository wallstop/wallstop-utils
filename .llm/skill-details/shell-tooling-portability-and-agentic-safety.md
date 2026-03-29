# Shell Tooling Portability And Agentic Safety (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/shell-tooling-portability-and-agentic-safety.md`.

## Mandatory Baseline

Use this baseline for production shell scripts and non-trivial agent-generated shell edits.

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Also require:

1. Preflight dependency checks with `command -v tool >/dev/null 2>&1`.
2. Explicit input validation for required files, paths, and permissions.
3. No silent failures. Emit actionable diagnostics to stderr.
   - Actionable means the message identifies the failed check and a concrete next step.
   - Good: `E_FILE_NOT_FOUND: expected /path/to/file; verify with ls -la`.
   - Anti-pattern: `Error` or `Failed` without context.

## GNU vs BSD Portability Guardrails

Cross-platform scripts must account for GNU/Linux and macOS BSD userland differences.

1. Use `grep -E` and `grep -F`; avoid deprecated `egrep` and `fgrep` forms.
2. Avoid assumptions about `sed -i` behavior. Portable pattern:
   - write to a temp file,
   - validate output,
   - then atomically replace.
3. Prefer POSIX-safe shell features unless Bash-specific behavior is required.
4. Avoid hardcoding system-specific paths and binaries when portable alternatives exist.
5. Use explicit locale control (`LC_ALL=C`) only when deterministic collation or large text throughput is needed.

## awk Patterns

1. Use `awk` for field-based transformations when delimiters are stable.
2. Prefer explicit field separators with `-F` instead of implicit defaults.
3. Keep expressions POSIX-compliant for portability; avoid GNU-only extensions unless GNU awk is a deliberate requirement.

Examples:

```bash
awk '{print $2, $1}' input.txt
awk -F: '$3 > 1000 {print $1}' /etc/passwd
```

## Reliability Patterns

### Quote everything that can expand

- Use `"$var"` and `"$@"`.
- Avoid unquoted expansions that trigger word-splitting or globbing.

### Use null-delimited file flows

Prefer:

```bash
find . -type f -print0 | xargs -0 -I{} your_command "{}"
```

or:

```bash
while IFS= read -r -d '' path; do
  your_command "$path"
done < <(find . -type f -print0)
```

### Keep channels clean

- Data output on stdout.
- Warnings and errors on stderr.
- This is mandatory for composable pipelines and predictable parsing.

### Prefer explicit cleanup

When temp files or locks are used, add cleanup hooks:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
```

## Performance Patterns

Performance guidance should be measurable and workload-specific.

1. Use `grep -F` for fixed-string search.
2. For large ASCII-heavy scans (for example, repeated passes over files larger than about 10MB), `LC_ALL=C` can reduce locale overhead; measure before standardizing.
3. Avoid unnecessary process spawning in tight loops when a shell builtin is simpler.
4. For large-scale search workloads, consider `rg` where available.
5. Do not hardcode absolute speedup claims in policy docs. State tradeoffs and measure in context.

## Agentic Workflow Patterns

These patterns are critical when scripts are generated or edited by autonomous agents.

1. Dry-run first for mutating operations (`--dry-run` or equivalent behavior).
2. Idempotence by default: repeated runs should converge, not corrupt state.
3. Bounded execution for external commands that can hang:
   - Use `timeout` where available (typically GNU coreutils environments).
   - On macOS, prefer `gtimeout` if GNU coreutils is installed.
   - If neither is available, use a guarded background+kill fallback.
   - Example: `timeout 10s curl -fsS https://example.com || { echo "E_REQUEST_TIMEOUT" >&2; exit 1; }`
4. Prefer deterministic command ordering and stable output formatting.
5. Avoid interactive prompts in unattended paths unless explicitly requested.
6. Break complex pipelines into reviewable steps when correctness is more important than terseness.

## Anti-Patterns And Replacements

| Brittle pattern | Safer replacement | Why |
| --- | --- | --- |
| `for f in $(ls)` | null-delimited `find ... -print0` loop | Handles spaces/newlines safely |
| bare `sed -i` across OSes | temp file rewrite + move | GNU and BSD `sed -i` semantics differ; temp rewrite avoids cross-OS breakage |
| `egrep` / `fgrep` | `grep -E` / `grep -F` | Modern, non-deprecated forms |
| data and logs both on stdout | data stdout + logs stderr | Keeps machine-readable output stable |
| non-idempotent mutate-once logic | state check + converge semantics | Safe repeated automation runs |
| unbounded external calls | explicit timeout strategy | Prevents hangs in agent loops |

## Evidence Quality And Source Weighting

Use high-signal sources for policy and treat community sources as supplemental context.

High confidence:

1. DigitalOcean tutorial on advanced Bash scripting (recent).
2. Current GitHub ecosystem guidance from curated agent-skill repositories.
3. Stack Overflow thread history on large-file grep tuning (`LC_ALL=C`, `grep -F`, parallelization caveats).

Supplemental or lower confidence:

1. Older Reddit discussions are useful for historical consensus but can include outdated thresholds.
2. Blog/tutorial posts behind anti-bot or access limits should not be sole policy basis.

## References Used During Research

1. https://www.reddit.com/r/devops/comments/7baj4c/shell_scripting_best_practices/
2. https://medium.com/@namanabhavya2001/deep-dive-into-grep-awk-and-sed-for-devops-engineers-f5e6ab438ba2
3. https://medium.com/@deveshbajaj59/a-comprehensive-tutorial-on-using-awk-grep-and-bash-functions-in-shell-scripting-88a3c53cbbf0
4. https://www.digitalocean.com/community/tutorials/advanced-bash-scripting
5. https://github.com/ComposioHQ/awesome-claude-skills
6. https://github.com/VoltAgent/awesome-agent-skills
7. https://stackoverflow.com/questions/13913014/grepping-a-huge-file-80gb-any-way-to-speed-it-up

## Commands

```bash
bash -n script.sh
shellcheck script.sh
pre-commit run --hook-stage pre-commit shellcheck
```
