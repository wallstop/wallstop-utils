import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

test('package manifest main points at the compiled extension entrypoint', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as { main?: string };

  const main = manifest.main;
  if (typeof main !== 'string') {
    throw new Error('package.json main must be a string.');
  }
  assert.equal(existsSync(join(extensionRoot, main)), true);
});

test('package manifest declares the includeDiffHunks setting defaulting to true', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as {
    contributes?: { configuration?: { properties?: Record<string, { type?: string; default?: unknown }> } };
  };

  const property = manifest.contributes?.configuration?.properties?.['wallstopPrComments.includeDiffHunks'];
  assert.ok(property, 'wallstopPrComments.includeDiffHunks must be declared');
  assert.equal(property.type, 'boolean');
  assert.equal(property.default, true);
});

test('package manifest routes npm test through the cross-platform test runner', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as {
    scripts?: { test?: string };
  };

  assert.equal(manifest.scripts?.test, 'npm run compile && node scripts/run-tests.js');
});

test('TypeScript compiler keeps unused declarations as errors', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const compilerConfig = JSON.parse(readFileSync(join(extensionRoot, 'tsconfig.json'), 'utf8')) as {
    compilerOptions?: { noUnusedLocals?: boolean; noUnusedParameters?: boolean };
  };

  assert.equal(compilerConfig.compilerOptions?.noUnusedLocals, true);
  assert.equal(compilerConfig.compilerOptions?.noUnusedParameters, true);
});

test('package manifest declares opt-out auto-refresh settings (enabled by default)', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as {
    contributes?: { configuration?: { properties?: Record<string, { type?: string; default?: unknown; minimum?: number }> } };
  };

  const properties = manifest.contributes?.configuration?.properties ?? {};
  const enabled = properties['wallstopPrComments.autoRefresh.enabled'];
  assert.ok(enabled, 'wallstopPrComments.autoRefresh.enabled must be declared');
  assert.equal(enabled.type, 'boolean');
  assert.equal(enabled.default, true, 'auto-refresh must be opt-out (default true)');

  const interval = properties['wallstopPrComments.autoRefresh.intervalMinutes'];
  assert.ok(interval, 'wallstopPrComments.autoRefresh.intervalMinutes must be declared');
  assert.equal(interval.type, 'number');
  assert.equal(interval.minimum, 1);
});

test('package manifest declares the per-repository refreshRepo command with a refresh icon', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as {
    contributes?: { commands?: Array<{ command?: string; title?: string; icon?: string }> };
  };

  const command = manifest.contributes?.commands?.find(
    (entry) => entry.command === 'wallstopPrComments.refreshRepo',
  );
  assert.ok(command, 'wallstopPrComments.refreshRepo command must be declared');
  assert.equal(command.icon, '$(refresh)');
});

test('package manifest pins refreshRepo inline on repository tree items', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as {
    contributes?: { menus?: { 'view/item/context'?: Array<{ command?: string; when?: string; group?: string }> } };
  };

  const itemMenus = manifest.contributes?.menus?.['view/item/context'] ?? [];
  const refreshRepoMenu = itemMenus.find((entry) => entry.command === 'wallstopPrComments.refreshRepo');
  assert.ok(refreshRepoMenu, 'refreshRepo must appear in view/item/context');
  assert.match(refreshRepoMenu.when ?? '', /viewItem == repository/u);
  assert.match(refreshRepoMenu.group ?? '', /^inline(@\d+)?$/u, 'refreshRepo must render inline on the repository node');
});

test('extension runtime floor supports the Node version required by production dependencies', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const repositoryRoot = join(extensionRoot, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as {
    engines?: { vscode?: string };
  };
  const lockfile = JSON.parse(readFileSync(join(extensionRoot, 'package-lock.json'), 'utf8')) as {
    packages?: {
      [key: string]: {
        dependencies?: { [key: string]: string };
        engines?: { node?: string };
      };
    };
  };
  const workflow = readFileSync(join(repositoryRoot, '.github', 'workflows', 'extension-tests.yml'), 'utf8');

  const vscodeEngineMatch = /^\^(\d+)\.(\d+)\.(\d+)$/u.exec(manifest.engines?.vscode ?? '');
  assert.ok(vscodeEngineMatch, 'the VS Code engine floor must be a caret semver range');
  assert.ok(Number(vscodeEngineMatch[2]) >= 101, 'the VS Code floor must provide the modern Node extension host');

  const markdownItPackage = lockfile.packages?.['node_modules/markdown-it'];
  const entityPackageName = markdownItPackage?.dependencies?.entities;
  assert.match(entityPackageName ?? '', /^\^\d+\.\d+\.\d+$/u, 'markdown-it must declare a semver entities dependency');

  const entityPackage = lockfile.packages?.[`node_modules/entities`];
  const nodeEngineMatch = /^>=(\d+)\.(\d+)\.(\d+)$/u.exec(entityPackage?.engines?.node ?? '');
  assert.ok(nodeEngineMatch, 'the production entity dependency must declare a minimum Node engine');
  assert.ok(Number(nodeEngineMatch[1]) >= 20, 'the extension must not package an entity dependency requiring an obsolete Node major');
  assert.match(
    workflow,
    /uses:\s*actions\/setup-node@v\d+\.\d+\.\d+/u,
    'extension CI must pin setup-node to an exact semver release so Dependabot owns action updates',
  );
  assert.match(
    workflow,
    /node-version:\s*["']20["']/u,
    'extension CI must include Node 20 so Node 24-only APIs do not pass the extension gate',
  );
});
