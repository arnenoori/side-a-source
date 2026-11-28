import { env, runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { macIDFor, quietRequest } from '../src/send';
import { LIMITS, type Install } from '../src/install';
import { TUNNEL } from '../src/tunnel';
import { FakeApns, call, newMac, paired, putDevice, register, signed, newPhone, phoneCall, type Mac, type Phone } from './helpers';

afterEach(() => vi.restoreAllMocks());

const MINUTE = 60_000;
const upgrade = { upgrade: 'websocket' };
const object = (mac: Mac) => env.INSTALLS.get(env.INSTALLS.idFromName(mac.installId));

function need<T>(value: T | null | undefined, what: string): T {
  if (value === null || value === undefined) throw new Error(`expected ${what}`);
  return value;
}

type Goodbye = { type: 'goodbye'; reason: string };
type Say = { type: 'watch' } | Goodbye;
type TunnelRow = { up: number; since: number; watch: number; goodbye: string | null; goodbye_at: number | null; alerted: number };

async function connect(mac: Mac, say: Say[] = [{ type: 'watch' }]) {
  const response = await call(await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade }));
  const ws = need(response.webSocket, 'a websocket upgrade');
  ws.accept();
  for (const message of say) ws.send(JSON.stringify(message));
  // The object takes a socket's messages in order, so the last one's effect is the proof of all of them.
  const bye = say.find((message): message is Goodbye => message.type === 'goodbye');
  await settled(mac, { up: 1, ...(say.length ? { watch: 1 } : {}), ...(bye ? { goodbye: bye.reason } : {}) });
  return ws;
}

const row = (mac: Mac) => runInDurableObject(object(mac), (_: Install, state) =>
  state.storage.sql.exec<TunnelRow>('SELECT up, since, watch, goodbye, goodbye_at, alerted FROM tunnel_mac').toArray()[0]);

const rowOf = async (mac: Mac) => need(await row(mac), 'the tunnel row');

async function until<T>(find: () => Promise<T | undefined> | T | undefined, what: string): Promise<T> {
  for (const deadline = Date.now() + 10_000; Date.now() < deadline;) {
    const found = await find();
    if (found !== undefined) return found;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error(`never saw ${what}`);
}

const settled = (mac: Mac, want: Partial<{ watch: number; up: number; goodbye: string | undefined }> = {}) =>
  until(async () => {
    const current = await row(mac);
    return current && Object.entries(want).every(([key, value]) => new Map(Object.entries(current)).get(key) === value) ? current : undefined;
  }, `the row ${JSON.stringify(want)}`);

const leave = async (mac: Mac, ws: WebSocket) => { ws.close(1000, 'bye'); await settled(mac, { up: 0 }); };
const watch = (mac: Mac, now: number) => runInDurableObject(object(mac), (instance: Install) => instance.watch(now));
const optIn = async (mac: Mac, phone: Phone) => { expect((await putDevice(mac, phone, { notifyQuiet: true })).status).toBe(200); };

async function setup(apns: FakeApns) {
  const { mac, phone } = await paired(apns);
  await optIn(mac, phone);
  return { mac, phone };
}

describe('a Mac that goes quiet', () => {
  it('is told to the phone once, after the threshold, with words the relay fixed', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    const ws = await connect(mac);
    await leave(mac, ws);
    const { since } = (await rowOf(mac));

    const early = await watch(mac, since + TUNNEL.quietAfter - 1000);
    expect(apns.to(phone.apnsToken)).toHaveLength(0);
    expect(early).toBe(since + TUNNEL.quietAfter);

    expect(await watch(mac, since + TUNNEL.quietAfter)).toBeNull();
    const push = need(apns.last(phone.apnsToken), 'a push');
    const collapse = `mac-quiet-${await macIDFor(mac.installId)}`;
    expect(push.body).toEqual({
      aps: { alert: { 'loc-key': 'PUSH_MAC_QUIET' }, category: 'MAC_QUIET', 'thread-id': collapse, sound: 'default', 'interruption-level': 'active' },
      q: await macIDFor(mac.installId),
    });
    expect(push.headers).toMatchObject({ 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-collapse-id': collapse });
    expect(push.body.aps['mutable-content']).toBeUndefined();

    await watch(mac, since + 2 * TUNNEL.quietAfter);
    await watch(mac, since + 3 * 3_600_000);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
  });

  it('is found when the socket never closed but the pings stopped', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    const ws = await connect(mac);
    const { since } = (await rowOf(mac));
    expect(await watch(mac, since + 5 * MINUTE)).toBe(since + TUNNEL.quietAfter);
    expect(apns.to(phone.apnsToken)).toHaveLength(0);
    await watch(mac, since + TUNNEL.quietAfter + MINUTE);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
    expect((await rowOf(mac)).up).toBe(0);
    ws.close();
  });

  it('is not told when the Mac said it quit, or turned Remote off', async () => {
    for (const reason of ['quit', 'off']) {
      const apns = new FakeApns();
      const { mac, phone } = await setup(apns);
      const ws = await connect(mac, [{ type: 'watch' }, { type: 'goodbye', reason }]);
      await leave(mac, ws);
      const { since, goodbye } = (await rowOf(mac));
      expect(goodbye).toBe(reason);
      expect(await watch(mac, since + 30 * 24 * 3_600_000)).toBeNull();
      expect(apns.to(phone.apnsToken)).toHaveLength(0);
    }
  });

  it('is told differently when the Mac said it was sleeping, and only after a day', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    const ws = await connect(mac, [{ type: 'watch' }, { type: 'goodbye', reason: 'sleep' }]);
    await leave(mac, ws);
    const { since, goodbye } = (await rowOf(mac));
    expect(goodbye).toBe('sleep');
    expect(await watch(mac, since + 12 * 3_600_000)).toBe(since + TUNNEL.asleepAfter);
    expect(apns.to(phone.apnsToken)).toHaveLength(0);
    await watch(mac, since + TUNNEL.asleepAfter);
    expect(need(apns.last(phone.apnsToken), 'a push').body.aps.alert).toEqual({ 'loc-key': 'PUSH_MAC_ASLEEP' });
  });

  it('does not honour a goodbye the Mac kept talking after', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    const ws = await connect(mac, [{ type: 'watch' }, { type: 'goodbye', reason: 'sleep' }]);
    await runInDurableObject(object(mac), (_: Install, state) => {
      state.storage.sql.exec('UPDATE tunnel_mac SET goodbye_at = ?', Date.now() - 3_600_000);
    });
    await leave(mac, ws);
    const { since, goodbye } = (await rowOf(mac));
    expect(goodbye).toBeNull();
    await watch(mac, since + TUNNEL.quietAfter);
    expect(need(apns.last(phone.apnsToken), 'a push').body.aps.alert).toEqual({ 'loc-key': 'PUSH_MAC_QUIET' });
  });

  it('is not told for an install that never opened a tunnel, or a Mac that never said it can be watched', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    expect(await watch(mac, Date.now() + 365 * 24 * 3_600_000)).toBeNull();
    expect(await row(mac)).toBeUndefined();

    const ws = await connect(mac, []);
    await leave(mac, ws);
    const { since } = (await rowOf(mac));
    expect(await watch(mac, since + 3_600_000)).toBeNull();
    expect(apns.to(phone.apnsToken)).toHaveLength(0);
  });

  it('is not told when the Mac is back before the threshold, and an outage after that starts afresh', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    await leave(mac, await connect(mac));
    const first = (await rowOf(mac)).since;
    const back = await connect(mac);
    expect((await rowOf(mac))).toMatchObject({ up: 1, alerted: 0, goodbye: null });
    expect(await watch(mac, Date.now() + MINUTE)).toBeGreaterThan(first);
    expect(apns.to(phone.apnsToken)).toHaveLength(0);

    await leave(mac, back);
    const second = (await rowOf(mac)).since;
    await watch(mac, second + TUNNEL.quietAfter);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
  });

  it('is cleared when the Mac returns: a silent background push naming the Mac, and none if nothing was said', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    await leave(mac, await connect(mac));
    const { since } = (await rowOf(mac));
    await watch(mac, since + TUNNEL.quietAfter);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);

    const back = await connect(mac);
    const push = await until(() => apns.to(phone.apnsToken)[1], 'the all-clear');
    expect(push.body).toEqual({ aps: { 'content-available': 1 }, back: await macIDFor(mac.installId) });
    expect(push.headers).toMatchObject({ 'apns-push-type': 'background', 'apns-priority': '5' });
    expect(push.headers['apns-collapse-id']).toBeUndefined();
    expect((await rowOf(mac)).alerted).toBe(0);

    await leave(mac, back);
    const again = await connect(mac);
    await settled(mac, { up: 1 });
    expect(apns.to(phone.apnsToken)).toHaveLength(2);
    again.close();
  });
});

describe('the quiet notice, per Mac', () => {
  it('has its own collapse id for each Mac, so two Macs never replace one another', () => {
    const one = quietRequest('quiet', 'macOne', 0);
    expect(one.collapseId).toBe('mac-quiet-macOne');
    expect(quietRequest('quiet', 'macTwo', 0).collapseId).toBe('mac-quiet-macTwo');
    expect(quietRequest('asleep', 'macOne', 0).collapseId).toBe(one.collapseId);
  });

  it('is removed by a background push with no alert, which names the Mac', () => {
    const back = quietRequest('back', 'macOne', 100);
    expect(back).toMatchObject({ pushType: 'background', priority: 5, expiration: 3700 });
    expect(back.collapseId).toBeUndefined();
    expect(JSON.parse(back.payload)).toEqual({ aps: { 'content-available': 1 }, back: 'macOne' });
  });
});

describe('who is told, and how much', () => {
  it('goes to the phones that asked, not the others', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    const quiet = newPhone(mac);
    await putDevice(mac, quiet);
    await phoneCall(quiet, 'POST', '/v1/device/verify', { challenge: need(apns.last(quiet.apnsToken), 'a push').body.verify.challenge });
    const refused = newPhone(mac);
    await putDevice(mac, refused, { notifyQuiet: false });
    await phoneCall(refused, 'POST', '/v1/device/verify', { challenge: need(apns.last(refused.apnsToken), 'a push').body.verify.challenge });
    apns.clear();

    await leave(mac, await connect(mac));
    await watch(mac, (await rowOf(mac)).since + TUNNEL.quietAfter);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
    expect(apns.to(quiet.apnsToken)).toHaveLength(0);
    expect(apns.to(refused.apnsToken)).toHaveLength(0);
  });

  it('is turned off by the phone, which the Mac says in the next registration; a Mac that says nothing changes nothing', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    await putDevice(mac, phone);
    await leave(mac, await connect(mac));
    const { since } = (await rowOf(mac));
    expect((await putDevice(mac, phone, { notifyQuiet: false })).status).toBe(200);
    await watch(mac, since + TUNNEL.quietAfter);
    expect(apns.to(phone.apnsToken)).toHaveLength(0);
  });

  it('refuses a notifyQuiet that is not a boolean', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    expect((await putDevice(mac, phone, { notifyQuiet: 'yes' })).status).toBe(400);
  });

  it('forgets a device that was removed', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    expect((await call(await signed(mac, 'DELETE', `/v1/devices/${phone.deviceId}`))).status).toBe(204);
    const ids = await runInDurableObject(object(mac), (_: Install, state) => state.storage.sql.exec('SELECT id FROM quiet_devices').toArray());
    expect(ids).toEqual([]);
  });

  it('waits out the install’s send limits and then tells', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    await leave(mac, await connect(mac));
    const { since } = (await rowOf(mac));
    const now = since + TUNNEL.quietAfter;
    await runInDurableObject(object(mac), (_: Install, state) => {
      state.storage.sql.exec('INSERT OR REPLACE INTO state VALUES (1, ?)', JSON.stringify({ nonces: {}, windows: { 'send.minute': { start: now, count: LIMITS.sendsPerMinute } } }));
    });
    const next = await watch(mac, now);
    expect(apns.to(phone.apnsToken)).toHaveLength(0);
    expect(next).toBe(now + 5 * MINUTE);
    expect((await rowOf(mac)).alerted).toBe(0);

    expect(await watch(mac, now + 5 * MINUTE)).toBeNull();
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
  });

  it('counts against the same limits as a send', async () => {
    const apns = new FakeApns();
    const { mac } = await setup(apns);
    await leave(mac, await connect(mac));
    const now = (await rowOf(mac)).since + TUNNEL.quietAfter;
    await watch(mac, now);
    const windows = await runInDurableObject(object(mac), (_: Install, state) => JSON.parse(state.storage.sql.exec<{ data: string }>('SELECT data FROM state').one().data).windows);
    expect(windows['send.minute'].count).toBe(1);
    expect(windows['send.day'].count).toBe(1);
  });

  it('is held while the relay is paused, and told when it is not', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    await leave(mac, await connect(mac));
    const now = (await rowOf(mac)).since + TUNNEL.quietAfter;
    const next = await runInDurableObject(object(mac), async (instance: Install) => {
      const held = Reflect.get(instance, 'env');
      Reflect.set(instance, 'env', { ...held, RELAY_PAUSED: '1' });
      try { return await instance.watch(now); } finally { Reflect.set(instance, 'env', held); }
    });
    expect(next).toBe(now + 5 * MINUTE);
    expect(apns.to(phone.apnsToken)).toHaveLength(0);
    await watch(mac, now + 5 * MINUTE);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
  });

  it('tries again when APNs says to', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    await leave(mac, await connect(mac));
    const now = (await rowOf(mac)).since + TUNNEL.quietAfter;
    apns.answer(phone.apnsToken, { status: 429, reason: 'TooManyRequests' });
    expect(await watch(mac, now)).toBe(now + MINUTE);
    expect((await rowOf(mac)).alerted).toBe(0);
    expect(await watch(mac, now + MINUTE)).toBeNull();
    expect(apns.to(phone.apnsToken)).toHaveLength(2);
    expect((await rowOf(mac)).alerted).toBe(1);
  });
});

describe('the alarm', () => {
  it('is set when the Mac connects, and again when it goes', async () => {
    const apns = new FakeApns();
    const { mac } = await setup(apns);
    const ws = await connect(mac);
    const alarm = () => runInDurableObject(object(mac), (_: Install, state) => state.storage.getAlarm());
    expect(await alarm()).toBeLessThanOrEqual(Date.now() + TUNNEL.quietAfter);
    await leave(mac, ws);
    expect(await alarm()).toBeLessThanOrEqual(Date.now() + TUNNEL.quietAfter);
  });

  it('sends the push when it runs, once', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await setup(apns);
    await leave(mac, await connect(mac));
    await runInDurableObject(object(mac), (_: Install, state) => {
      state.storage.sql.exec('UPDATE tunnel_mac SET since = ?', Date.now() - TUNNEL.quietAfter - MINUTE);
    });
    expect(await runDurableObjectAlarm(object(mac))).toBe(true);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
    await runDurableObjectAlarm(object(mac));
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
  });

  it('keeps an install that only sleeps from being swept: no register needed to read the row', async () => {
    const mac = await newMac();
    await register(mac);
    expect(await watch(mac, Date.now())).toBeNull();
  });
});
