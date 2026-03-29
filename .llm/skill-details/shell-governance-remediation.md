# Shell Governance And Remediation (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/shell-governance-remediation.md`.

## Fix-First Remediation Loop

Apply strict shell lint governance while keeping AI remediation changes minimal and reviewable.

1. Reproduce failures on the current tree.
2. Patch narrowly to fix reported issues.
3. Format touched shell files.
4. Re-run lint and policy tests.
5. Re-run hooks to confirm end-to-end green status.

## Suppression Governance With Reasons

Only use targeted suppression with adjacent reason text.

Never use broad disable directives or suppression without explicit justification.

## Deep-Dive Remediation Contract

For complete remediation workflow, suppression template, and verification checklist, see:

- [LLM Remediation Contract](./shell-governance/llm-remediation-contract.md)

## References

- `.shellcheckrc`
- `.llm/skill-details/shell-governance/llm-remediation-contract.md`
- `Scripts/Utils/Quality/README.md`
- `README.md`
