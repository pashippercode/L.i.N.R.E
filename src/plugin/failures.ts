export type PluginContributionKind = 'skill' | 'hook' | 'mcp';
export type PluginFailureCategory = 'start' | 'protocol' | 'crash' | 'timeout' | 'hook-error' | 'hook-timeout' | 'business' | 'bad-arguments' | 'denied' | 'overloaded' | 'cancelled';

export interface PluginFailure {
  pluginId: string;
  contentHash: string;
  contributionKind: PluginContributionKind;
  contributionName: string;
  category: PluginFailureCategory;
  message: string;
}

export function isSystemicPluginFailure(failure: PluginFailure): boolean {
  return ['start', 'protocol', 'crash', 'timeout', 'hook-error', 'hook-timeout'].includes(failure.category);
}
