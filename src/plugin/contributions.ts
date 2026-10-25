import { readFileSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';

import { loadHookConfig, type HookConfigEntry } from '../hook/hooks.ts';
import { parseMcpServers, type McpServerEntry } from '../mcp/client.ts';
import type { PluginPackage } from './package-store.ts';

export interface PluginSkillRoot { dir: string; rootName: string; packageHash: string }

export function composePluginSkillRoots(packages: readonly PluginPackage[]): PluginSkillRoot[] {
  return packages.flatMap((pkg) => pkg.manifest.contributions.skills.map((path) => ({
    dir: join(pkg.rootDir, path),
    rootName: relative(process.cwd(), join(pkg.rootDir, path)).split(sep).join('/'),
    packageHash: pkg.contentHash,
  })));
}

function inside(root: string, candidate: string): boolean {
  const rel = relative(root, candidate);
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

export function composePluginHooks(packages: readonly PluginPackage[]): { entries: HookConfigEntry[]; warnings: string[] } {
  const entries: HookConfigEntry[] = [];
  const warnings: string[] = [];
  for (const pkg of packages) {
    const declaration = pkg.manifest.contributions.hooks;
    if (declaration === undefined) continue;
    const loaded = loadHookConfig(join(pkg.rootDir, declaration));
    warnings.push(...loaded.problems.map((problem) => `${pkg.manifest.id}: ${problem}`));
    for (const entry of loaded.entries) {
      const cwd = entry.cwd === undefined ? pkg.rootDir : resolve(pkg.rootDir, entry.cwd);
      if (!inside(pkg.rootDir, cwd)) {
        warnings.push(`${pkg.manifest.id}: Hook cwd escapes the package: ${entry.cwd}`);
        continue;
      }
      entries.push({ ...entry, cwd, plugin: { id: pkg.manifest.id, contentHash: pkg.contentHash, contributionName: `${entry.hook}:${entry.matcher}` } });
    }
  }
  return { entries, warnings };
}

export function composePluginMcp(packages: readonly PluginPackage[], extraLaunchers?: readonly string[]): { servers: McpServerEntry[]; warnings: string[] } {
  const servers: McpServerEntry[] = [];
  const warnings: string[] = [];
  const names = new Set<string>();
  for (const pkg of packages) {
    const declaration = pkg.manifest.contributions.mcp;
    if (declaration === undefined) continue;
    let raw: unknown;
    try {
      raw = JSON.parse(readFileSync(join(pkg.rootDir, declaration), 'utf8'));
    } catch (error) {
      warnings.push(`${pkg.manifest.id}: ${error instanceof Error ? error.message : String(error)}`);
      continue;
    }
    if (!Array.isArray(raw)) {
      warnings.push(`${pkg.manifest.id}: MCP declaration must be an array`);
      continue;
    }
    const parsed: McpServerEntry[] = [];
    raw.forEach((item, index) => {
      try {
        parsed.push(...parseMcpServers([item], `${pkg.manifest.id}.mcp[${index}]`, extraLaunchers));
      } catch (error) {
        warnings.push(`${pkg.manifest.id}: ${error instanceof Error ? error.message : String(error)}`);
      }
    });
    for (const entry of parsed) {
      const name = `${pkg.manifest.id}__${entry.name}`;
      if (name.length > 128) {
        warnings.push(`${pkg.manifest.id}: MCP name exceeds 128 characters: ${name}`);
        continue;
      }
      if (names.has(name)) {
        warnings.push(`${pkg.manifest.id}: duplicate MCP name ${name}; later declaration ignored`);
        continue;
      }
      const cwd = entry.cwd === undefined ? pkg.rootDir : resolve(pkg.rootDir, entry.cwd);
      if (!inside(pkg.rootDir, cwd)) {
        warnings.push(`${pkg.manifest.id}: MCP cwd escapes the package: ${entry.cwd}`);
        continue;
      }
      names.add(name);
      servers.push({ ...entry, name, cwd });
    }
  }
  return { servers, warnings };
}
