# Wallstop PR Comments

VS Code sidebar for copying GitHub pull request review comments and exposed suggested changes.

## Local Setup

From this directory:

```bash
npm run install:local
```

That one command restores dependencies, runs the extension tests, packages a VSIX with `scripts/package-vsix.js`, installs it with the first available VS Code-family CLI (`code`, `code-insiders`, `codium`, or `code-oss`), and then prints a reload reminder.

Run it as your normal VS Code user, not with `sudo`. The installer uses this extension's ignored `.npm-cache` directory by default so a broken or root-owned user npm cache does not block setup.

For development setup without installing into VS Code:

```bash
npm run setup
```

Use `node scripts/install-local.js --help` for options, including `--code-cli` for VS Code Insiders, VSCodium, Code OSS, or portable installations. You can also set `WALLSTOP_VSCODE_CLI`.
