# Post-Work Self-Improvement (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/post-work-self-improvement.md`.

## Purpose

Every significant piece of work generates knowledge — new patterns, failure categories,
techniques, corrections, or architectural insights. Without systematic capture, this
knowledge disperses and the same mistakes recur. This workflow ensures agents
systematically analyze completed work, extract durable knowledge, and update the
repository's guidance infrastructure so future sessions start smarter.

## Trigger Criteria

Execute this workflow when **any** of the following apply to the work just completed:

1. Changes span multiple files or subsystems.
2. A new failure category or invariant was discovered during the work.
3. The work required novel problem-solving not covered by existing skills.
4. Changes touch safety-critical paths (backup/restore, destructive ops, git mutations).
5. Changes touch `.llm/` skills, context, workflows, or harness tooling.
6. The work involved debugging a non-obvious issue whose root cause should be documented.
7. A workaround was applied that future agents should know about.
8. Cross-platform or environment-specific behavior was encountered.

If none apply, skip the workflow and note the skip decision briefly.

## Analysis Phase

A dedicated sub-agent performs the analysis. The sub-agent receives:

- The full diff of changes made in the session.
- Any error messages, test failures, or diagnostics encountered.
- The current `.llm/` skills and context for reference.

The sub-agent must produce a structured analysis covering:

### What was done

- Summary of changes and their purpose.
- Files modified, created, or deleted.
- Problems encountered and how they were resolved.

### What was learned

- New patterns or techniques applied.
- Failure categories discovered (with root cause analysis).
- Existing guidance that proved incorrect, incomplete, or missing.
- Cross-cutting concerns that affect multiple subsystems.

### What should change

- Specific proposed updates to `.llm/` files (skills, context, workflows).
- New skill cards or detail documents needed.
- Existing rules that need amendment or retirement.
- Memory entries worth persisting for future sessions.
- New test cases or policy tests needed to enforce discovered invariants.

## Knowledge Extraction

Knowledge falls into these categories, each with a different capture mechanism:

### Category 1: New invariants

Patterns that must always hold and can be mechanically enforced.

- **Capture**: Add to `context.md` authoritative rules + policy test in
  `ScriptSafetyConventions.Tests.ps1`.
- **Example**: "All `OpenRead` calls must use `using` or `try/finally`."

### Category 2: Best practices

Guidance that improves quality but cannot always be mechanically enforced.

- **Capture**: Add to relevant skill card + expanded detail.
- **Example**: "Prefer `ProcessStartInfo.ArgumentList` over `-ArgumentList` string."

### Category 3: Trivia and environment facts

Useful context that saves debugging time but does not warrant a rule.

- **Capture**: Store in repository memory via the memory tool.
- **Example**: "macOS `/var` is a symlink to `/private/var`."

### Category 4: Workflow improvements

Changes to how agents should sequence work or use tools.

- **Capture**: Update `validation-workflow.md` or create new workflow documents.
- **Example**: "Run index generation before harness tests to avoid stale-index failures."

### Category 5: Corrections to existing guidance

Existing rules that are wrong, outdated, or overly broad.

- **Capture**: Amend the specific rule in `context.md` or skill files. Add a comment
  explaining why the correction was needed.
- **Example**: "Rule 14 said X, but Y is actually correct because..."

## Self-Update Protocol

When proposing updates, follow these constraints:

1. **Minimal diff**: Change only what is necessary. Do not rewrite surrounding text.
2. **Category-level**: Prefer general rules over one-off exceptions.
3. **Testable**: If a rule can be enforced by a policy test, propose the test.
4. **Consistent**: Match the style and structure of existing guidance.
5. **Under limits**: Keep skill cards ≤ 80 lines, all `.llm/` files ≤ 300 lines.
6. **Regenerate index**: After any skill card change, run `Update-LlmSkillsIndex.ps1`.
7. **Validate harness**: After any `.llm/` change, run `Test-LlmHarness.ps1`.

## Adversarial Consensus Loop

Quality assurance uses an adversarial multi-agent loop:

### Step 1: Proposal (Proposer sub-agent)

The proposer sub-agent analyzes the completed work and drafts concrete proposals
for knowledge capture and guidance updates. Output must be specific and actionable —
not vague suggestions but exact text changes with file paths and line references.

### Step 2: Adversarial review (Reviewer sub-agent)

A separate sub-agent reviews the proposals with zero access to the proposer's
reasoning (see [Adversarial Handoff Protocol](adversarial-handoff-protocol.md)). The reviewer must:

- Challenge every proposed change for accuracy and necessity.
- Identify missing knowledge that the proposer overlooked.
- Flag over-engineering: unnecessary rules, excessive detail, or scope creep.
- Flag under-engineering: important patterns not captured.
- Verify consistency with existing guidance (no contradictions).
- Rate overall quality honestly on a strict scale.

### Step 3: Resolution (Resolver sub-agent)

If the reviewer identifies issues, a resolver sub-agent:

- Considers each recommendation independently.
- Implements accepted changes to the proposals.
- Documents rejected recommendations with clear rationale.
- Produces the final refined proposal set.

### Step 4: Consensus check

Repeat steps 2-3 until the adversarial reviewer confirms:

- **Zero unresolved issues** — every finding addressed or explicitly accepted.
- **No quality gaps** — nothing important is missing.
- **No over-engineering** — no unnecessary additions.
- **Complete and concise** — each finding addressed with clear rationale, no critical gaps remain.

Only then are the updates applied to the actual files.

### Consensus termination

To prevent infinite loops:

- Maximum 3 adversarial iterations per workflow execution.
- If consensus is not reached after 3 iterations, apply the best version achieved
  and document remaining concerns in `/memories/session/` via the memory tool.
- Each iteration must show measurable progress (fewer findings, higher quality rating).

## Integration With Existing Workflows

This workflow integrates with the existing session-close validation:

1. Complete the primary work.
2. Run `Invoke-FullValidation.ps1` to verify work correctness.
3. **Execute this self-improvement workflow** (analyze, extract, propose, review, apply).
4. Run `Update-LlmSkillsIndex.ps1` if skills were modified.
5. Run `Test-LlmHarness.ps1` to validate `.llm/` consistency.
6. Run `Invoke-FullValidation.ps1` again to verify self-improvement changes.
7. Push and watch CI.

## Anti-Patterns

Avoid these common failure modes:

1. **Skipping the workflow** because "nothing was learned" — even confirming existing
   guidance is valid is a useful signal worth brief documentation.
2. **Vague proposals** like "update the docs" — every proposal must be a specific
   text change with file path.
3. **Over-capturing** trivia that will never be referenced again — apply judgment
   about what genuinely helps future sessions.
4. **Self-referential loops** where the workflow updates itself endlessly — bound
   iterations and focus on the primary work's knowledge, not meta-workflow tweaks.
5. **Contradicting existing rules** without explicit rationale — always explain why
   a correction is needed, not just what changed.

## References

- [Validation Workflow](../validation-workflow.md)
- [Adversarial Handoff Protocol](adversarial-handoff-protocol.md)
- [Cross-Language Quality Gate](cross-language-quality-gate.md)
- [LLM Context](../context.md)
- [Codify New Knowledge](../validation-workflow.md)
