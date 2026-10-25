import type { HookConfigEntry } from '../hook/hooks.js';
import type { McpServerEntry } from '../mcp/client.js';
import { composePluginHooks, composePluginMcp, composePluginSkillRoots, type PluginSkillRoot } from './contributions.ts';
import type { PluginManager } from './manager.js';
import { pluginPackagesRoot, type PluginPackage } from './package-store.ts';

export interface PluginRuntimeComposition {
  packages: PluginPackage[];
  skillRoots: PluginSkillRoot[];
  hookEntries: HookConfigEntry[];
  mcpServers: McpServerEntry[];
  warnings: string[];
}

export function composePluginRuntime(manager: PluginManager, extraLaunchers?: readonly string[]): PluginRuntimeComposition {
  const packages = manager.active();
  const hooks = composePluginHooks(packages);
  const hookProbes = manager.hookProbes().flatMap((pkg) => {
    const circuit = manager.list().find((view) => view.package.manifest.id === pkg.manifest.id
      && view.package.contentHash === pkg.contentHash)?.circuit;
    if (circuit?.contributionKind !== 'hook') return [];
    const composed = composePluginHooks([pkg]);
    return composed.entries.filter((entry) => entry.plugin?.contributionName === circuit.contributionName);
  });
  const mcp = composePluginMcp(packages, extraLaunchers);
  return {
    packages,
    skillRoots: composePluginSkillRoots(packages),
    hookEntries: [...hooks.entries, ...hookProbes],
    mcpServers: mcp.servers,
    warnings: [...manager.list().flatMap((view) => view.problems), ...hooks.warnings, ...mcp.warnings],
  };
}

export function mergeMcpDeclarations(configServers: readonly McpServerEntry[], pluginServers: readonly McpServerEntry[]): McpServerEntry[] {
  const merged = [...configServers, ...pluginServers];
  const names = new Set<string>();
  for (const entry of merged) {
    if (names.has(entry.name)) throw new Error(`Duplicate MCP declaration name: ${entry.name}`);
    names.add(entry.name);
  }
  return merged;
}

export function mapPluginMcpOwners(
  configServers: readonly McpServerEntry[],
  packages: readonly PluginPackage[],
  extraLaunchers?: readonly string[],
): Map<string, { pluginId: string; contentHash: string }> {
  const composed = composePluginMcp(packages, extraLaunchers);
  try {
    mergeMcpDeclarations(configServers, composed.servers);
  } catch {
    return new Map();
  }
  const accepted = new Set(composed.servers.map((server) => server.name));
  const owners = new Map<string, { pluginId: string; contentHash: string }>();
  for (const pkg of packages) {
    for (const server of composePluginMcp([pkg], extraLaunchers).servers) {
      if (accepted.has(server.name) && !owners.has(server.name)) {
        owners.set(server.name, { pluginId: pkg.manifest.id, contentHash: pkg.contentHash });
      }
    }
  }
  return owners;
}

export function pluginProtectedPaths(dataDir: string): string[] {
  return [pluginPackagesRoot(dataDir)];
}
