# Devcontainer Bootstrap (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/devcontainer-bootstrap.md`.

## Devcontainer Baseline Toolchain

Use the repository devcontainer bootstrap to keep local quality tooling consistent with CI expectations.

Run quality work in the provided container baseline to reduce host-specific drift.

Prefer an image-first devcontainer contract for reliability and rebuild speed:

- Pin `.devcontainer/devcontainer.json` `image` to an official `mcr.microsoft.com/devcontainers/*@sha256:...` digest.
- Avoid `build` and non-empty `features` in this repository's end-user devcontainer; feature mutation during build is a common transient network failure source.
- Keep `init: true` in `.devcontainer/devcontainer.json` for stronger startup/shutdown process hygiene.
- Keep persistent cache mounts for `/home/vscode/.cache/pip`, `/home/vscode/.cache/pre-commit`, and `/home/vscode/.npm` to reduce repeat cold-start bootstrap cost.
- Keep project-specific tool bootstrap in `.devcontainer/post-create.sh`, bounded by timeout guards and explicit non-blocking diagnostics.
- Keep Codex bootstrap opt-in via `WALLSTOP_DEVCONTAINER_ENABLE_CODEX=1` so default cold-start attach remains fast and reliable.

## Post-Create Bootstrap Expectations

Confirm that pre-commit hooks and PowerShell quality modules are installed during container bootstrap.
Bootstrap should also run `Invoke-FullValidation.ps1 -PreflightOnly` once in non-blocking mode so module/tooling drift is surfaced before commit-time hooks.

## Parity Commands Before PR

Run the same documented local quality commands before opening or updating a pull request.

## Commands

```bash
pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-FullValidation.ps1 -PreflightOnly
pre-commit run
pre-commit run --all-files
pwsh -NoLogo -NoProfile -File Scripts/Utils/Run-PreCommitValidation.ps1
```

## References

- `.devcontainer/devcontainer.json`
- `.devcontainer/post-create.sh`
- `README.md`
- `Scripts/Utils/Run-PreCommitValidation.ps1`
