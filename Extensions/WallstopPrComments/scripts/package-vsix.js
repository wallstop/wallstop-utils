#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const yazl = require('yazl');

const CONTENT_TYPES_PATH = '[Content_Types].xml';
const VSIX_MANIFEST_PATH = 'extension.vsixmanifest';
const STABLE_ZIP_MTIME = new Date(Date.UTC(2024, 0, 1, 0, 0, 0));
const STABLE_FILE_MODE = 0o100644;

function compareOrdinal(left, right) {
  if (left < right) {
    return -1;
  }
  if (left > right) {
    return 1;
  }
  return 0;
}

function parseArgs(argv) {
  const options = {
    out: undefined,
    help: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--out') {
      index += 1;
      if (index >= argv.length || argv[index].startsWith('--')) {
        throw new Error('--out requires a path value.');
      }
      options.out = argv[index];
    } else if (arg.startsWith('--out=')) {
      options.out = arg.slice('--out='.length);
      if (!options.out) {
        throw new Error('--out requires a non-empty path value.');
      }
    } else if (arg === '--help' || arg === '-h') {
      options.help = true;
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }

  return options;
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function assertSafeIdentifier(value, fieldName) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)) {
    throw new Error(`package.json ${fieldName} must be a simple VSIX identifier.`);
  }
}

function normalizeZipPath(value) {
  return value.split(path.sep).join('/');
}

function escapeXml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function getDefaultVsixPath(extensionRoot, manifest) {
  assertSafeIdentifier(manifest.name, 'name');
  assertSafeIdentifier(manifest.version, 'version');
  return path.join(extensionRoot, 'dist', `${manifest.name}-${manifest.version}.vsix`);
}

function getContentTypeForExtension(extension) {
  switch (extension.toLowerCase()) {
    case 'cjs':
    case 'js':
    case 'mjs':
      return 'application/javascript';
    case 'json':
    case 'map':
      return 'application/json';
    case 'md':
    case 'markdown':
      return 'text/markdown';
    case 'svg':
      return 'image/svg+xml';
    case 'txt':
      return 'text/plain';
    case 'vsixmanifest':
    case 'xml':
      return 'text/xml';
    case 'css':
      return 'text/css';
    case 'html':
      return 'text/html';
    case 'yaml':
    case 'yml':
      return 'application/yaml';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'wasm':
      return 'application/wasm';
    default:
      return 'application/octet-stream';
  }
}

function getZipExtension(zipPath) {
  const baseName = path.posix.basename(zipPath);
  const dotIndex = baseName.lastIndexOf('.');
  if (dotIndex <= 0 || dotIndex === baseName.length - 1) {
    return '';
  }
  return baseName.slice(dotIndex + 1).toLowerCase();
}

function createContentTypesXml(entries = []) {
  const defaults = new Map([
    ['vsixmanifest', 'text/xml'],
    ['xml', 'text/xml']
  ]);
  const overrides = [];

  for (const entry of entries) {
    const zipPath = typeof entry === 'string' ? entry : entry.zipPath;
    const extension = getZipExtension(zipPath);
    if (extension) {
      defaults.set(extension, getContentTypeForExtension(extension));
    } else {
      overrides.push({
        partName: `/${zipPath}`,
        contentType: 'text/plain'
      });
    }
  }

  const defaultNodes = Array.from(defaults.entries())
    .sort(([left], [right]) => compareOrdinal(left, right))
    .map(([extension, contentType]) => `  <Default Extension="${escapeXml(extension)}" ContentType="${escapeXml(contentType)}"/>`);
  const overrideNodes = overrides
    .sort((left, right) => compareOrdinal(left.partName, right.partName))
    .map((override) => `  <Override PartName="${escapeXml(override.partName)}" ContentType="${escapeXml(override.contentType)}"/>`);

  return `<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
${[...defaultNodes, ...overrideNodes].join('\n')}
</Types>
`;
}

function createVsixManifestXml(manifest) {
  assertSafeIdentifier(manifest.name, 'name');
  assertSafeIdentifier(manifest.publisher, 'publisher');
  assertSafeIdentifier(manifest.version, 'version');
  const categories = Array.isArray(manifest.categories) ? manifest.categories.join(',') : '';
  const engine = manifest.engines && typeof manifest.engines.vscode === 'string' ? manifest.engines.vscode : '';

  return `<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="${escapeXml(manifest.name)}" Version="${escapeXml(manifest.version)}" Publisher="${escapeXml(manifest.publisher)}"/>
    <DisplayName>${escapeXml(manifest.displayName || manifest.name)}</DisplayName>
    <Description xml:space="preserve">${escapeXml(manifest.description || '')}</Description>
    <Categories>${escapeXml(categories)}</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="${escapeXml(engine)}"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
`;
}

function walkFiles(root, options = {}) {
  const results = [];
  const entries = fs.readdirSync(root, { withFileTypes: true });
  entries.sort((left, right) => compareOrdinal(left.name, right.name));

  for (const entry of entries) {
    const absolutePath = path.join(root, entry.name);
    if (entry.isSymbolicLink()) {
      throw new Error(`Unsafe VSIX symlink: ${absolutePath}`);
    }
    if (entry.isDirectory()) {
      if (options.skipNestedNodeModules === true && entry.name === 'node_modules') {
        continue;
      }
      results.push(...walkFiles(absolutePath, options));
    } else if (entry.isFile()) {
      results.push(absolutePath);
    }
  }

  return results;
}

function addDirectoryEntries(entries, extensionRoot, sourceDir, targetPrefix, options = {}) {
  if (!fs.existsSync(sourceDir)) {
    throw new Error(`Required VSIX input is missing: ${sourceDir}`);
  }
  assertSafeSourceDirectory(extensionRoot, sourceDir);
  const files = walkFiles(sourceDir, options);
  for (const filePath of files) {
    const relativePath = path.relative(sourceDir, filePath);
    entries.push({
      sourcePath: filePath,
      zipPath: normalizeZipPath(path.join('extension', targetPrefix, relativePath))
    });
  }
  return entries;
}

function isPathUnderRoot(root, candidate) {
  const relativePath = path.relative(root, candidate);
  return Boolean(relativePath) && !relativePath.startsWith('..') && !path.isAbsolute(relativePath);
}

function isSamePathOrUnderRoot(root, candidate) {
  const relativePath = path.relative(root, candidate);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

function getExistingRealPath(candidate) {
  return fs.realpathSync(candidate);
}

function getExistingFileIdentity(candidate) {
  if (!fs.existsSync(candidate)) {
    return undefined;
  }

  const stat = fs.lstatSync(candidate);
  if (stat.isSymbolicLink() || !stat.isFile()) {
    throw new Error(`Unsafe VSIX output path: ${candidate}`);
  }

  return {
    dev: stat.dev,
    ino: stat.ino
  };
}

function isSameFileIdentity(left, right) {
  return Boolean(left && right && left.dev === right.dev && left.ino === right.ino);
}

function getOutputComparisonPath(outPath) {
  const absoluteOutPath = path.resolve(outPath);
  if (fs.existsSync(absoluteOutPath)) {
    const stat = fs.lstatSync(absoluteOutPath);
    if (stat.isSymbolicLink() || !stat.isFile()) {
      throw new Error(`Unsafe VSIX output path: ${outPath}`);
    }
    return getExistingRealPath(absoluteOutPath);
  }

  let nearestExistingParent = path.dirname(absoluteOutPath);
  while (!fs.existsSync(nearestExistingParent)) {
    const parent = path.dirname(nearestExistingParent);
    if (parent === nearestExistingParent) {
      throw new Error(`Unsafe VSIX output path: ${outPath}`);
    }
    nearestExistingParent = parent;
  }

  const parentRealPath = getExistingRealPath(nearestExistingParent);
  return path.resolve(parentRealPath, path.relative(nearestExistingParent, absoluteOutPath));
}

function assertSafeSourceDirectory(extensionRoot, sourceDir) {
  const extensionRootRealPath = getExistingRealPath(extensionRoot);
  const sourceRealPath = getExistingRealPath(sourceDir);
  if (!isPathUnderRoot(extensionRootRealPath, sourceRealPath)) {
    throw new Error(`Unsafe VSIX source directory: ${sourceDir}`);
  }
}

function assertSafeSourceFile(extensionRoot, sourcePath) {
  const extensionRootRealPath = getExistingRealPath(extensionRoot);
  const sourceRealPath = getExistingRealPath(sourcePath);
  if (!isPathUnderRoot(extensionRootRealPath, sourceRealPath)) {
    throw new Error(`Unsafe VSIX source file: ${sourcePath}`);
  }
}

function assertSafePackageLockPath(packagePath) {
  if (typeof packagePath !== 'string' || !packagePath.startsWith('node_modules/')) {
    throw new Error(`Unsafe package-lock package path: ${packagePath}`);
  }
  if (path.posix.isAbsolute(packagePath) || packagePath.includes('\\') || packagePath.includes('\0')) {
    throw new Error(`Unsafe package-lock package path: ${packagePath}`);
  }

  const segments = packagePath.split('/');
  if (segments.length < 2 || segments[0] !== 'node_modules') {
    throw new Error(`Unsafe package-lock package path: ${packagePath}`);
  }
  for (const segment of segments) {
    if (segment === '' || segment === '.' || segment === '..') {
      throw new Error(`Unsafe package-lock package path: ${packagePath}`);
    }
  }

  return segments;
}

function resolvePackageSourceDir(extensionRoot, packagePath) {
  const segments = assertSafePackageLockPath(packagePath);
  const extensionRootRealPath = getExistingRealPath(extensionRoot);
  const nodeModulesRoot = path.resolve(extensionRoot, 'node_modules');
  const sourceDir = path.resolve(extensionRoot, ...segments);
  if (!fs.existsSync(sourceDir)) {
    throw new Error(`Production dependency is missing from node_modules: ${packagePath}`);
  }

  const nodeModulesRealPath = getExistingRealPath(nodeModulesRoot);
  const sourceRealPath = getExistingRealPath(sourceDir);
  if (
    !isPathUnderRoot(extensionRootRealPath, nodeModulesRealPath) ||
    !isPathUnderRoot(nodeModulesRoot, sourceDir) ||
    !isPathUnderRoot(nodeModulesRealPath, sourceRealPath)
  ) {
    throw new Error(`Unsafe package-lock package path: ${packagePath}`);
  }
  return sourceDir;
}

function getProductionPackagePaths(extensionRoot) {
  const lockPath = path.join(extensionRoot, 'package-lock.json');
  const lock = readJsonFile(lockPath);
  if (!lock.packages || typeof lock.packages !== 'object') {
    throw new Error('package-lock.json must include a packages object.');
  }

  const packagePaths = [];
  for (const [packagePath, metadata] of Object.entries(lock.packages)) {
    if (!packagePath.startsWith('node_modules/')) {
      continue;
    }
    assertSafePackageLockPath(packagePath);
    if (packagePath.includes('/node_modules/.bin')) {
      continue;
    }
    if (metadata && metadata.dev === true) {
      continue;
    }
    const sourceDir = path.resolve(extensionRoot, ...assertSafePackageLockPath(packagePath));
    if (metadata && metadata.optional === true && !fs.existsSync(sourceDir)) {
      continue;
    }
    packagePaths.push(packagePath);
  }

  packagePaths.sort(compareOrdinal);
  return packagePaths;
}

function addProductionDependencyEntries(entries, extensionRoot) {
  for (const packagePath of getProductionPackagePaths(extensionRoot)) {
    const sourceDir = resolvePackageSourceDir(extensionRoot, packagePath);
    addDirectoryEntries(entries, extensionRoot, sourceDir, packagePath, { skipNestedNodeModules: true });
  }
}

function assertSafeVsixOutputPath(extensionRoot, outPath, entries = []) {
  const outputComparisonPath = getOutputComparisonPath(outPath);
  const outputIdentity = getExistingFileIdentity(outPath);
  const packagedFiles = [
    path.join(extensionRoot, 'package.json'),
    path.join(extensionRoot, 'README.md')
  ].map(getExistingRealPath);
  const packagedDirectories = [
    path.join(extensionRoot, 'resources'),
    path.join(extensionRoot, 'out', 'src'),
    ...getProductionPackagePaths(extensionRoot).map((packagePath) => resolvePackageSourceDir(extensionRoot, packagePath))
  ].map(getExistingRealPath);

  if (
    packagedFiles.includes(outputComparisonPath) ||
    packagedDirectories.some((directory) => isSamePathOrUnderRoot(directory, outputComparisonPath)) ||
    entries.some((entry) => isSameFileIdentity(outputIdentity, fs.statSync(entry.sourcePath)))
  ) {
    throw new Error(`Unsafe VSIX output path overlaps packaged input: ${outPath}`);
  }
}

function createVsixEntryPlan(extensionRoot) {
  const manifest = readJsonFile(path.join(extensionRoot, 'package.json'));
  assertSafeSourceFile(extensionRoot, path.join(extensionRoot, 'package.json'));
  assertSafeSourceFile(extensionRoot, path.join(extensionRoot, 'README.md'));
  const entries = [
    {
      sourcePath: path.join(extensionRoot, 'package.json'),
      zipPath: 'extension/package.json'
    },
    {
      sourcePath: path.join(extensionRoot, 'README.md'),
      zipPath: 'extension/README.md'
    }
  ];

  addDirectoryEntries(entries, extensionRoot, path.join(extensionRoot, 'resources'), 'resources');
  addDirectoryEntries(entries, extensionRoot, path.join(extensionRoot, 'out', 'src'), path.join('out', 'src'));
  addProductionDependencyEntries(entries, extensionRoot);

  return {
    manifest,
    entries
  };
}

function getStableZipOptions() {
  return {
    mtime: STABLE_ZIP_MTIME,
    mode: STABLE_FILE_MODE
  };
}

function writeVsixPackage(options = {}) {
  const extensionRoot = path.resolve(options.extensionRoot || path.join(__dirname, '..'));
  const plan = createVsixEntryPlan(extensionRoot);
  const outPath = path.resolve(options.out || getDefaultVsixPath(extensionRoot, plan.manifest));

  assertSafeVsixOutputPath(extensionRoot, outPath, plan.entries);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  const zip = new yazl.ZipFile();
  zip.addBuffer(Buffer.from(createContentTypesXml(plan.entries), 'utf8'), CONTENT_TYPES_PATH, getStableZipOptions());
  zip.addBuffer(Buffer.from(createVsixManifestXml(plan.manifest), 'utf8'), VSIX_MANIFEST_PATH, getStableZipOptions());

  const seen = new Set([CONTENT_TYPES_PATH, VSIX_MANIFEST_PATH]);
  for (const entry of [...plan.entries].sort((left, right) => compareOrdinal(left.zipPath, right.zipPath))) {
    if (seen.has(entry.zipPath)) {
      throw new Error(`Duplicate VSIX entry: ${entry.zipPath}`);
    }
    seen.add(entry.zipPath);
    zip.addFile(entry.sourcePath, entry.zipPath, getStableZipOptions());
  }

  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(outPath);
    output.on('close', () => {
      resolve({
        outPath,
        entryCount: seen.size
      });
    });
    output.on('error', reject);
    zip.on('error', reject);
    zip.outputStream.on('error', reject);
    zip.outputStream.pipe(output);
    zip.end();
  });
}

function printHelp() {
  console.log(`Wallstop PR Comments VSIX packager

Usage:
  npm run package:vsix
  node scripts/package-vsix.js --out <path>
`);
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return;
  }

  const result = await writeVsixPackage({ out: options.out });
  console.log(`[wallstop-pr-comments] Packaged ${result.entryCount} VSIX entries: ${result.outPath}`);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`E_WALLSTOP_PR_COMMENTS_PACKAGE_FAILED: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  CONTENT_TYPES_PATH,
  VSIX_MANIFEST_PATH,
  compareOrdinal,
  createContentTypesXml,
  getContentTypeForExtension,
  createVsixEntryPlan,
  createVsixManifestXml,
  assertSafePackageLockPath,
  assertSafeVsixOutputPath,
  getProductionPackagePaths,
  parseArgs,
  writeVsixPackage
};
