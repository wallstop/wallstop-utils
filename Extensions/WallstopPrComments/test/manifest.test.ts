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
