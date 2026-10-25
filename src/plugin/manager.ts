import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

import type { AppEvent, AppEventType } from '../log/types.js';
import type { PluginFailure } from './failures.js';
import { installPluginPackage, pluginPackagesRoot, scanPluginPackage, type PluginPackage } from './package-store.ts';

export type PluginState = 'untrusted' | 'disabled' | 'enabled' | 'invalid' | 'quarantined' | 'probing';
export interface PluginCircuitView {
  state: 'quarantined' | 'probing';
  contributionKind: string;
  contributionName: string;
  category: string;
  count: number;
  retryAt?: string;
  lastError: string;
  strikes: number;
}
export interface PluginView {
  package: PluginPackage;
  state: PluginState;
  problems: string[];
  requiresRestart: boolean;
  circuit?: PluginCircuitView;
}
export type PluginEventSink = (type: AppEventType, data: AppEvent['data']) => void;

interface Lifecycle { trusted: boolean; enabled: boolean; circuit?: PluginCircuitView | undefined }
const keyOf = (id: string, hash: string): string => `${id}\0${hash}`;
const asString = (value: unknown): string => typeof value === 'string' ? value : '';

export class PluginManager {
  private lifecycle = new Map<string, Lifecycle>();
  private runtimeEnabled = new Map<string, boolean>();
  private versions = new Map<string, string>();
  private readonly dataDir: string;
  private readonly emit: PluginEventSink;

  constructor(dataDir: string, emit: PluginEventSink = () => {}) {
    this.dataDir = dataDir;
    this.emit = emit;
  }

  setEvents(events: readonly AppEvent[]): void {
    this.lifecycle.clear();
    this.versions.clear();
    for (const event of [...events].sort((a, b) => a.seq - b.seq)) {
      if (!event.type.startsWith('plugin/')) continue;
      const data = event.data as Record<string, unknown>;
      const id = asString(data['id']);
      const hash = asString(data['contentHash']);
      if (!id || !hash) continue;
      const key = keyOf(id, hash);
      const current = this.lifecycle.get(key) ?? { trusted: false, enabled: false };
      if (event.type === 'plugin/installed' && typeof data['version'] === 'string') {
        current.trusted = true;
        this.versions.set(key, data['version']);
      } else if (event.type === 'plugin/enabled' && current.trusted) current.enabled = true;
      else if (event.type === 'plugin/disabled') current.enabled = false;
      else if (event.type === 'plugin/quarantined') {
        const previous = current.circuit;
        current.circuit = {
          state: 'quarantined', contributionKind: asString(data['contributionKind']), contributionName: asString(data['contributionName']),
          category: asString(data['category']), count: Number(data['count']) || 0, retryAt: asString(data['retryAt']),
          lastError: asString(data['reason']) || event.ts, strikes: (previous?.strikes ?? 0) + 1,
        };
      } else if (event.type === 'plugin/probe-started' && current.circuit) {
        current.circuit = { ...current.circuit, state: 'quarantined', retryAt: event.ts };
      } else if (event.type === 'plugin/recovered') current.circuit = undefined;
      this.lifecycle.set(key, current);
    }
    this.runtimeEnabled = new Map([...this.lifecycle].map(([key, value]) => [key, value.enabled]));
  }

  install(sourceDir: string): PluginPackage { return installPluginPackage(sourceDir, this.dataDir); }

  confirm(id: string, contentHash: string): void {
    const plugin = this.requirePackage(id, contentHash);
    if (this.state(id, contentHash).trusted) return;
    this.emit('plugin/installed', { id, version: plugin.manifest.version, contentHash, path: plugin.rootDir, by: 'human' });
    this.lifecycle.set(keyOf(id, contentHash), { trusted: true, enabled: false });
    this.versions.set(keyOf(id, contentHash), plugin.manifest.version);
  }

  setEnabled(id: string, contentHash: string, enabled: boolean): void {
    this.requirePackage(id, contentHash);
    const state = this.lifecycle.get(keyOf(id, contentHash));
    if (!state?.trusted) throw new Error(`Plugin ${id}@${contentHash} must be confirmed before enablement`);
    if (state.enabled === enabled) return;
    this.emit(enabled ? 'plugin/enabled' : 'plugin/disabled', { id, contentHash });
    this.lifecycle.set(keyOf(id, contentHash), { ...state, enabled });
  }

  recordFailure(id: string, contentHash: string, reason: string): void {
    this.requirePackage(id, contentHash);
    this.emit('plugin/failed', { id, contentHash, reason });
  }

  quarantine(failure: PluginFailure, count: number, retryAt: string, failedAt: string): void {
    this.requirePackage(failure.pluginId, failure.contentHash);
    const state = this.lifecycle.get(keyOf(failure.pluginId, failure.contentHash));
    if (!state?.trusted || !state.enabled) return;
    this.emit('plugin/quarantined', {
      id: failure.pluginId, contentHash: failure.contentHash, contributionKind: failure.contributionKind,
      contributionName: failure.contributionName, category: failure.category, count, retryAt, failedAt, reason: failure.message,
    });
    this.lifecycle.set(keyOf(failure.pluginId, failure.contentHash), { ...state, circuit: {
      state: 'quarantined', contributionKind: failure.contributionKind, contributionName: failure.contributionName,
      category: failure.category, count, retryAt, lastError: failure.message, strikes: (state.circuit?.strikes ?? 0) + 1,
    } });
  }

  beginProbe(id: string, hash: string, probeAt: string): boolean {
    const state = this.lifecycle.get(keyOf(id, hash));
    if (!state?.circuit || state.circuit.state !== 'quarantined') return false;
    const circuit = state.circuit;
    this.emit('plugin/probe-started', { id, contentHash: hash, contributionKind: circuit.contributionKind,
      contributionName: circuit.contributionName, category: circuit.category, count: circuit.count, probeAt });
    this.lifecycle.set(keyOf(id, hash), { ...state, circuit: { ...circuit, state: 'probing' } });
    return true;
  }

  recovered(id: string, hash: string, recoveredAt: string): void {
    const state = this.lifecycle.get(keyOf(id, hash));
    if (!state?.circuit) return;
    const circuit = state.circuit;
    this.emit('plugin/recovered', { id, contentHash: hash, contributionKind: circuit.contributionKind,
      contributionName: circuit.contributionName, category: circuit.category, count: circuit.count, recoveredAt });
    this.lifecycle.set(keyOf(id, hash), { ...state, circuit: undefined });
  }

  list(): PluginView[] {
    return this.discover().map((candidate) => {
      const lifecycle = this.state(candidate.id, candidate.hash);
      const key = keyOf(candidate.id, candidate.hash);
      const problems: string[] = [];
      let plugin: PluginPackage;
      try {
        plugin = scanPluginPackage(candidate.rootDir);
        if (plugin.manifest.id !== candidate.id) throw new Error(`Package id mismatch: ${plugin.manifest.id}`);
      } catch (error) {
        problems.push(error instanceof Error ? error.message : String(error));
        plugin = { rootDir: candidate.rootDir, contentHash: candidate.hash, fileCount: 0, totalBytes: 0,
          manifest: { apiVersion: 1, id: candidate.id, version: this.versions.get(key) ?? '0.0.0',
            engine: { irmia: '>=0.0.0' }, contributions: { skills: [] }, permissions: [] } };
      }
      const state: PluginState = problems.length ? 'invalid' : !lifecycle.trusted ? 'untrusted' : !lifecycle.enabled ? 'disabled' : lifecycle.circuit?.state ?? 'enabled';
      return { package: plugin, state, problems, requiresRestart: lifecycle.enabled !== (this.runtimeEnabled.get(key) ?? false),
        ...(lifecycle.circuit !== undefined ? { circuit: lifecycle.circuit } : {}) };
    });
  }

  active(): PluginPackage[] {
    return this.list().filter((view) => view.state === 'enabled' && !view.requiresRestart).map((view) => view.package)
      .sort((a, b) => a.manifest.id.localeCompare(b.manifest.id) || a.contentHash.localeCompare(b.contentHash));
  }

  hookProbes(): PluginPackage[] {
    return this.list().filter((view) => view.state === 'probing' && view.circuit?.contributionKind === 'hook'
      && view.package.manifest.contributions.hooks !== undefined).map((view) => view.package);
  }

  private state(id: string, hash: string): Lifecycle { return this.lifecycle.get(keyOf(id, hash)) ?? { trusted: false, enabled: false }; }

  private requirePackage(id: string, hash: string): PluginPackage {
    if (!/^[a-z0-9-]{1,64}$/.test(id) || !/^[a-f0-9]{64}$/.test(hash)) throw new Error('Invalid plugin id or contentHash');
    const plugin = scanPluginPackage(join(pluginPackagesRoot(this.dataDir), id, hash));
    if (plugin.manifest.id !== id) throw new Error(`Plugin id mismatch: ${plugin.manifest.id}`);
    return plugin;
  }

  private discover(): { id: string; hash: string; rootDir: string }[] {
    const root = pluginPackagesRoot(this.dataDir);
    if (!existsSync(root)) return [];
    const out: { id: string; hash: string; rootDir: string }[] = [];
    for (const id of readdirSync(root, { withFileTypes: true })) {
      if (!id.isDirectory() || !/^[a-z0-9-]{1,64}$/.test(id.name)) continue;
      for (const hash of readdirSync(join(root, id.name), { withFileTypes: true })) {
        if (hash.isDirectory() && /^[a-f0-9]{64}$/.test(hash.name)) out.push({ id: id.name, hash: hash.name, rootDir: join(root, id.name, hash.name) });
      }
    }
    return out.sort((a, b) => a.id.localeCompare(b.id) || a.hash.localeCompare(b.hash));
  }
}
