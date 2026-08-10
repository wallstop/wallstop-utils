# Session 019: Small-language analyzer evaluation

Date: 2026-08-10

Scope: resolve issue #62 after the managed warnings-as-errors lanes were completed.

JavaScript decision:

- The only tracked hand-written JavaScript files are `scripts/install-local.js`,
  `scripts/package-vsix.js`, and `scripts/run-tests.js` under
  `Extensions/WallstopPrComments/`.
- The extension already uses TypeScript compilation and a Node test suite; the
  three utility scripts are directly exercised by the extension packaging and
  installation tests.
- ESLint would add a separate dependency/configuration surface and a heavier
  PR lane for three utility scripts. The material remaining invariant is parse
  validity, so the extension workflow now runs the built-in, dependency-free
  `node --check` command for all three files through `npm run lint:scripts`.

AppleScript decision:

- The four tracked `.scpt` files are `Config/Mac/activate-windows.scpt`,
  `Config/Mac/minimize-window.scpt`, `Scripts/Mac/activate-windows.scpt`, and
  `Scripts/Mac/minimize-window.scpt`.
- macOS provides the relevant migration-safe checks used here: text sources are
  compiled with `osacompile`; compiled artifacts are decompiled with
  `osadecompile` and recompiled when source files are unavailable.
- No additional third-party AppleScript linter is required for these compiled
  artifacts; the existing validator remains platform-gated and fail-closed when
  the tools are available.

Decision: close issue #62 after the JavaScript syntax gate and this documented
AppleScript limitation land. Issue #46 remains separate because it requires a
live Windows backup transport run.
