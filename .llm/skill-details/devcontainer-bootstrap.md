# Devcontainer Bootstrap (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/devcontainer-bootstrap.md`.

## Devcontainer Baseline Toolchain

Use the repository devcontainer bootstrap to keep local quality tooling consistent with CI expectations.

Run quality work in the provided container baseline to reduce host-specific drift.

## Post-Create Bootstrap Expectations

Confirm that pre-commit hooks and PowerShell quality modules are installed during container bootstrap.

## Parity Commands Before PR

Run the same documented local quality commands before opening or updating a pull request.

## Commands

```bash
pre-commit run
pre-commit run --all-files
pwsh -NoLogo -NoProfile -File Scripts/Utils/Run-PreCommitValidation.ps1
```

## References

- `.devcontainer/devcontainer.json`
- `.devcontainer/post-create.sh`
- `README.md`
- `Scripts/Utils/Run-PreCommitValidation.ps1`
