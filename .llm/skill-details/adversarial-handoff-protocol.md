# Adversarial Handoff Protocol (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/adversarial-handoff-protocol.md`.

## Known vs Unknown Invariants

Policy tests enforce **known** invariants: `-LiteralPath` usage, stream disposal, empty-array safety,
git sequencing order, and other patterns already codified in `ScriptSafetyConventions.Tests.ps1`.

Adversarial review discovers **unknown** invariants: failure modes that no existing test checks for.
Both layers are necessary. Policy tests prevent known regressions cheaply; adversarial review
finds the regressions you don't yet know to test for.

When an adversarial pass reveals a new category, codify it per the
[Codify New Knowledge](../validation-workflow.md) section so it becomes a known invariant
with mechanical enforcement.

## Zero-Knowledge Handoff

A zero-knowledge handoff means the reviewer receives only:

1. The diff (changed files and lines).
2. Test output (pass/fail, diagnostics, error codes).
3. The `.llm/` skill and context files.

No conversation history, no verbal rationale, no session notes. If the change is not
self-evident from those three artifacts, it needs better commit messages, test names,
or inline comments. This constraint reveals documentation gaps that would otherwise
hide behind tribal knowledge.

Use zero-knowledge handoffs for:

- Safety-contract changes (backup/restore orchestrators, destructive operations).
- Cross-platform path handling or file-discovery logic changes.
- Any change to `.llm/` skills, context, or harness tooling.

## Red/Green Team Pass

**Red pass** (adversarial): actively try to break the change.

- Inject unexpected input: paths with spaces, brackets, wildcards, unicode characters.
- Remove safety guards mentally: what happens if `-LiteralPath` is changed to `-Path`?
- Probe concurrency: what if two backup sessions run simultaneously?
- Check partial-failure paths: source validated, destination cleared, then copy fails midway.
- Verify platform edges: does this behave differently on Windows vs macOS vs Linux?
- Test empty/maximum bounds: empty directories, zero-length files, paths at `MAX_PATH`.
- Question return semantics: does `return @()` unwrap to `$null` at any call site?

**Green pass** (hardening): for each red-team finding, either:

1. **Fix**: Write the code change and regression test before merge.
2. **Accept risk**: Document why the scenario is unreachable with a code comment.
3. **Defer**: File as a tracked issue with the specific scenario description.

Any red finding that reveals a _category_ (not just a single instance) must be
codified per the validation-workflow.md [Codify New Knowledge](../validation-workflow.md) section.

## Extreme Test Scenarios

When writing tests for new or changed invariants, systematically cover:

1. **Empty input**: empty strings, empty arrays, empty directories, `$null`.
2. **Maximum input**: paths at `MAX_PATH`, large file counts, deeply nested directories.
3. **Special characters**: spaces, brackets `[]`, backticks, unicode, glob wildcards `*?`.
4. **Concurrent access**: two processes writing the same destination.
5. **Platform boundaries**: path separators, case sensitivity, line endings, env variable formats.
6. **Error paths**: permission denied, disk full, network timeout, process crash mid-operation.
7. **Return semantics**: verify `.Count`, pipeline behavior, and `$null` propagation.

Prefer these scenario categories over happy-path-only coverage. A test that only
verifies the success path provides false confidence about production reliability.

## Scope

This protocol applies to changes touching:

- Backup/Restore Safety Contract rules or orchestrator scripts.
- Destructive operations (`Remove-Item -Recurse`, `robocopy /MIR`, git force operations).
- Cross-platform path handling or file-discovery logic.
- `.llm/` skills, context, or harness validation tooling.

Not every typo fix or documentation update needs adversarial review.

## References

- [Backup/Restore Safety Contract](../context.md)
- [Codify New Knowledge](../validation-workflow.md)
- `Tests/Utils/ScriptSafetyConventions.Tests.ps1`
