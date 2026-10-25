import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

import { EVENT_VISIBILITY, type AppEvent } from '../src/log/types.ts';
import { PluginManager } from '../src/plugin/manager.ts';
import { installPluginPackage } from '../src/plugin/package-store.ts';
import { tempDirSync } from './helpers/temp-dirs.ts';

function source(version = '1.0.0'): string {
  const dir = tempDirSync('irmia-manager-source-');
  writeFileSync(join(dir, 'plugin.json'), JSON.stringify({
    apiVersion: 1,
    id: 'memory-friend',
    version,
    engine: { irmia: '>=0.1.0-beta.12' },
    contributions: { skills: [] },
    permissions: [],
  }));
  return dir;
}

function harness() {
  const dataDir = tempDirSync('irmia-manager-data-');
  const emitted: AppEvent[] = [];
  const manager = new PluginManager(dataDir, (type, data) => {
    emitted.push({ seq: emitted.length + 1, ts: new Date(0).toISOString(), type, data, visibility: 'internal' } as AppEvent);
  });
  return { manager, emitted, dataDir };
}

test('安装不可信，确认绑定内容后才允许启用，重复命令幂等', () => {
  const { manager, emitted } = harness();
  const installed = manager.install(source());
  assert.equal(manager.list()[0]?.state, 'untrusted');
  assert.equal(emitted.length, 0);
  assert.throws(() => manager.setEnabled(installed.manifest.id, installed.contentHash, true), /confirm|trust/i);
  manager.confirm(installed.manifest.id, installed.contentHash);
  assert.equal(manager.list()[0]?.state, 'disabled');
  manager.confirm(installed.manifest.id, installed.contentHash);
  assert.equal(emitted.length, 1);
  manager.setEnabled(installed.manifest.id, installed.contentHash, true);
  manager.setEnabled(installed.manifest.id, installed.contentHash, true);
  assert.equal(manager.list()[0]?.state, 'enabled');
  assert.equal(manager.list()[0]?.requiresRestart, true);
  assert.equal(manager.active().length, 0);
  assert.equal(emitted.length, 2);
  assert.deepEqual(emitted.map((event) => event.type), ['plugin/installed', 'plugin/enabled']);
});

test('启停按 seq 最后事件生效，旧无关事件不改变插件状态', () => {
  const { manager, dataDir } = harness();
  const installed = installPluginPackage(source(), dataDir);
  const base = { ts: new Date(0).toISOString(), visibility: 'internal' as const };
  manager.setEvents([
    { ...base, seq: 4, type: 'plugin/disabled', data: { id: installed.manifest.id, contentHash: installed.contentHash } },
    { ...base, seq: 2, type: 'plugin/enabled', data: { id: installed.manifest.id, contentHash: installed.contentHash } },
    { ...base, seq: 1, type: 'plugin/installed', data: { id: installed.manifest.id, version: installed.manifest.version, contentHash: installed.contentHash, path: installed.rootDir, by: 'human' } },
    { ...base, seq: 3, type: 'memory/selected', data: { query: 'old', selected: [] } },
  ] as AppEvent[]);
  assert.equal(manager.list()[0]?.state, 'disabled');
  assert.equal(manager.list()[0]?.requiresRestart, false);
});

test('升级 hash 不继承信任，篡改包保持 invalid 且不进入 active', () => {
  const { manager, emitted, dataDir } = harness();
  const oldPackage = manager.install(source('1.0.0'));
  manager.confirm(oldPackage.manifest.id, oldPackage.contentHash);
  manager.setEnabled(oldPackage.manifest.id, oldPackage.contentHash, true);
  const upgraded = manager.install(source('2.0.0'));
  assert.equal(manager.list().find((item) => item.package.contentHash === upgraded.contentHash)?.state, 'untrusted');
  manager.setEvents(emitted);
  assert.equal(manager.active().length, 1);
  writeFileSync(join(oldPackage.rootDir, 'unexpected.txt'), 'tampered');
  assert.equal(manager.list().find((item) => item.package.contentHash === oldPackage.contentHash)?.state, 'invalid');
  assert.equal(manager.active().length, 0);
  assert.ok(manager.list().find((item) => item.package.contentHash === oldPackage.contentHash)?.problems.length);
  assert.equal(upgraded.rootDir.startsWith(dataDir), true);
});

test('所有插件事件都显式为 internal', () => {
  for (const type of ['plugin/installed', 'plugin/enabled', 'plugin/disabled', 'plugin/failed']) {
    assert.equal(EVENT_VISIBILITY[type], 'internal');
  }
});

test('事件写盘失败时不提前改变本地状态', () => {
  const dir = source();
  const dataDir = tempDirSync('irmia-manager-data-');
  const installed = installPluginPackage(dir, dataDir);
  const manager = new PluginManager(dataDir, () => { throw new Error('disk full'); });
  assert.throws(() => manager.confirm(installed.manifest.id, installed.contentHash), /disk full/);
  assert.equal(manager.list()[0]?.state, 'untrusted');
});
