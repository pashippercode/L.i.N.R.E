import { createHash, randomUUID } from 'node:crypto';
import { cpSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { AGENT_VERSION } from '../version.ts';
import { isPluginEngineCompatible, parsePluginManifest, type PluginManifest } from './manifest.ts';

export const PLUGIN_FILE_LIMITS = Object.freeze({ maxFiles: 256, maxFileBytes: 1024 * 1024, maxTotalBytes: 8 * 1024 * 1024 });

export interface PluginPackage {
  readonly rootDir: string;
  readonly contentHash: string;
  readonly fileCount: number;
  readonly totalBytes: number;
  readonly manifest: PluginManifest;
}

interface ScannedFile { absolute: string; relative: string; bytes: Buffer }

export function pluginPackagesRoot(dataDir: string): string {
  return join(dataDir, 'plugins', 'packages');
}

function scanFiles(rootDir: string): ScannedFile[] {
  const root = realpathSync(rootDir);
  const files: ScannedFile[] = [];
  let totalBytes = 0;
  function walk(dir: string): void {
    const entries = readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const absolute = join(dir, entry.name);
      const stat = lstatSync(absolute);
      if (stat.isSymbolicLink()) throw new Error(`Plugin contains a symbolic link: ${absolute}`);
      if (stat.isDirectory()) {
        walk(absolute);
        continue;
      }
      if (!stat.isFile()) throw new Error(`Plugin contains a non-regular entry: ${absolute}`);
      if (stat.size > PLUGIN_FILE_LIMITS.maxFileBytes) throw new Error(`Plugin file size exceeds ${PLUGIN_FILE_LIMITS.maxFileBytes}: ${absolute}`);
      totalBytes += stat.size;
      if (totalBytes > PLUGIN_FILE_LIMITS.maxTotalBytes) throw new Error(`Plugin total size exceeds ${PLUGIN_FILE_LIMITS.maxTotalBytes}`);
      if (files.length >= PLUGIN_FILE_LIMITS.maxFiles) throw new Error(`Plugin file count exceeds ${PLUGIN_FILE_LIMITS.maxFiles}`);
      const relativePath = relative(root, absolute).split(sep).join('/');
      files.push({ absolute, relative: relativePath, bytes: readFileSync(absolute) });
    }
  }
  walk(root);
  return files;
}

function hashFiles(files: readonly ScannedFile[]): string {
  const hash = createHash('sha256');
  for (const file of [...files].sort((a, b) => a.relative.localeCompare(b.relative))) {
    hash.update(file.relative);
    hash.update('\0');
    hash.update(file.bytes);
  }
  return hash.digest('hex');
}

function scan(rootDir: string, expectedHash?: string): PluginPackage {
  const files = scanFiles(rootDir);
  const contentHash = hashFiles(files);
  if (expectedHash !== undefined && contentHash !== expectedHash) throw new Error(`Installed plugin contentHash mismatch: expected ${expectedHash}, got ${contentHash}`);
  const manifestPath = join(rootDir, 'plugin.json');
  const manifest = parsePluginManifest(JSON.parse(readFileSync(manifestPath, 'utf8')), manifestPath);
  if (!isPluginEngineCompatible(manifest.engine.irmia, AGENT_VERSION)) {
    throw new Error(`Plugin ${manifest.id} requires Irmia ${manifest.engine.irmia}; current version is ${AGENT_VERSION}`);
  }
  return { rootDir, contentHash, fileCount: files.length, totalBytes: files.reduce((sum, file) => sum + file.bytes.length, 0), manifest };
}

export function scanPluginPackage(rootDir: string): PluginPackage {
  const root = realpathSync(rootDir);
  const expectedHash = /^[a-f0-9]{64}$/.test(basename(root)) ? basename(root) : undefined;
  return scan(root, expectedHash);
}

export function assertPluginSourceOutsideStore(source: string, destinationRoot: string): void {
  const relation = relative(destinationRoot, source);
  if (relation === '' || (!relation.startsWith(`..${sep}`) && relation !== '..' && !isAbsolute(relation))) {
    throw new Error('Plugin source is inside the destination package store; refusing recursive installation');
  }
}

export function installPluginPackage(sourceDir: string, dataDir: string): PluginPackage {
  const source = realpathSync(sourceDir);
  const destinationRoot = resolve(pluginPackagesRoot(dataDir));
  assertPluginSourceOutsideStore(source, destinationRoot);
  const scanned = scan(source);
  const parent = join(destinationRoot, scanned.manifest.id);
  const destination = join(parent, scanned.contentHash);
  if (existsSync(destination)) return scan(destination, scanned.contentHash);
  mkdirSync(parent, { recursive: true });
  const temporary = join(parent, `.${basename(destination)}.${randomUUID()}.tmp`);
  try {
    cpSync(source, temporary, { recursive: true, dereference: false, errorOnExist: true });
    scan(temporary, scanned.contentHash);
    renameSync(temporary, destination);
  } catch (error) {
    rmSync(temporary, { recursive: true, force: true });
    throw error;
  }
  return scan(destination, scanned.contentHash);
}
