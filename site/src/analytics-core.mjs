// Deliberately small: public capture API only, no SDK, autocapture, or recordings.
const actions = new Set(['open', 'next', 'previous', 'play', 'stop', 'mode', 'hold']);
const events = new Set(['$pageview', 'download_clicked', 'release_list_opened', 'setup_opened', 'demo_interacted', 'demo_load_failed', 'release_lookup_failed']);
const optOutKey = 'side-a-analytics-disabled';

/** Dependencies are injectable so privacy and failure behavior can be tested without sending events. */
export function createAnalytics({ projectToken, host, location, navigator, storage, randomUUID, fetch }) {
  let visitID;
  let disabled = false;
  try { disabled = storage?.getItem(optOutKey) === '1'; } catch { disabled = true; }
  const privacySignal = () => navigator.doNotTrack === '1' || navigator.globalPrivacyControl === true;
  const isEnabled = () => !disabled && !privacySignal() && location.hostname === 'getsidea.com' && location.protocol === 'https:';

  function capture(event, properties = {}) {
    if (!isEnabled() || !events.has(event)) return;
    const allowed = {};
    if (event === 'demo_interacted') {
      if (!actions.has(properties.action)) return;
      allowed.action = properties.action;
    }
    if (event === 'download_clicked') {
      if (typeof properties.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(properties.version)) return;
      allowed.version = properties.version;
      allowed.format = 'dmg';
      allowed.source = 'hero';
    }
    try {
      visitID ??= randomUUID(); // Memory only: reloads are new visits, never returning-user identities.
      void Promise.resolve(fetch(`${host}/i/v0/e/`, {
        method: 'POST', credentials: 'omit', keepalive: true, referrerPolicy: 'no-referrer',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          api_key: projectToken, distinct_id: visitID, event,
          properties: {
            ...allowed, surface: 'landing', schema_version: 1,
            $current_url: 'https://getsidea.com/', $pathname: '/', $host: 'getsidea.com',
            $process_person_profile: false, $is_identified: false, $geoip_disable: true,
          },
        }),
      })).catch(() => {}); // Analytics must never delay downloads or break the model.
    } catch { /* Unavailable browser APIs or blocked requests are harmless. */ }
  }
  function setDisabled(value) {
    disabled = Boolean(value);
    visitID = undefined;
    try { if (disabled) storage?.setItem(optOutKey, '1'); else storage?.removeItem(optOutKey); } catch { /* Keep the in-memory preference. */ }
  }
  return { capture, isEnabled, setDisabled, privacySignal };
}
