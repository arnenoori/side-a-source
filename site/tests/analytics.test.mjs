import test from 'node:test';
import assert from 'node:assert/strict';
import { createAnalytics } from '../src/analytics-core.mjs';

function fixture(overrides = {}) {
  const requests = [], values = new Map();
  let sequence = 0;
  const dependencies = {
    projectToken: 'phc_public', host: 'https://us.i.posthog.com',
    location: { hostname: 'getsidea.com', protocol: 'https:', search: '?email=private@example.com', hash: '#secret' },
    navigator: {}, randomUUID: () => `visit-${++sequence}`,
    storage: { getItem: k => values.get(k), setItem: (k, v) => values.set(k, v), removeItem: k => values.delete(k) },
    fetch: (...args) => { requests.push(args); return Promise.resolve({ ok: true }); }, ...overrides,
  };
  return { analytics: createAnalytics(dependencies), requests, values, dependencies };
}

test('captures an ephemeral visit without identity, URL secrets, or arbitrary properties', () => {
  const { analytics, requests, values } = fixture();
  analytics.capture('$pageview', { email: 'private@example.com', $current_url: 'secret', $process_person_profile: true });
  analytics.capture('download_clicked', { version: '0.3.1', email: 'secret' });
  const [url, options] = requests[0];
  const first = JSON.parse(options.body), second = JSON.parse(requests[1][1].body);
  assert.equal(url, 'https://us.i.posthog.com/i/v0/e/');
  assert.equal(first.distinct_id, second.distinct_id);
  assert.equal(first.properties.$process_person_profile, false);
  assert.equal(first.properties.$geoip_disable, true);
  assert.equal(first.properties.$current_url, 'https://getsidea.com/');
  assert.equal(second.properties.version, '0.3.1');
  assert.equal(options.referrerPolicy, 'no-referrer');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.keepalive, true);
  assert.doesNotMatch(JSON.stringify(requests), /private@example|secret|email/);
  assert.equal(values.size, 0);
});

test('privacy signals, opt-out, and nonproduction sites send nothing', () => {
  for (const overrides of [
    { navigator: { doNotTrack: '1' } }, { navigator: { globalPrivacyControl: true } },
    { location: { hostname: 'localhost', protocol: 'https:' } },
    { location: { hostname: 'side-a-preview.vercel.app', protocol: 'https:' } },
    { location: { hostname: 'getsidea.com', protocol: 'http:' } },
    { storage: { getItem: () => '1' } },
    { storage: { getItem: () => { throw Error('Blocked'); } } },
  ]) {
    const { analytics, requests } = fixture(overrides);
    analytics.capture('$pageview');
    assert.equal(requests.length, 0);
  }
});

test('opt-out persists only the preference and resets the visit identity', () => {
  const { analytics, requests, values, dependencies } = fixture();
  analytics.capture('$pageview');
  analytics.setDisabled(true);
  analytics.capture('setup_opened');
  createAnalytics(dependencies).capture('$pageview');
  assert.equal(requests.length, 1);
  assert.deepEqual([...values], [['side-a-analytics-disabled', '1']]);
  analytics.setDisabled(false);
  analytics.capture('setup_opened');
  assert.notEqual(JSON.parse(requests[0][1].body).distinct_id, JSON.parse(requests[1][1].body).distinct_id);
  assert.equal(values.size, 0);
});

test('only defined events, valid releases, and physical demo actions are accepted', () => {
  const { analytics, requests } = fixture();
  analytics.capture('account_added', { email: 'secret' });
  analytics.capture('demo_interacted', { action: 'secret account' });
  analytics.capture('download_clicked', { version: 'https://secret' });
  analytics.capture('download_clicked');
  assert.equal(requests.length, 0);
  analytics.capture('demo_interacted', { action: 'open', account: 'secret' });
  assert.equal(requests.length, 1);
  assert.equal(JSON.parse(requests[0][1].body).properties.action, 'open');
});

test('blocked networking never throws or holds up the interface', async () => {
  for (const fetch of [() => { throw Error('Blocked'); }, () => Promise.reject(Error('Offline'))]) {
    const { analytics } = fixture({ fetch });
    assert.doesNotThrow(() => analytics.capture('$pageview'));
    await new Promise(resolve => setImmediate(resolve));
  }
});

test('every deployed CSP permits capture without widening other connections', async () => {
  const { readFile } = await import('node:fs/promises');
  const index = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  const headers = await readFile(new URL('../public/_headers', import.meta.url), 'utf8');
  const vercel = JSON.parse(await readFile(new URL('../../vercel.json', import.meta.url), 'utf8'));
  const policies = [
    index.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)[1],
    headers.match(/Content-Security-Policy: (.+)/)[1],
    vercel.headers.flatMap(rule => rule.headers).find(header => header.key === 'Content-Security-Policy').value,
  ];
  for (const policy of policies) {
    assert.equal(policy.match(/connect-src ([^;]+)/)[1], "'self' https://api.github.com https://us.i.posthog.com");
  }
});
