import { env, evictDurableObject, runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { b64url } from '../src/bytes';
import { Install, LIMITS } from '../src/install';
import worker from '../src/index';
import { BASE, FakeApns, type Mac, alert, call, context, incoming, newMac, newPhone, paired, phoneCall, randomId, register, signed, stub } from './helpers';

afterEach(() => vi.restoreAllMocks());

const DAY = 86_400_000;

describe('rate limits', () => {
  it('allows 60 sends a minute per install, and remembers that across eviction', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    for (let i = 0; i < 60; i++) expect((await call(await signed(mac, 'POST', '/v1/send', alert(phone)))).status).toBe(200);
    await evictDurableObject(stub(mac.installId));
    const limited = await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get('retry-after'))).toBeGreaterThan(0);
  });

  it('caps sends at 2,000 a day', async () => {
    const apns = new FakeApns();
    const { mac } = await paired(apns);
    const now = Date.now();
    await runInDurableObject(stub(mac.installId), (instance: Install, state) => {
      state.storage.sql.exec('INSERT OR REPLACE INTO state VALUES (1, ?)', JSON.stringify({
        nonces: {}, windows: { 'send.day': { start: now - 1000, count: LIMITS.sendsPerDay } },
      }));
    });
    const response = await call(await signed(mac, 'POST', '/v1/send', alert({ deviceId: randomId() } as any)));
    expect(response.status).toBe(429);
    expect(Number(response.headers.get('retry-after'))).toBeGreaterThan(DAY / 1000 - 10);
  });

  it('remembers nonces across eviction', async () => {
    const mac = await newMac();
    await register(mac);
    const nonce = randomId();
    const path = `/v1/devices/${randomId()}`;
    expect((await call(await signed(mac, 'DELETE', path, undefined, { nonce }))).status).toBe(204);
    await evictDurableObject(stub(mac.installId));
    expect((await call(await signed(mac, 'DELETE', path, undefined, { nonce }))).status).toBe(401);
  });

  it('allows 30 phone requests a minute per device', async () => {
    const apns = new FakeApns();
    const { phone } = await paired(apns);
    // pairing used one (verify)
    for (let i = 0; i < 29; i++) expect((await phoneCall(phone, 'DELETE', `/v1/device/activities/${randomId()}`)).status).toBe(204);
    expect((await phoneCall(phone, 'DELETE', `/v1/device/activities/${randomId()}`)).status).toBe(429);
  });

  it('allows 10 registrations a minute from one address', async () => {
    const minute = () => Math.floor(Date.now() / 60_000);
    // The local binding's windows are on the wall clock since wrangler 4.15x, so a run across a minute starts over.
    for (let attempt = 0; attempt < 3; attempt++) {
      const ip = `2001:db8:77:${attempt}::1`;
      const started = minute();
      for (let i = 0; i < 10; i++) expect((await register(await newMac(), ip)).status).toBe(201);
      const eleventh = (await register(await newMac(), ip)).status;
      if (minute() !== started) continue;
      expect(eleventh).toBe(429);
      break;
    }
    expect((await register(await newMac())).status).toBe(201);
  });

  it('turns a flood from one network away before it wakes an install', async () => {
    const mac = await newMac();
    const phone = newPhone(mac);
    const keys: string[] = [];
    const flooded = {
      ...env,
      REQUEST_LIMIT: { limit: async ({ key }: { key: string }) => (keys.push(key), { success: false }) },
      INSTALLS: { idFromName: () => { throw new Error('woke an install'); }, get: () => { throw new Error('woke an install'); } },
    } as unknown as Env;
    const from = (request: Request, ip: string) => {
      const headers = new Headers(request.headers);
      headers.set('cf-connecting-ip', ip);
      return incoming(new Request(request, { headers }));
    };
    const requests = [
      from(await signed(mac, 'POST', '/v1/send', alert(phone)), '2001:db8:5:6::1'),
      from(await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }), '2001:db8:5:6::2'),
      from(new Request(`${BASE}/v1/device/verify`, {
        method: 'POST', body: JSON.stringify({ challenge: b64url(new Uint8Array(16)) }), headers: { authorization: phone.bearer },
      }), '2001:db8:5:6::3'),
    ];
    for (const request of requests) {
      const response = await worker.fetch(request, flooded, context);
      expect(response.status).toBe(429);
      expect(await response.json()).toEqual({ error: { code: 'rate_limited', message: 'Too many requests from this network', retryable: true } });
      expect(Number(response.headers.get('retry-after'))).toBeGreaterThan(0);
    }
    // One /64 is one network.
    expect(new Set(keys).size).toBe(1);
    expect((await worker.fetch(incoming(new Request(`${BASE}/v1/health`)), flooded, context)).status).toBe(200);
  });

  it('answers 503 not_configured, not 500, everywhere a network is keyed while RATE_KEY is unset', async () => {
    const unset = { ...env, RATE_KEY: '' } as unknown as Env;
    const mac = await newMac();
    const ip = { 'cf-connecting-ip': '198.51.100.30' };
    const requests = [
      await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }, { headers: ip }),
      await signed(mac, 'POST', '/v1/send', alert(newPhone(mac)), { headers: ip }),
      await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: { ...ip, upgrade: 'websocket' } }),
    ];
    for (const request of requests) {
      const response = await worker.fetch(incoming(request), unset, context);
      expect(response.status).toBe(503);
      expect(((await response.json()) as any).error.code).toBe('not_configured');
    }
    expect((await worker.fetch(incoming(new Request(`${BASE}/v1/health`)), unset, context)).status).toBe(200);
  });

  it('cools an address down for the day after 50 registrations', async () => {
    const open = { ...env, REGISTER_LIMIT: { limit: async () => ({ success: true }) } } as unknown as Env;
    const registerOnce = async () => {
      const mac = await newMac();
      const request = await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }, { headers: { 'cf-connecting-ip': '198.51.100.9' } });
      return worker.fetch(incoming(request), open, context);
    };
    for (let i = 0; i < 50; i++) expect((await registerOnce()).status).toBe(201);
    const cooled = await registerOnce();
    expect(cooled.status).toBe(429);
    expect(Number(cooled.headers.get('retry-after'))).toBeGreaterThan(0);
  });

  it('counts an IPv6 network once, and only installs that really registered', async () => {
    const open = { ...env, REGISTER_LIMIT: { limit: async () => ({ success: true }) } } as unknown as Env;
    const attempt = async (mac: Mac, host: number, options = {}) => worker.fetch(incoming(
      await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }, { headers: { 'cf-connecting-ip': `2001:db8:77:88::${host}` }, ...options })), open, context);
    const stranger = await newMac();
    for (let i = 0; i < 60; i++) expect((await attempt(await newMac(), i, { key: stranger.privateKey })).status).toBe(401);
    for (let i = 0; i < 50; i++) expect((await attempt(await newMac(), i + 1)).status).toBe(201);
    expect((await attempt(await newMac(), 999)).status).toBe(429);
  });
});

describe('cleanup alarm', () => {
  it('drops activities older than 12 hours', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await phoneCall(phone, 'PUT', '/v1/device/activities/old', { updateToken: 'cd'.repeat(32) });
    await phoneCall(phone, 'PUT', '/v1/device/activities/new', { updateToken: 'ef'.repeat(32) });
    const object = stub(mac.installId);
    await runInDurableObject(object, (_: Install, state) => {
      state.storage.sql.exec("UPDATE activities SET created = ? WHERE id = 'old'", Date.now() - 13 * 3_600_000);
    });
    expect(await runDurableObjectAlarm(object)).toBe(true);
    const ids = await runInDurableObject(object, (_: Install, state) => state.storage.sql.exec('SELECT id FROM activities').toArray().map(row => row.id));
    expect(ids).toEqual(['new']);
  });

  it('deletes an install with no successful send for 90 days', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
    const object = stub(mac.installId);
    const lastSend = await runInDurableObject(object, (_: Install, state) => state.storage.sql.exec('SELECT last_send FROM install').one().last_send);
    expect(lastSend).toBeGreaterThan(Date.now() - 5000);
    await runInDurableObject(object, (_: Install, state) => {
      state.storage.sql.exec('UPDATE install SET last_send = ?', Date.now() - 91 * DAY);
    });
    await runDurableObjectAlarm(object);
    expect((await call(await signed(mac, 'DELETE', '/v1/installs'))).status).toBe(401);
  });

  it('deletes an install with no device for 30 days', async () => {
    const mac = await newMac();
    await register(mac);
    const object = stub(mac.installId);
    await runDurableObjectAlarm(object);
    const emptySince = await runInDurableObject(object, (_: Install, state) => state.storage.sql.exec('SELECT empty_since FROM install').one().empty_since);
    expect(emptySince).toBeGreaterThan(0);
    await runInDurableObject(object, (_: Install, state) => {
      state.storage.sql.exec('UPDATE install SET empty_since = ?', Date.now() - 31 * DAY);
    });
    await runDurableObjectAlarm(object);
    expect((await register(mac)).status).toBe(201);
  });

  it('keeps an install that is in use', async () => {
    const apns = new FakeApns();
    const { mac } = await paired(apns);
    const object = stub(mac.installId);
    await runDurableObjectAlarm(object);
    expect(await runInDurableObject(object, (_: Install, state) => state.storage.getAlarm())).toBeGreaterThan(Date.now());
    expect((await register(mac)).status).toBe(200);
  });
});
