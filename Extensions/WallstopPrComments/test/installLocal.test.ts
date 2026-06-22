import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, linkSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

type InstallLocalModule = {
  createSetupPlan: (options: {
    extensionRoot: string;
    codeCli?: string | { command: string; argsPrefix?: string[]; env?: NodeJS.ProcessEnv };
    env?: NodeJS.ProcessEnv;
    platform?: NodeJS.Platform;
    setupOnly?: boolean;
    skipDependencyRestore?: boolean;
    skipTests?: boolean;
    vsixPath?: string;
  }) => {
    extensionRoot: string;
    vsixPath?: string;
    commands: Array<{ label: string; command: string; args: string[]; cwd: string; env?: NodeJS.ProcessEnv }>;
  };
  executeSetupPlan: (
    plan: {
      vsixPath?: string;
      commands: Array<{ label: string; command: string; args: string[]; cwd: string; env?: NodeJS.ProcessEnv }>;
    },
    options?: { dryRun?: boolean; platform?: NodeJS.Platform; env?: NodeJS.ProcessEnv }
  ) => Promise<void>;
  resolveCodeCli: (options: {
    codeCli?: string;
    env?: NodeJS.ProcessEnv;
    candidates?: string[];
    platform?: NodeJS.Platform;
    findCommand?: (command: string) => Promise<string[]>;
    fileExists?: (path: string) => boolean;
    probe: (command: string | { command: string; argsPrefix?: string[]; env?: NodeJS.ProcessEnv }) => Promise<boolean>;
  }) => Promise<string | { command: string; argsPrefix?: string[]; env?: NodeJS.ProcessEnv }>;
  createCodeCliCommand: (
    label: string,
    codeCli: string | { command: string; argsPrefix?: string[]; env?: NodeJS.ProcessEnv },
    args: string[],
    cwd: string
  ) => { label: string; command: string; args: string[]; cwd: string; env?: NodeJS.ProcessEnv };
  createSpawnOptions: (
    command: string,
    args: string[],
    cwd: string,
    platform: NodeJS.Platform,
    env: NodeJS.ProcessEnv
  ) => {
    command: string;
    args: string[];
    options: { cwd: string; env: NodeJS.ProcessEnv; stdio: string; shell: boolean };
  };
  mergeCommandEnvironment: (baseEnv: NodeJS.ProcessEnv, commandEnv?: NodeJS.ProcessEnv) => NodeJS.ProcessEnv;
};

type PackageVsixModule = {
  compareOrdinal: (left: string, right: string) => number;
  createVsixEntryPlan: (extensionRoot: string) => {
    entries: Array<{ sourcePath: string; zipPath: string }>;
  };
  getProductionPackagePaths: (extensionRoot: string) => string[];
  writeVsixPackage: (options: { extensionRoot: string; out: string }) => Promise<{ outPath: string; entryCount: number }>;
};

function loadInstallLocalModule(): InstallLocalModule {
  return require(join(__dirname, '..', '..', 'scripts', 'install-local.js')) as InstallLocalModule;
}

function loadPackageVsixModule(): PackageVsixModule {
  return require(join(__dirname, '..', '..', 'scripts', 'package-vsix.js')) as PackageVsixModule;
}

function sha256File(filePath: string): string {
  return createHash('sha256').update(readFileSync(filePath)).digest('hex');
}

function writePackageFixture(extensionRoot: string, lockPackages: Record<string, unknown> = { '': {} }): void {
  writeFileSync(
    join(extensionRoot, 'package.json'),
    JSON.stringify({
      name: 'wallstop-pr-comments',
      displayName: 'Wallstop PR Comments',
      description: 'fixture',
      version: '0.1.0',
      publisher: 'wallstop',
      engines: { vscode: '^1.90.0' },
      categories: ['Other']
    }),
    'utf8'
  );
  writeFileSync(join(extensionRoot, 'README.md'), '# fixture\n', 'utf8');
  mkdirSync(join(extensionRoot, 'resources'), { recursive: true });
  writeFileSync(join(extensionRoot, 'resources', 'pr-comments.svg'), '<svg/>\n', 'utf8');
  mkdirSync(join(extensionRoot, 'out', 'src'), { recursive: true });
  writeFileSync(join(extensionRoot, 'out', 'src', 'extension.js'), 'module.exports = {};\n', 'utf8');
  mkdirSync(join(extensionRoot, 'node_modules'), { recursive: true });
  writeFileSync(join(extensionRoot, 'package-lock.json'), JSON.stringify({ packages: lockPackages }), 'utf8');
}

function readZipEntries(zipPath: string): Promise<string[]> {
  const yauzl = require('yauzl') as {
    open: (
      path: string,
      options: { lazyEntries: boolean },
      callback: (error: Error | null, zipFile?: {
        readEntry: () => void;
        on: (event: string, callback: (value?: { fileName: string }) => void) => void;
      }) => void
    ) => void;
  };

  return new Promise((resolve, reject) => {
    yauzl.open(zipPath, { lazyEntries: true }, (error, zipFile) => {
      if (error) {
        reject(error);
        return;
      }
      if (!zipFile) {
        reject(new Error('Expected zip file handle.'));
        return;
      }

      const entries: string[] = [];
      zipFile.on('entry', (entry) => {
        if (entry) {
          entries.push(entry.fileName);
        }
        zipFile.readEntry();
      });
      zipFile.on('end', () => resolve(entries.sort()));
      zipFile.on('error', (zipError) => reject(zipError));
      zipFile.readEntry();
    });
  });
}

test('package manifest exposes one-click local install and setup scripts', () => {
  const extensionRoot = join(__dirname, '..', '..');
  const manifest = JSON.parse(readFileSync(join(extensionRoot, 'package.json'), 'utf8')) as {
    scripts?: Record<string, string>;
    devDependencies?: Record<string, string>;
  };

  assert.equal(manifest.scripts?.setup, 'node scripts/install-local.js --setup-only');
  assert.equal(manifest.scripts?.['install:local'], 'node scripts/install-local.js');
  assert.equal(manifest.scripts?.['package:vsix'], 'npm run compile && node scripts/package-vsix.js');
  assert.equal(manifest.scripts?.test, 'npm run compile && node --test out/test');
  assert.equal(manifest.devDependencies?.['@vscode/vsce'], undefined);
  assert.equal(typeof manifest.devDependencies?.yazl, 'string');

  const readme = readFileSync(join(extensionRoot, 'README.md'), 'utf8');
  assert.match(readme, /scripts\/package-vsix\.js/);
  assert.doesNotMatch(readme, /@vscode\/vsce/);
});

test('local install plan tests, packages, and installs a VSIX', () => {
  const { createSetupPlan } = loadInstallLocalModule();
  const root = join(__dirname, '..', '..');
  const vsixPath = join(tmpdir(), 'wallstop-pr-comments test.vsix');

  const plan = createSetupPlan({
    extensionRoot: root,
    codeCli: 'code',
    vsixPath,
    env: { npm_execpath: '/opt/npm-cli.js' },
    platform: 'linux'
  });

  assert.equal(plan.extensionRoot, root);
  assert.equal(plan.vsixPath, vsixPath);
  assert.deepEqual(
    plan.commands.map((command) => ({
      label: command.label,
      command: command.command,
      args: command.args,
      cwd: command.cwd
    })),
    [
      {
        label: 'Install extension development dependencies',
        command: process.execPath,
        args: ['/opt/npm-cli.js', 'ci'],
        cwd: root
      },
      {
        label: 'Run extension tests',
        command: process.execPath,
        args: ['/opt/npm-cli.js', 'test'],
        cwd: root
      },
      {
        label: 'Package VSIX',
        command: process.execPath,
        args: [join(root, 'scripts', 'package-vsix.js'), '--out', vsixPath],
        cwd: root
      },
      {
        label: 'Install VSIX in VS Code',
        command: 'code',
        args: ['--install-extension', vsixPath, '--force'],
        cwd: root
      }
    ]
  );
});

test('local install plan uses an extension-local npm cache by default', () => {
  const { createSetupPlan } = loadInstallLocalModule();
  const root = join(__dirname, '..', '..');

  const plan = createSetupPlan({
    extensionRoot: root,
    codeCli: 'code',
    env: { npm_execpath: '/opt/npm-cli.js' },
    platform: 'linux'
  });
  const npmCommands = plan.commands.filter((command) => command.args.includes('/opt/npm-cli.js'));

  assert.equal(npmCommands.length, 2);
  for (const command of npmCommands) {
    assert.deepEqual(command.env, { npm_config_cache: join(root, '.npm-cache') });
  }
});

test('local install plan preserves an explicitly configured npm cache', () => {
  const { createSetupPlan } = loadInstallLocalModule();
  const root = join(__dirname, '..', '..');

  const plan = createSetupPlan({
    extensionRoot: root,
    codeCli: 'code',
    env: { npm_execpath: '/opt/npm-cli.js', npm_config_cache: '/tmp/npm-cache' },
    platform: 'linux'
  });
  const npmCommands = plan.commands.filter((command) => command.args.includes('/opt/npm-cli.js'));

  assert.equal(npmCommands.length, 2);
  for (const command of npmCommands) {
    assert.equal(command.env, undefined);
  }
});

test('setup-only plan does not need a VS Code extensions directory', () => {
  const { createSetupPlan } = loadInstallLocalModule();
  const root = join(__dirname, '..', '..');

  const plan = createSetupPlan({
    extensionRoot: root,
    setupOnly: true,
    skipDependencyRestore: true,
    env: { npm_execpath: '/opt/npm-cli.js' },
    platform: 'linux'
  });

  assert.equal(plan.vsixPath, undefined);
  assert.deepEqual(
    plan.commands.map((command) => command.label),
    ['Compile extension']
  );
});

test('default VSIX output path is deterministic and cross-platform safe', () => {
  const { createSetupPlan } = loadInstallLocalModule();
  const tempHome = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-home-'));
  try {
    const root = join(__dirname, '..', '..');

    assert.equal(
      createSetupPlan({
        extensionRoot: root,
        codeCli: 'code',
        env: { HOME: tempHome, npm_execpath: '/opt/npm-cli.js' },
        platform: 'linux'
      }).vsixPath,
      join(root, 'dist', 'wallstop-pr-comments-0.1.0.vsix')
    );
    assert.equal(
      createSetupPlan({
        extensionRoot: root,
        codeCli: 'code',
        env: { USERPROFILE: tempHome, npm_execpath: 'C:\\npm-cli.js' },
        platform: 'win32'
      }).vsixPath,
      join(root, 'dist', 'wallstop-pr-comments-0.1.0.vsix')
    );
  } finally {
    rmSync(tempHome, { recursive: true, force: true });
  }
});

test('VS Code CLI resolution uses override before probing fallback candidates', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const probed: string[] = [];

  assert.equal(
    await resolveCodeCli({
      env: { WALLSTOP_VSCODE_CLI: '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' },
      probe: async (command) => {
        if (typeof command !== 'string') {
          throw new Error('Expected string command.');
        }
        probed.push(command);
        return true;
      }
    }),
    '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code'
  );
  assert.deepEqual(probed, ['/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code']);
});

test('explicit VS Code CLI option takes precedence over environment override', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const probed: string[] = [];

  assert.equal(
    await resolveCodeCli({
      env: { WALLSTOP_VSCODE_CLI: 'code-insiders' },
      codeCli: 'codium',
      platform: 'linux',
      probe: async (command) => {
        if (typeof command !== 'string') {
          throw new Error('Expected string command.');
        }
        probed.push(command);
        return true;
      }
    }),
    'codium'
  );
  assert.deepEqual(probed, ['codium']);
});

test('VS Code CLI resolution falls back through common command names', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const probed: string[] = [];

  assert.equal(
    await resolveCodeCli({
      env: {},
      candidates: ['code', 'code-insiders', 'codium'],
      platform: 'linux',
      probe: async (command) => {
        if (typeof command !== 'string') {
          throw new Error('Expected string command.');
        }
        probed.push(command);
        return command === 'codium';
      }
    }),
    'codium'
  );
  assert.deepEqual(probed, ['code', 'code-insiders', 'codium']);
});

test('Windows VS Code CLI resolution probes backing exe with VS Code cli.js semantics', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const probed: Array<{ command: string; argsPrefix?: string[]; env?: NodeJS.ProcessEnv }> = [];
  const codeCmd = 'C:\\Program Files\\Microsoft VS Code\\bin\\code.cmd';
  const codeExe = 'C:\\Program Files\\Microsoft VS Code\\Code.exe';
  const cliJs = 'C:\\Program Files\\Microsoft VS Code\\resources\\app\\out\\cli.js';

  assert.deepEqual(
    await resolveCodeCli({
      env: {},
      platform: 'win32',
      candidates: ['code'],
      findCommand: async (command) => (command === 'code' ? [codeCmd] : []),
      fileExists: (candidate) => candidate === codeExe || candidate === cliJs,
      probe: async (command) => {
        assert.notEqual(typeof command, 'string');
        if (typeof command === 'string') {
          throw new Error('Expected resolved Windows CLI object.');
        }
        probed.push(command);
        return true;
      }
    }),
    {
      command: codeExe,
      argsPrefix: [cliJs],
      env: { ELECTRON_RUN_AS_NODE: '1', VSCODE_DEV: undefined }
    }
  );
  assert.deepEqual(probed, [
    {
      command: codeExe,
      argsPrefix: [cliJs],
      env: { ELECTRON_RUN_AS_NODE: '1', VSCODE_DEV: undefined }
    }
  ]);
});

test('Windows VS Code CLI resolution converts Code.exe hits to cli.js semantics before probing', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const probed: Array<string | { command: string; argsPrefix?: string[]; env?: NodeJS.ProcessEnv }> = [];
  const codeExe = 'C:\\Program Files\\Microsoft VS Code\\Code.exe';
  const codeCmd = 'C:\\Program Files\\Microsoft VS Code\\bin\\code.cmd';
  const cliJs = 'C:\\Program Files\\Microsoft VS Code\\resources\\app\\out\\cli.js';

  assert.deepEqual(
    await resolveCodeCli({
      env: {},
      platform: 'win32',
      candidates: ['code'],
      findCommand: async (command) => (command === 'code' ? [codeExe, codeCmd] : []),
      fileExists: (candidate) => candidate === codeExe || candidate === cliJs,
      probe: async (command) => {
        probed.push(command);
        return true;
      }
    }),
    {
      command: codeExe,
      argsPrefix: [cliJs],
      env: { ELECTRON_RUN_AS_NODE: '1', VSCODE_DEV: undefined }
    }
  );
  assert.deepEqual(probed, [
    {
      command: codeExe,
      argsPrefix: [cliJs],
      env: { ELECTRON_RUN_AS_NODE: '1', VSCODE_DEV: undefined }
    }
  ]);
});

test('explicit Windows custom cmd CLI is honored instead of silently falling back', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const customCli = 'C:\\Tools\\portable-code.cmd';
  const probed: string[] = [];

  assert.equal(
    await resolveCodeCli({
      env: {},
      platform: 'win32',
      codeCli: customCli,
      findCommand: async () => [],
      probe: async (command) => {
        if (typeof command !== 'string') {
          throw new Error('Expected explicit custom cmd to be probed as a command string.');
        }
        probed.push(command);
        return command === customCli;
      }
    }),
    customCli
  );
  assert.deepEqual(probed, [customCli]);
});

test('failed explicit Windows CLI option does not fall back to default candidates', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const probed: string[] = [];

  await assert.rejects(
    () => resolveCodeCli({
      env: {},
      platform: 'win32',
      codeCli: 'C:\\Tools\\portable-code.cmd',
      candidates: ['code'],
      findCommand: async (command) => (command === 'code' ? ['C:\\Program Files\\Microsoft VS Code\\Code.exe'] : []),
      fileExists: () => true,
      probe: async (command) => {
        if (typeof command !== 'string') {
          throw new Error('Default candidates must not be probed after an explicit failure.');
        }
        probed.push(command);
        return false;
      }
    }),
    /Explicit VS Code CLI was not usable/
  );
  assert.deepEqual(probed, ['C:\\Tools\\portable-code.cmd']);
});

test('failed environment Windows CLI override does not fall back to default candidates', async () => {
  const { resolveCodeCli } = loadInstallLocalModule();
  const probed: string[] = [];

  await assert.rejects(
    () => resolveCodeCli({
      env: { WALLSTOP_VSCODE_CLI: 'C:\\Tools\\portable-code.cmd' },
      platform: 'win32',
      candidates: ['code'],
      findCommand: async (command) => (command === 'code' ? ['C:\\Program Files\\Microsoft VS Code\\Code.exe'] : []),
      fileExists: () => true,
      probe: async (command) => {
        if (typeof command !== 'string') {
          throw new Error('Default candidates must not be probed after an environment override failure.');
        }
        probed.push(command);
        return false;
      }
    }),
    /Explicit VS Code CLI was not usable/
  );
  assert.deepEqual(probed, ['C:\\Tools\\portable-code.cmd']);
});

test('resolved Code CLI environment clears VSCODE_DEV when launching the shim target', () => {
  const { mergeCommandEnvironment } = loadInstallLocalModule();
  const command = {
    label: 'Install VSIX in VS Code',
    command: 'C:\\Program Files\\Microsoft VS Code\\Code.exe',
    args: [
      'C:\\Program Files\\Microsoft VS Code\\resources\\app\\out\\cli.js',
      '--install-extension',
      'fixture.vsix',
      '--force'
    ],
    cwd: 'C:\\repo',
    env: { ELECTRON_RUN_AS_NODE: '1', VSCODE_DEV: undefined }
  };
  const env = mergeCommandEnvironment({ VSCODE_DEV: '1', ELECTRON_RUN_AS_NODE: '0' }, command.env);

  assert.equal(env.ELECTRON_RUN_AS_NODE, '1');
  assert.equal(Object.hasOwn(env, 'VSCODE_DEV'), false);
});

test('local install plan preserves resolved VS Code CLI args and environment', () => {
  const { createCodeCliCommand, createSetupPlan } = loadInstallLocalModule();
  const root = join(__dirname, '..', '..');
  const codeCli = {
    command: 'C:\\Program Files\\Microsoft VS Code\\Code.exe',
    argsPrefix: ['C:\\Program Files\\Microsoft VS Code\\resources\\app\\out\\cli.js'],
    env: { ELECTRON_RUN_AS_NODE: '1' }
  };

  assert.deepEqual(
    createCodeCliCommand('Install VSIX in VS Code', codeCli, ['--install-extension', 'fixture.vsix', '--force'], root),
    {
      label: 'Install VSIX in VS Code',
      command: codeCli.command,
      args: [...codeCli.argsPrefix, '--install-extension', 'fixture.vsix', '--force'],
      cwd: root,
      env: codeCli.env
    }
  );

  const installCommand = createSetupPlan({
    extensionRoot: root,
    codeCli,
    skipDependencyRestore: true,
    skipTests: true
  }).commands.at(-1);
  assert.equal(installCommand?.command, codeCli.command);
  assert.deepEqual(installCommand?.args.slice(0, 1), codeCli.argsPrefix);
});

test('Windows spawn planning invokes exe commands directly and preserves injected environment', () => {
  const { createSpawnOptions } = loadInstallLocalModule();
  const env = { ComSpec: 'C:\\Windows\\System32\\cmd.exe', WALLSTOP_TEST: '1' };
  const spawnOptions = createSpawnOptions(
    'C:\\Program Files\\Microsoft VS Code\\Code.exe',
    ['--install-extension', 'C:\\Users\\Jane & 100%\\Wallstop PR Comments.vsix', '--force'],
    'C:\\repo with spaces',
    'win32',
    env
  );

  assert.equal(spawnOptions.command, 'C:\\Program Files\\Microsoft VS Code\\Code.exe');
  assert.deepEqual(spawnOptions.args, [
    '--install-extension',
    'C:\\Users\\Jane & 100%\\Wallstop PR Comments.vsix',
    '--force'
  ]);
  assert.equal(spawnOptions.options.shell, false);
  assert.equal(spawnOptions.options.env, env);
});

test('Windows spawn planning rejects control characters in command tokens', () => {
  const { createSpawnOptions } = loadInstallLocalModule();

  assert.throws(
    () => createSpawnOptions('code.cmd', ['--install-extension', 'C:\\tmp\\bad\npath.vsix'], 'C:\\repo', 'win32', {}),
    /Unsafe Windows command token/
  );
});

test('VSIX entry plan includes runtime files and excludes source tests and dev dependencies', () => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const root = join(__dirname, '..', '..');
  const entries = createVsixEntryPlan(root).entries.map((entry) => entry.zipPath);

  assert.equal(entries.includes('extension/package.json'), true);
  assert.equal(entries.includes('extension/README.md'), true);
  assert.equal(entries.includes('extension/resources/pr-comments.svg'), true);
  assert.equal(entries.includes('extension/out/src/extension.js'), true);
  assert.equal(entries.some((entry) => entry.startsWith('extension/node_modules/markdown-it/')), true);
  assert.equal(entries.some((entry) => entry.startsWith('extension/src/')), false);
  assert.equal(entries.some((entry) => entry.startsWith('extension/test/')), false);
  assert.equal(entries.some((entry) => entry.startsWith('extension/node_modules/typescript/')), false);
  assert.equal(entries.some((entry) => entry.startsWith('extension/node_modules/yazl/')), false);
});

test('ordinal comparator is stable and locale-independent for package ordering', () => {
  const { compareOrdinal } = loadPackageVsixModule();

  assert.deepEqual(['z', 'A', 'a', '\u00e4'].sort(compareOrdinal), ['A', 'a', 'z', '\u00e4']);
});

test('production dependency path planning rejects unsafe package-lock keys', () => {
  const { getProductionPackagePaths } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-lock-'));
  try {
    writeFileSync(
      join(tempRoot, 'package-lock.json'),
      JSON.stringify({
        packages: {
          '': {},
          'node_modules/@scope/pkg': {},
          'node_modules/../outside': {},
          'node_modules/pkg//child': {},
          'node_modules/pkg/../../outside': {},
          'node_modules/pkg\\..\\outside': {}
        }
      }),
      'utf8'
    );

    assert.throws(() => getProductionPackagePaths(tempRoot), /Unsafe package-lock package path/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('VSIX entry planning rejects symlinked package roots outside node_modules', (context) => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-symlink-'));
  let outsideRoot: string | undefined;
  try {
    writeFileSync(
      join(tempRoot, 'package.json'),
      JSON.stringify({
        name: 'wallstop-pr-comments',
        displayName: 'Wallstop PR Comments',
        description: 'fixture',
        version: '0.1.0',
        publisher: 'wallstop',
        engines: { vscode: '^1.90.0' },
        categories: ['Other']
      }),
      'utf8'
    );
    writeFileSync(join(tempRoot, 'README.md'), '# fixture\n', 'utf8');
    mkdirSync(join(tempRoot, 'resources'), { recursive: true });
    writeFileSync(join(tempRoot, 'resources', 'pr-comments.svg'), '<svg/>\n', 'utf8');
    mkdirSync(join(tempRoot, 'out', 'src'), { recursive: true });
    writeFileSync(join(tempRoot, 'out', 'src', 'extension.js'), 'module.exports = {};\n', 'utf8');
    mkdirSync(join(tempRoot, 'node_modules'), { recursive: true });

    outsideRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-outside-'));
    writeFileSync(join(outsideRoot, 'secret.js'), 'module.exports = "no";\n', 'utf8');
    try {
      symlinkSync(outsideRoot, join(tempRoot, 'node_modules', 'pkg'), 'dir');
    } catch (error) {
      context.skip(`Symlink creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    writeFileSync(
      join(tempRoot, 'package-lock.json'),
      JSON.stringify({
        packages: {
          '': {},
          'node_modules/pkg': {}
        }
      }),
      'utf8'
    );

    assert.throws(() => createVsixEntryPlan(tempRoot), /Unsafe package-lock package path/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  }
});

test('VSIX entry planning rejects symlinked node_modules outside extension root', (context) => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-node-modules-link-'));
  let outsideRoot: string | undefined;
  try {
    writeFileSync(
      join(tempRoot, 'package.json'),
      JSON.stringify({
        name: 'wallstop-pr-comments',
        displayName: 'Wallstop PR Comments',
        description: 'fixture',
        version: '0.1.0',
        publisher: 'wallstop',
        engines: { vscode: '^1.90.0' },
        categories: ['Other']
      }),
      'utf8'
    );
    writeFileSync(join(tempRoot, 'README.md'), '# fixture\n', 'utf8');
    mkdirSync(join(tempRoot, 'resources'), { recursive: true });
    writeFileSync(join(tempRoot, 'resources', 'pr-comments.svg'), '<svg/>\n', 'utf8');
    mkdirSync(join(tempRoot, 'out', 'src'), { recursive: true });
    writeFileSync(join(tempRoot, 'out', 'src', 'extension.js'), 'module.exports = {};\n', 'utf8');

    outsideRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-node-modules-outside-'));
    mkdirSync(join(outsideRoot, 'pkg'), { recursive: true });
    writeFileSync(join(outsideRoot, 'pkg', 'secret.js'), 'module.exports = "no";\n', 'utf8');
    try {
      symlinkSync(outsideRoot, join(tempRoot, 'node_modules'), 'dir');
    } catch (error) {
      context.skip(`Symlink creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    writeFileSync(
      join(tempRoot, 'package-lock.json'),
      JSON.stringify({
        packages: {
          '': {},
          'node_modules/pkg': {}
        }
      }),
      'utf8'
    );

    assert.throws(() => createVsixEntryPlan(tempRoot), /Unsafe package-lock package path/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  }
});

test('VSIX entry planning rejects symlinked resources outside extension root', (context) => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-resources-link-'));
  let outsideRoot: string | undefined;
  try {
    writeFileSync(
      join(tempRoot, 'package.json'),
      JSON.stringify({
        name: 'wallstop-pr-comments',
        displayName: 'Wallstop PR Comments',
        description: 'fixture',
        version: '0.1.0',
        publisher: 'wallstop',
        engines: { vscode: '^1.90.0' },
        categories: ['Other']
      }),
      'utf8'
    );
    writeFileSync(join(tempRoot, 'README.md'), '# fixture\n', 'utf8');
    mkdirSync(join(tempRoot, 'out', 'src'), { recursive: true });
    writeFileSync(join(tempRoot, 'out', 'src', 'extension.js'), 'module.exports = {};\n', 'utf8');
    mkdirSync(join(tempRoot, 'node_modules'), { recursive: true });
    writeFileSync(join(tempRoot, 'package-lock.json'), JSON.stringify({ packages: { '': {} } }), 'utf8');

    outsideRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-resources-outside-'));
    writeFileSync(join(outsideRoot, 'secret.svg'), '<svg/>\n', 'utf8');
    try {
      symlinkSync(outsideRoot, join(tempRoot, 'resources'), 'dir');
    } catch (error) {
      context.skip(`Symlink creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    assert.throws(() => createVsixEntryPlan(tempRoot), /Unsafe VSIX source directory/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  }
});

test('VSIX entry planning rejects nested symlinks inside resources', (context) => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-resource-nested-link-'));
  let outsideRoot: string | undefined;
  try {
    writePackageFixture(tempRoot);
    outsideRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-resource-nested-outside-'));
    writeFileSync(join(outsideRoot, 'secret.svg'), '<svg/>\n', 'utf8');
    try {
      symlinkSync(join(outsideRoot, 'secret.svg'), join(tempRoot, 'resources', 'linked.svg'), 'file');
    } catch (error) {
      context.skip(`Symlink creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    assert.throws(() => createVsixEntryPlan(tempRoot), /Unsafe VSIX symlink/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  }
});

test('VSIX entry planning rejects symlinked compiled output outside extension root', (context) => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-out-link-'));
  let outsideRoot: string | undefined;
  try {
    writeFileSync(
      join(tempRoot, 'package.json'),
      JSON.stringify({
        name: 'wallstop-pr-comments',
        displayName: 'Wallstop PR Comments',
        description: 'fixture',
        version: '0.1.0',
        publisher: 'wallstop',
        engines: { vscode: '^1.90.0' },
        categories: ['Other']
      }),
      'utf8'
    );
    writeFileSync(join(tempRoot, 'README.md'), '# fixture\n', 'utf8');
    mkdirSync(join(tempRoot, 'resources'), { recursive: true });
    writeFileSync(join(tempRoot, 'resources', 'pr-comments.svg'), '<svg/>\n', 'utf8');
    mkdirSync(join(tempRoot, 'node_modules'), { recursive: true });
    writeFileSync(join(tempRoot, 'package-lock.json'), JSON.stringify({ packages: { '': {} } }), 'utf8');

    outsideRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-out-outside-'));
    mkdirSync(join(outsideRoot, 'src'), { recursive: true });
    writeFileSync(join(outsideRoot, 'src', 'extension.js'), 'module.exports = "no";\n', 'utf8');
    mkdirSync(join(tempRoot, 'out'), { recursive: true });
    try {
      symlinkSync(outsideRoot, join(tempRoot, 'out', 'src'), 'dir');
    } catch (error) {
      context.skip(`Symlink creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    assert.throws(() => createVsixEntryPlan(tempRoot), /Unsafe VSIX source directory/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  }
});

test('VSIX entry planning rejects nested symlinks inside compiled output', (context) => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-out-nested-link-'));
  let outsideRoot: string | undefined;
  try {
    writePackageFixture(tempRoot);
    outsideRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-out-nested-outside-'));
    writeFileSync(join(outsideRoot, 'secret.js'), 'module.exports = "no";\n', 'utf8');
    try {
      symlinkSync(join(outsideRoot, 'secret.js'), join(tempRoot, 'out', 'src', 'linked.js'), 'file');
    } catch (error) {
      context.skip(`Symlink creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    assert.throws(() => createVsixEntryPlan(tempRoot), /Unsafe VSIX symlink/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  }
});

test('VSIX entry planning rejects nested symlinks inside production dependencies', (context) => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-dep-nested-link-'));
  let outsideRoot: string | undefined;
  try {
    writePackageFixture(tempRoot, {
      '': {},
      'node_modules/pkg': {}
    });
    mkdirSync(join(tempRoot, 'node_modules', 'pkg'), { recursive: true });
    writeFileSync(join(tempRoot, 'node_modules', 'pkg', 'index.js'), 'module.exports = {};\n', 'utf8');
    outsideRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-dep-nested-outside-'));
    writeFileSync(join(outsideRoot, 'secret.js'), 'module.exports = "no";\n', 'utf8');
    try {
      symlinkSync(join(outsideRoot, 'secret.js'), join(tempRoot, 'node_modules', 'pkg', 'linked.js'), 'file');
    } catch (error) {
      context.skip(`Symlink creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    assert.throws(() => createVsixEntryPlan(tempRoot), /Unsafe VSIX symlink/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    if (outsideRoot) {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  }
});

test('VSIX entry planning avoids duplicate entries for nested production dependencies', () => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-nested-deps-'));
  try {
    writePackageFixture(tempRoot, {
      '': {},
      'node_modules/a': {},
      'node_modules/a/node_modules/b': {}
    });
    mkdirSync(join(tempRoot, 'node_modules', 'a', 'node_modules', 'b'), { recursive: true });
    writeFileSync(join(tempRoot, 'node_modules', 'a', 'index.js'), 'module.exports = {};\n', 'utf8');
    writeFileSync(join(tempRoot, 'node_modules', 'a', 'node_modules', 'b', 'index.js'), 'module.exports = {};\n', 'utf8');

    const entries = createVsixEntryPlan(tempRoot).entries.map((entry) => entry.zipPath);
    assert.equal(new Set(entries).size, entries.length);
    assert.equal(
      entries.filter((entry) => entry === 'extension/node_modules/a/node_modules/b/index.js').length,
      1
    );
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('VSIX entry planning skips optional production dependencies missing from node_modules', () => {
  const { createVsixEntryPlan } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-optional-dep-'));
  try {
    writePackageFixture(tempRoot, {
      '': {},
      'node_modules/native-optional': { optional: true }
    });

    const entries = createVsixEntryPlan(tempRoot).entries.map((entry) => entry.zipPath);
    assert.equal(entries.some((entry) => entry.startsWith('extension/node_modules/native-optional/')), false);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('writes a VSIX with the required install structure', async () => {
  const { writeVsixPackage } = loadPackageVsixModule();
  const root = join(__dirname, '..', '..');
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-vsix-'));
  try {
    const vsixPath = join(tempRoot, 'Wallstop PR Comments.vsix');
    const result = await writeVsixPackage({ extensionRoot: root, out: vsixPath });
    const entries = await readZipEntries(result.outPath);

    assert.equal(result.outPath, vsixPath);
    assert.equal(entries.includes('[Content_Types].xml'), true);
    assert.equal(entries.includes('extension.vsixmanifest'), true);
    assert.equal(entries.includes('extension/package.json'), true);
    assert.equal(entries.includes('extension/out/src/extension.js'), true);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('VSIX package writing rejects output paths inside packaged inputs', async () => {
  const { writeVsixPackage } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-vsix-self-output-'));
  try {
    writePackageFixture(tempRoot, {
      '': {},
      'node_modules/pkg': {}
    });
    mkdirSync(join(tempRoot, 'node_modules', 'pkg'), { recursive: true });
    writeFileSync(join(tempRoot, 'node_modules', 'pkg', 'index.js'), 'module.exports = {};\n', 'utf8');

    const unsafeOutputs = [
      join(tempRoot, 'package.json'),
      join(tempRoot, 'resources', 'self.vsix'),
      join(tempRoot, 'out', 'src', 'self.vsix'),
      join(tempRoot, 'node_modules', 'pkg', 'self.vsix')
    ];

    for (const unsafeOutput of unsafeOutputs) {
      await assert.rejects(
        async () => {
          await writeVsixPackage({ extensionRoot: tempRoot, out: unsafeOutput });
        },
        /Unsafe VSIX output path overlaps packaged input/
      );
    }
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('VSIX package writing rejects hard-linked output paths before mutating packaged files', async (context) => {
  const { writeVsixPackage } = loadPackageVsixModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-vsix-hard-link-'));
  try {
    writePackageFixture(tempRoot);
    const packageJsonPath = join(tempRoot, 'package.json');
    const originalPackageJson = readFileSync(packageJsonPath, 'utf8');
    const hardLinkedOutput = join(tempRoot, 'dist', 'hard-linked.vsix');
    mkdirSync(join(tempRoot, 'dist'), { recursive: true });
    try {
      linkSync(packageJsonPath, hardLinkedOutput);
    } catch (error) {
      context.skip(`Hard link creation is not available in this environment: ${(error as Error).message}`);
      return;
    }

    await assert.rejects(
      async () => {
        await writeVsixPackage({ extensionRoot: tempRoot, out: hardLinkedOutput });
      },
      /Unsafe VSIX output path overlaps packaged input/
    );
    assert.equal(readFileSync(packageJsonPath, 'utf8'), originalPackageJson);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('install execution does not pre-create unsafe VSIX output directories', async () => {
  const { executeSetupPlan } = loadInstallLocalModule();
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-install-output-'));
  try {
    writePackageFixture(tempRoot);
    const unsafeOutputDir = join(tempRoot, 'resources', 'generated');

    await assert.rejects(
      async () => {
        await executeSetupPlan(
          {
            vsixPath: join(unsafeOutputDir, 'self.vsix'),
            commands: [
              {
                label: 'Package VSIX',
                command: process.execPath,
                args: ['-e', 'process.exit(1)'],
                cwd: tempRoot
              }
            ]
          },
          { env: process.env, platform: process.platform }
        );
      },
      /Package VSIX failed/
    );
    assert.equal(existsSync(unsafeOutputDir), false);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('writes deterministic VSIX bytes for identical inputs', async () => {
  const { writeVsixPackage } = loadPackageVsixModule();
  const root = join(__dirname, '..', '..');
  const tempRoot = mkdtempSync(join(tmpdir(), 'wallstop-pr-comments-deterministic-'));
  try {
    const firstPath = join(tempRoot, 'first.vsix');
    const secondPath = join(tempRoot, 'second.vsix');

    await writeVsixPackage({ extensionRoot: root, out: firstPath });
    await writeVsixPackage({ extensionRoot: root, out: secondPath });

    assert.equal(sha256File(firstPath), sha256File(secondPath));
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});
