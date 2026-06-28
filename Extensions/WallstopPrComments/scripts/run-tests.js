#!/usr/bin/env node
'use strict';

const { readdirSync } = require('node:fs');
const { join } = require('node:path');
const { spawnSync } = require('node:child_process');

const extensionRoot = join(__dirname, '..');
const testRoot = join(extensionRoot, 'out', 'test');

function collectTestFiles(root) {
  const files = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectTestFiles(path));
    } else if (entry.isFile() && entry.name.endsWith('.test.js')) {
      files.push(path);
    }
  }
  return files.sort((left, right) => left.localeCompare(right, 'en-US'));
}

let testFiles;
try {
  testFiles = collectTestFiles(testRoot);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Could not discover compiled tests under ${testRoot}: ${message}`);
  process.exit(1);
}

if (testFiles.length === 0) {
  console.error(`No compiled test files found under ${testRoot}. Run npm run compile first.`);
  process.exit(1);
}

const result = spawnSync(process.execPath, ['--test', ...testFiles], { stdio: 'inherit' });
if (result.error !== undefined) {
  console.error(`Failed to start node test runner: ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 1);
