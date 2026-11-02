import { env, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { b64url, sha256 } from '../src/bytes';
import { network } from '../src/index';
import { type Install } from '../src/install';
import { CLAIM_LIFETIME, Ledger } from '../src/ledger';
import { FakeApns, alert, call, hexToken, newMac, newPhone, paired, phoneCall, putDevice, register, signed, stub } from './helpers';

afterEach(() => vi.restoreAllMocks());

const content = { working: 1, waiting: 0 };
const start = (phone: { deviceId: string }) => ({ devices: [phone.deviceId], kind: 'liveactivity', event: 'start', contentState: content, priority: 5, expiresIn: 0 });
const update = (phone: { deviceId: string }, activityId: string) => ({ ...start(phone), event: 'update', activityId, priority: 5 });

async function sent(mac: Parameters<typeof signed>[0], body: unknown) {
  const response = await call(await signed(mac, 'POST', '/v1/send', body));
  expect(response.status).toBe(200);
  return ((await response.json()) as any).results[0];
}

describe('whose Live Activity token it is', () => {
  it('refuses a push-to-start token a proven device of its own never held', async () => {
    const apns = new FakeApns();
    const { mac: owner, phone: victim } = await paired(apns);
    expect((await sent(owner, start(victim))).result).toBe('ok');
    apns.clear();

    const { mac: fake, phone: attacker } = await paired(apns, undefined, {});
    await putDevice(fake, attacker, { pushToStartToken: victim.pushToStartToken });
    expect(await sent(fake, start(attacker))).toMatchObject({ result: 'rejected', reason: 'TokenHeldByAnotherDevice' });
    expect(apns.to(victim.pushToStartToken)).toEqual([]);

    await phoneCall(attacker, 'PUT', '/v1/device/tokens', { pushToStartToken: victim.pushToStartToken });
    expect((await sent(fake, start(attacker))).result).toBe('rejected');
    expect(apns.to(victim.pushToStartToken)).toEqual([]);
  });

  it('refuses an update token the same way', async () => {
    const apns = new FakeApns();
    const { mac: owner, phone: victim } = await paired(apns);
    const updateToken = hexToken();
    expect((await phoneCall(victim, 'PUT', '/v1/device/activities/a1', { updateToken })).status).toBe(204);
    expect((await sent(owner, update(victim, 'a1'))).result).toBe('ok');
    apns.clear();

    const { mac: fake, phone: attacker } = await paired(apns);
    expect((await phoneCall(attacker, 'PUT', '/v1/device/activities/a2', { updateToken })).status).toBe(204);
    expect((await sent(fake, update(attacker, 'a2'))).result).toBe('rejected');
    expect(apns.to(updateToken)).toEqual([]);
  });

  it('holds after the rightful phone forgets the Mac', async () => {
    const apns = new FakeApns();
    const { mac: exPaired, phone } = await paired(apns);
    expect((await sent(exPaired, start(phone))).result).toBe('ok');
    expect((await phoneCall(phone, 'DELETE', '/v1/device')).status).toBe(204);
    apns.clear();

    // The Mac kept the phone's tokens and registers them again: the challenge reaches a phone that ignores it.
    await putDevice(exPaired, phone);
    expect((await sent(exPaired, start(phone))).result).toBe('unverified');

    // With a phone of its own it proves that one, and still can't reach the old phone's Lock Screen.
    const own = newPhone(exPaired);
    await putDevice(exPaired, own, { pushToStartToken: phone.pushToStartToken });
    await phoneCall(own, 'POST', '/v1/device/verify', { challenge: apns.last(own.apnsToken)!.body.verify.challenge });
    expect((await sent(exPaired, start(own))).result).toBe('rejected');
    expect(apns.to(phone.pushToStartToken)).toEqual([]);
  });

  it('lets one phone paired with two Macs use its token from both', async () => {
    const apns = new FakeApns();
    const { mac: first, phone } = await paired(apns);
    const second = await newMac();
    await register(second);
    const again = { ...newPhone(second), apnsToken: phone.apnsToken, pushToStartToken: phone.pushToStartToken };
    await putDevice(second, again);
    await phoneCall(again, 'POST', '/v1/device/verify', { challenge: apns.last(phone.apnsToken)!.body.verify.challenge });
    expect((await sent(first, start(phone))).result).toBe('ok');
    expect((await sent(second, start(again))).result).toBe('ok');
  });

  it('lapses when unused, so a phone with a new device token gets back in', async () => {
    const ledger = env.LEDGER.get(env.LEDGER.idFromName(`token:${crypto.randomUUID()}`));
    const now = Date.now();
    expect(await ledger.claim('old', now)).toBe(true);
    expect(await ledger.claim('new', now + CLAIM_LIFETIME)).toBe(false);
    expect(await ledger.claim('new', now + CLAIM_LIFETIME + 1)).toBe(true);
    expect(await ledger.claim('old', now + CLAIM_LIFETIME + 2)).toBe(false);
  });

  it('keeps nothing once it lapses', async () => {
    const ledger = env.LEDGER.get(env.LEDGER.idFromName(`token:${crypto.randomUUID()}`));
    await ledger.claim('owner', Date.now());
    await runInDurableObject(ledger, async (instance: Ledger, state) => {
      await instance.alarm();
      expect((await state.storage.list()).size).toBe(0);
    });
  });
});

describe('tokens follow the proof', () => {
  const activities = (installId: string) => runInDurableObject(stub(installId), (_: Install, state) =>
    state.storage.sql.exec('SELECT id FROM activities').toArray().length);

  it('takes no update token from a device that has not proved its own', async () => {
    new FakeApns();
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    await putDevice(mac, phone);
    const refused = await phoneCall(phone, 'PUT', '/v1/device/activities/a1', { updateToken: hexToken() });
    expect(refused.status).toBe(403);
    expect((await refused.json() as any).error.code).toBe('unverified');
  });

  it('drops activities and push-to-start when the phone brings a new device token', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await phoneCall(phone, 'PUT', '/v1/device/activities/a1', { updateToken: hexToken() });
    await phoneCall(phone, 'PUT', '/v1/device/tokens', { apnsToken: hexToken() });
    expect(await activities(mac.installId)).toBe(0);
    const state = await runInDurableObject(stub(mac.installId), (_: Install, ctx) =>
      ctx.storage.sql.exec('SELECT push_to_start FROM devices').one());
    expect(state.push_to_start).toBeNull();
  });

  it('drops activities when the Mac moves the device to a new token or a new secret', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await phoneCall(phone, 'PUT', '/v1/device/activities/a1', { updateToken: hexToken() });
    await putDevice(mac, phone);
    expect(await activities(mac.installId)).toBe(1);
    await putDevice(mac, phone, { secretHash: b64url(await sha256(crypto.getRandomValues(new Uint8Array(32)))) });
    expect(await activities(mac.installId)).toBe(0);
  });

  it('forgets the device entirely when the phone forgets the Mac', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await phoneCall(phone, 'PUT', '/v1/device/activities/a1', { updateToken: hexToken() });
    await runInDurableObject(stub(mac.installId), (_: Install, state) => {
      state.storage.sql.exec('CREATE TABLE IF NOT EXISTS tunnel_devices(id TEXT PRIMARY KEY, secret_hash BLOB)');
      state.storage.sql.exec('INSERT INTO tunnel_devices VALUES (?, zeroblob(32))', phone.deviceId);
    });
    expect((await phoneCall(phone, 'DELETE', '/v1/device')).status).toBe(204);
    const left = await runInDurableObject(stub(mac.installId), (_: Install, state) => ({
      devices: state.storage.sql.exec('SELECT 1 FROM devices').toArray().length,
      activities: state.storage.sql.exec('SELECT 1 FROM activities').toArray().length,
      tunnel: state.storage.sql.exec('SELECT 1 FROM tunnel_devices').toArray().length,
    }));
    expect(left).toEqual({ devices: 0, activities: 0, tunnel: 0 });
  });

  it('leaves ordinary alerts alone', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    expect((await sent(mac, alert(phone))).result).toBe('ok');
    expect(apns.last(phone.apnsToken)).toBeTruthy();
  });
});

describe('what counts as one network', () => {
  it('is an IPv4 address, or an IPv6 /64', () => {
    expect(network('198.51.100.9')).toBe('198.51.100.9');
    expect(network('2001:db8:1:2:3:4:5:6')).toBe(network('2001:db8:1:2::9'));
    expect(network('2001:DB8:0001:0002::')).toBe('2001:db8:1:2');
    expect(network('2001:db8:1:3::1')).not.toBe(network('2001:db8:1:2::1'));
    expect(network('::1')).toBe('0:0:0:0');
  });
});
