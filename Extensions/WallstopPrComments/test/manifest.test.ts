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
