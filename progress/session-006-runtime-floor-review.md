# Session 006: runtime-floor review correction

## Finding

Cursor Bugbot identified that the TypeScript 7 dependency graph brings `entities@8`, whose Node engine requirement is newer than the extension's previous VS Code `^1.90.0` runtime floor.

## Changes

- Raised the extension runtime floor to the VS Code release line that provides the modern Node extension host.
- Reworked the runtime-policy test to validate semver shape and compatibility floors instead of asserting exact dependency or engine versions, keeping Dependabot upgrades test-independent.
- Derived the `entities` dependency range from `markdown-it`'s lockfile entry and validated its declared Node engine contract.

## Verification

- `npm test`: 277 passing.
- Staged pre-commit checks passed.
- PR #51 required CI lanes passed, including extension compilation/tests, PowerShell 5.1/7, pre-commit, compatibility, Windows, macOS, and devcontainer validation.
