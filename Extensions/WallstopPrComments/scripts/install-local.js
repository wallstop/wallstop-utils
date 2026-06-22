#!/usr/bin/env node
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const CODE_CLI_ENV = 'WALLSTOP_VSCODE_CLI';
const DEFAULT_CODE_CLI_CANDIDATES = ['code', 'code-insiders', 'codium', 'code-oss'];
const WINDOWS_CODE_BACKING_EXES = new Map([
  ['code', 'Code.exe'],
  ['code-insiders', 'Code - Insiders.exe'],
  ['codium', 'VSCodium.exe'],
  ['code-oss', 'Code - OSS.exe']
]);
const WINDOWS_CODE_EXE_BASENAMES = new Set(Array.from(WINDOWS_CODE_BACKING_EXES.values()).map((value) => value.toLowerCase()));

function parseArgs(argv) {
  const options = {
    setupOnly: false,
    skipDependencyRestore: false,
    skipTests: false,
    dryRun: false,
    codeCli: undefined,
    vsixPath: undefined,
    help: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--setup-only') {
      options.setupOnly = true;
    } else if (arg === '--skip-dependency-restore') {
      options.skipDependencyRestore = true;
    } else if (arg === '--skip-tests') {
      options.skipTests = true;
    } else if (arg === '--dry-run') {
      options.dryRun = true;
    } else if (arg === '--help' || arg === '-h') {
      options.help = true;
    } else if (arg === '--code-cli') {
      index += 1;
      options.codeCli = readRequiredValue(argv, index, '--code-cli');
    } else if (arg.startsWith('--code-cli=')) {
      options.codeCli = readInlineValue(arg, '--code-cli');
    } else if (arg === '--vsix-out') {
      index += 1;
      options.vsixPath = readRequiredValue(argv, index, '--vsix-out');
    } else if (arg.startsWith('--vsix-out=')) {
      options.vsixPath = readInlineValue(arg, '--vsix-out');
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }

  return options;
}

function readRequiredValue(argv, index, optionName) {
  if (index >= argv.length || argv[index].startsWith('--')) {
    throw new Error(`${optionName} requires a value.`);
  }
  return argv[index];
}

function readInlineValue(arg, optionName) {
  const value = arg.slice(`${optionName}=`.length);
  if (!value) {
    throw new Error(`${optionName} requires a non-empty value.`);
  }
  return value;
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function assertSafeIdentifier(value, fieldName) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)) {
    throw new Error(`package.json ${fieldName} must be a simple extension identifier.`);
  }
}

function resolveNpmInvocation(env = process.env, platform = process.platform) {
  if (env.npm_execpath) {
    return {
      command: process.execPath,
      argsPrefix: [env.npm_execpath]
    };
  }

  if (platform === 'win32') {
    return {
      command: env.ComSpec || 'cmd.exe',
      argsPrefix: ['/d', '/s', '/c', 'npm']
    };
  }

  return {
    command: 'npm',
    argsPrefix: []
  };
}

function createNpmCommand(label, npmInvocation, npmArgs, cwd, commandEnv) {
  const command = {
    label,
    command: npmInvocation.command,
    args: [...npmInvocation.argsPrefix, ...npmArgs],
    cwd
  };
  if (commandEnv) {
    command.env = commandEnv;
  }
  return command;
}

function getNpmCommandEnvironment(extensionRoot, env = process.env) {
  if (env.npm_config_cache || env.NPM_CONFIG_CACHE) {
    return undefined;
  }

  return {
    npm_config_cache: path.join(extensionRoot, '.npm-cache')
  };
}

function normalizeCodeCli(codeCli) {
  if (typeof codeCli === 'string') {
    return {
      command: codeCli,
      argsPrefix: [],
      env: undefined
    };
  }

  return {
    command: codeCli.command,
    argsPrefix: Array.isArray(codeCli.argsPrefix) ? codeCli.argsPrefix : [],
    env: codeCli.env
  };
}

function createCodeCliCommand(label, codeCli, args, cwd) {
  const normalizedCodeCli = normalizeCodeCli(codeCli);
  return {
    label,
    command: normalizedCodeCli.command,
    args: [...normalizedCodeCli.argsPrefix, ...args],
    cwd,
    env: normalizedCodeCli.env
  };
}

function getDefaultVsixPath(extensionRoot, manifest) {
  assertSafeIdentifier(manifest.name, 'name');
  assertSafeIdentifier(manifest.version, 'version');
  return path.join(extensionRoot, 'dist', `${manifest.name}-${manifest.version}.vsix`);
}

function createSetupPlan(options = {}) {
  const extensionRoot = path.resolve(options.extensionRoot || path.join(__dirname, '..'));
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const manifest = readJsonFile(path.join(extensionRoot, 'package.json'));
  const npmInvocation = resolveNpmInvocation(env, platform);
  const npmCommandEnv = getNpmCommandEnvironment(extensionRoot, env);
  const setupOnly = Boolean(options.setupOnly);
  const skipDependencyRestore = Boolean(options.skipDependencyRestore);
  const skipTests = Boolean(options.skipTests);
  const commands = [];

  if (!skipDependencyRestore) {
    commands.push(createNpmCommand('Install extension development dependencies', npmInvocation, ['ci'], extensionRoot, npmCommandEnv));
  }

  if (setupOnly) {
    commands.push(createNpmCommand('Compile extension', npmInvocation, ['run', 'compile'], extensionRoot, npmCommandEnv));
    return {
      extensionRoot,
      vsixPath: undefined,
      commands
    };
  }

  const codeCli = options.codeCli;
  if (!codeCli) {
    throw new Error('createSetupPlan requires a resolved VS Code CLI for install mode.');
  }

  const vsixPath = path.resolve(options.vsixPath || getDefaultVsixPath(extensionRoot, manifest));
  commands.push(
    skipTests
      ? createNpmCommand('Compile extension', npmInvocation, ['run', 'compile'], extensionRoot, npmCommandEnv)
      : createNpmCommand('Run extension tests', npmInvocation, ['test'], extensionRoot, npmCommandEnv)
  );
  commands.push(
    {
      label: 'Package VSIX',
      command: process.execPath,
      args: [path.join(extensionRoot, 'scripts', 'package-vsix.js'), '--out', vsixPath],
      cwd: extensionRoot
    }
  );
  commands.push(createCodeCliCommand('Install VSIX in VS Code', codeCli, ['--install-extension', vsixPath, '--force'], extensionRoot));

  return {
    extensionRoot,
    vsixPath,
    commands
  };
}

function formatCommand(command) {
  return [command.command, ...command.args].join(' ');
}

function rejectUnsafeWindowsCommandToken(value) {
  if (/[\0\r\n]/.test(value)) {
    throw new Error(`Unsafe Windows command token: ${value}`);
  }
}

function quoteWindowsCommandToken(value) {
  rejectUnsafeWindowsCommandToken(value);
  if (value.length === 0) {
    return '""';
  }
  return `"${value.replace(/"/g, '""').replace(/%/g, '%%')}"`;
}

function shouldUseWindowsCommandShell(command, env) {
  const comspec = env.ComSpec || 'cmd.exe';
  if (command.toLowerCase() === comspec.toLowerCase()) {
    return false;
  }

  const extension = path.win32.extname(command).toLowerCase();
  if (extension === '.exe' || extension === '.com') {
    return false;
  }

  return true;
}

function hasWindowsPathSeparator(command) {
  return command.includes('\\') || command.includes('/');
}

function createWindowsCodeCli(command, fileExists = fs.existsSync) {
  const cliJsPath = path.win32.resolve(path.win32.dirname(command), 'resources', 'app', 'out', 'cli.js');
  if (!fileExists(command) || !fileExists(cliJsPath)) {
    return undefined;
  }

  return {
    command,
    argsPrefix: [cliJsPath],
    env: { ELECTRON_RUN_AS_NODE: '1', VSCODE_DEV: undefined }
  };
}

function getWindowsCodeBackingExecutable(command, fileExists = fs.existsSync) {
  const extension = path.win32.extname(command).toLowerCase();
  if (extension === '.exe' && WINDOWS_CODE_EXE_BASENAMES.has(path.win32.basename(command).toLowerCase())) {
    return createWindowsCodeCli(command, fileExists);
  }

  if (extension !== '.cmd' && extension !== '.bat') {
    return undefined;
  }

  const baseName = path.win32.basename(command, extension).toLowerCase();
  const executableName = WINDOWS_CODE_BACKING_EXES.get(baseName);
  if (!executableName) {
    return undefined;
  }

  const executablePath = path.win32.resolve(path.win32.dirname(command), '..', executableName);
  return createWindowsCodeCli(executablePath, fileExists);
}

function findWindowsCommand(command, env = process.env) {
  if (hasWindowsPathSeparator(command) || path.win32.isAbsolute(command)) {
    return Promise.resolve([command]);
  }

  return new Promise((resolve) => {
    const child = spawn('where.exe', [command], {
      env,
      stdio: ['ignore', 'pipe', 'ignore'],
      shell: false,
      windowsHide: true
    });
    let stdout = '';
    const timer = setTimeout(() => {
      child.kill();
      resolve([]);
    }, 10000);

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString('utf8');
    });
    child.on('error', () => {
      clearTimeout(timer);
      resolve([]);
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        resolve([]);
        return;
      }
      resolve(
        stdout
          .split(/\r?\n/)
          .map((line) => line.trim())
          .filter(Boolean)
      );
    });
  });
}

async function getWindowsCodeCliProbeCommands(candidate, options = {}) {
  if (typeof candidate !== 'string') {
    return [candidate];
  }

  const env = options.env || process.env;
  const findCommand = options.findCommand || ((command) => findWindowsCommand(command, env));
  const fileExists = options.fileExists || fs.existsSync;
  const allowCommandScripts = Boolean(options.allowCommandScripts);
  const discovered = await findCommand(candidate);
  const commands = hasWindowsPathSeparator(candidate) || path.win32.isAbsolute(candidate) ? [candidate, ...discovered] : discovered;
  const results = [];
  const seen = new Set();

  for (const command of commands) {
    if (!command || seen.has(command)) {
      continue;
    }
    seen.add(command);
    const backingExecutable = getWindowsCodeBackingExecutable(command, fileExists);
    const backingKey = backingExecutable ? `${backingExecutable.command}\0${backingExecutable.argsPrefix.join('\0')}` : undefined;
    if (backingExecutable) {
      if (!seen.has(backingKey)) {
        results.push(backingExecutable);
        seen.add(backingKey);
      }
      continue;
    }

    const extension = path.win32.extname(command).toLowerCase();
    if (extension === '.cmd' || extension === '.bat') {
      if (allowCommandScripts) {
        results.push(command);
      }
      continue;
    }
    if (extension === '.exe' && WINDOWS_CODE_EXE_BASENAMES.has(path.win32.basename(command).toLowerCase())) {
      continue;
    }
    results.push(command);
  }

  return results;
}

function createSpawnOptions(command, args, cwd, platform = process.platform, env = process.env) {
  if (platform === 'win32') {
    [command, ...args].forEach(rejectUnsafeWindowsCommandToken);
  }

  if (platform === 'win32' && shouldUseWindowsCommandShell(command, env)) {
    return {
      command: env.ComSpec || 'cmd.exe',
      args: ['/d', '/s', '/v:off', '/c', [command, ...args].map(quoteWindowsCommandToken).join(' ')],
      options: { cwd, env, stdio: 'inherit', shell: false }
    };
  }

  return {
    command,
    args,
    options: { cwd, env, stdio: 'inherit', shell: false }
  };
}

function mergeCommandEnvironment(baseEnv, commandEnv) {
  const merged = { ...baseEnv };
  for (const [key, value] of Object.entries(commandEnv || {})) {
    if (value === undefined) {
      delete merged[key];
    } else {
      merged[key] = value;
    }
  }
  return merged;
}

function runCommand(command, options = {}) {
  const dryRun = Boolean(options.dryRun);
  const platform = options.platform || process.platform;
  const env = mergeCommandEnvironment(options.env || process.env, command.env);

  console.log(`[wallstop-pr-comments] ${command.label}: ${formatCommand(command)}`);
  if (dryRun) {
    return Promise.resolve();
  }

  const spawnConfig = createSpawnOptions(command.command, command.args, command.cwd, platform, env);
  return new Promise((resolve, reject) => {
    const child = spawn(spawnConfig.command, spawnConfig.args, spawnConfig.options);
    child.on('error', (error) => {
      reject(new Error(`${command.label} failed to start: ${error.message}`));
    });
    child.on('exit', (code, signal) => {
      if (code === 0) {
        resolve();
        return;
      }
      const exitDetail = signal ? `signal ${signal}` : `exit code ${code}`;
      reject(new Error(`${command.label} failed with ${exitDetail}.`));
    });
  });
}

function probeCommand(command, options = {}) {
  const platform = options.platform || process.platform;
  const normalizedCommand = typeof command === 'string'
    ? { command, argsPrefix: [], env: undefined }
    : normalizeCodeCli(command);
  const env = { ...(options.env || process.env), ...(normalizedCommand.env || {}) };
  const spawnConfig = createSpawnOptions(
    normalizedCommand.command,
    [...normalizedCommand.argsPrefix, '--version'],
    process.cwd(),
    platform,
    env
  );

  return new Promise((resolve) => {
    const child = spawn(spawnConfig.command, spawnConfig.args, {
      ...spawnConfig.options,
      stdio: 'ignore'
    });
    const timer = setTimeout(() => {
      child.kill();
      resolve(false);
    }, 10000);

    child.on('error', () => {
      clearTimeout(timer);
      resolve(false);
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      resolve(code === 0);
    });
  });
}

async function resolveCodeCli(options = {}) {
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const candidates = [];
  if (options.codeCli) {
    candidates.push({ value: options.codeCli, explicit: true });
  }
  if (env[CODE_CLI_ENV]) {
    candidates.push({ value: env[CODE_CLI_ENV], explicit: true });
  }
  candidates.push(...(options.candidates || DEFAULT_CODE_CLI_CANDIDATES).map((candidate) => ({ value: candidate, explicit: false })));

  const seen = new Set();
  for (const candidateEntry of candidates) {
    const candidate = candidateEntry.value;
    const candidateKey = typeof candidate === 'string'
      ? candidate
      : `${candidate.command}\0${(candidate.argsPrefix || []).join('\0')}`;
    if (!candidate || seen.has(candidateKey)) {
      continue;
    }
    seen.add(candidateKey);
    const commandsToProbe = platform === 'win32'
      ? await getWindowsCodeCliProbeCommands(candidate, {
          env,
          findCommand: options.findCommand,
          fileExists: options.fileExists,
          allowCommandScripts: candidateEntry.explicit
        })
      : [candidate];

    for (const command of commandsToProbe) {
      const ok = await options.probe(command);
      if (ok) {
        return command;
      }
    }

    if (candidateEntry.explicit) {
      const candidateLabel = typeof candidate === 'string' ? candidate : candidate.command;
      throw new Error(`Explicit VS Code CLI was not usable: ${candidateLabel}`);
    }
  }

  throw new Error(
    `Could not find a VS Code command-line tool. Set ${CODE_CLI_ENV} or run "Shell Command: Install 'code' command in PATH" from VS Code.`
  );
}

async function executeSetupPlan(plan, options = {}) {
  const dryRun = Boolean(options.dryRun);
  const platform = options.platform || process.platform;
  const env = options.env || process.env;

  for (const command of plan.commands) {
    await runCommand(command, { dryRun, platform, env });
  }
}

function printHelp() {
  console.log(`Wallstop PR Comments local installer

Usage:
  npm run setup
  npm run install:local
  node scripts/install-local.js [options]

Options:
  --setup-only                Restore dependencies and compile without packaging or installing.
  --code-cli <path-or-name>   Use a specific VS Code-compatible command-line tool.
  --vsix-out <path>           Write the packaged VSIX to a specific path.
  --skip-dependency-restore   Skip npm ci in the extension source directory.
  --skip-tests                Compile before packaging instead of running npm test.
  --dry-run                   Print planned steps without changing files.
  -h, --help                  Show this help.

Environment:
  ${CODE_CLI_ENV}             Overrides VS Code CLI discovery.
`);
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return;
  }

  const codeCli = options.setupOnly
    ? undefined
    : await resolveCodeCli({
        codeCli: options.codeCli,
        env: process.env,
        probe: (command) => probeCommand(command, { platform: process.platform, env: process.env })
      });
  const plan = createSetupPlan({ ...options, codeCli });
  await executeSetupPlan(plan, {
    dryRun: options.dryRun,
    platform: process.platform,
    env: process.env
  });

  if (options.dryRun) {
    console.log('[wallstop-pr-comments] Dry run complete. No files were changed.');
  } else if (options.setupOnly) {
    console.log('[wallstop-pr-comments] Setup complete.');
  } else {
    console.log('[wallstop-pr-comments] Install complete. Reload VS Code to activate the extension.');
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`E_WALLSTOP_PR_COMMENTS_INSTALL_FAILED: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  CODE_CLI_ENV,
  DEFAULT_CODE_CLI_CANDIDATES,
  createCodeCliCommand,
  getNpmCommandEnvironment,
  createSetupPlan,
  createSpawnOptions,
  executeSetupPlan,
  findWindowsCommand,
  getWindowsCodeBackingExecutable,
  mergeCommandEnvironment,
  parseArgs,
  resolveCodeCli,
  resolveNpmInvocation
};
