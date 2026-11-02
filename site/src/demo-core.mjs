export function formatMemory(mb) {
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

export const TIGHT_MB = 10 * 1024;

export function memoryWarning(totalMB) {
  return totalMB >= TIGHT_MB ? `Sessions hold ${Math.round(totalMB / 1024)} GB · memory is tight` : null;
}

const SHORTCUTS = {
  ask: { KeyY: 'allow', KeyN: 'deny', KeyA: 'always', KeyT: 'terminal' },
  done: { KeyR: 'reply', KeyG: 'go' },
  compact: { KeyI: 'expand', KeyY: 'allow', KeyN: 'deny' },
};

export function islandShortcut(state, event) {
  if (event.key === 'Escape') return state === 'ask' || state === 'reply' ? 'collapse' : state === 'done' ? 'dismiss' : null;
  if (!event.ctrlKey || !event.altKey || event.metaKey) return null;
  return SHORTCUTS[state]?.[event.code] ?? null;
}

// Keep awake, as the app decides: a closed lid sleeps unless both options are on; otherwise the Mac
// is held up while an agent works and let go a grace period after the last one stops.
export function macSleeps({ keepAwake, lidOption, lidClosed, working, idleMs }, grace) {
  if (lidClosed && !(keepAwake && lidOption)) return true;
  if (!keepAwake) return false;
  return !working && idleMs >= grace;
}
