import { afterEach, describe, expect, it, vi } from 'vitest';
import { parseDeviceBearer, parseSignature } from '../src/auth';
import { b64url, sha256 } from '../src/bytes';
import { BASE, FakeApns, alert, call, hexToken, newMac, newPhone, paired, phoneCall, putDevice, randomId, register, signed } from './helpers';

afterEach(() => vi.restoreAllMocks());

describe('signature header', () => {
  const sig = b64url(new Uint8Array(64));
  const id = randomId();
  it('parses the documented form', () => {
    expect(parseSignature(`SideA-Sig v=1, install=${id}, ts=1792200000, nonce=${id}, sig=${sig}`)).toMatchObject({ install: id, ts: 1792200000, nonce: id });
  });
  it('rejects malformed signature headers', () => {
    for (const [what, header] of [
    ['no scheme', `v=1, install=${id}, ts=1, nonce=${id}, sig=${sig}`],
    ['wrong version', `SideA-Sig v=2, install=${id}, ts=1, nonce=${id}, sig=${sig}`],
    ['duplicate field', `SideA-Sig v=1, install=${id}, install=${id}, ts=1, nonce=${id}, sig=${sig}`],
    ['short signature', `SideA-Sig v=1, install=${id}, ts=1, nonce=${id}, sig=${sig.slice(0, 40)}`],
    ['bad install id', `SideA-Sig v=1, install=abc, ts=1, nonce=${id}, sig=${sig}`],
    ['non-numeric ts', `SideA-Sig v=1, install=${id}, ts=1e9, nonce=${id}, sig=${sig}`],
    ]) expect(parseSignature(header), what).toBeNull();
  });

  it('hashes the device secret and refuses malformed bearers', async () => {
    const secret = new Uint8Array(32).fill(7);
    const credential = await parseDeviceBearer(`Bearer d1.${id}.${id}.${b64url(secret)}`);
    expect(credential?.secretHash).toEqual(await sha256(secret));
    expect(await parseDeviceBearer(`Bearer d2.${id}.${id}.${b64url(secret)}`)).toBeNull();
    expect(await parseDeviceBearer(`Bearer d1.${id}.${id}.${b64url(secret.slice(0, 31))}`)).toBeNull();
  });
});

describe('installs', () => {
  it('serves health with no body', async () => {
    const response = await call(new Request(`${BASE}/v1/health`));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('');
  });

  it('registers once, and again idempotently with the same key', async () => {
    const mac = await newMac();
    const first = await register(mac);
    expect(first.status).toBe(201);
    expect(await first.json()).toEqual({ installId: mac.installId });
    expect((await register(mac)).status).toBe(200);
  });

  it('refuses an install id not derived from the key', async () => {
    const mac = await newMac();
    const other = await newMac();
    const response = await call(await signed({ ...mac, installId: other.installId }, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }));
    expect(response.status).toBe(400);
  });

  it('refuses a registration signed by another key', async () => {
    const mac = await newMac();
    const other = await newMac();
    const response = await call(await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }, { key: other.privateKey }));
    expect(response.status).toBe(401);
  });

  it('refuses unknown installs, tampered bodies and replays', async () => {
    const mac = await newMac();
    expect((await call(await signed(mac, 'DELETE', '/v1/installs'))).status).toBe(401);
    await register(mac);

    const request = await signed(mac, 'POST', '/v1/installs/rotate', { newPublicKey: b64url((await newMac()).publicKey) });
    const tampered = new Request(request, { body: JSON.stringify({ newPublicKey: b64url(new Uint8Array(32)) }) });
    expect((await call(tampered)).status).toBe(401);

    const nonce = randomId();
    const phone = newPhone(mac);
    expect((await call(await signed(mac, 'DELETE', `/v1/devices/${phone.deviceId}`, undefined, { nonce }))).status).toBe(204);
    const replay = await call(await signed(mac, 'DELETE', `/v1/devices/${phone.deviceId}`, undefined, { nonce }));
    expect(replay.status).toBe(401);
    expect((await replay.json() as any).error.code).toBe('replay');
  });

  it('refuses a clock more than 120 seconds off and says the time', async () => {
    const mac = await newMac();
    await register(mac);
    const response = await call(await signed(mac, 'DELETE', '/v1/installs', undefined, { ts: Math.floor(Date.now() / 1000) - 121 }));
    expect(response.status).toBe(401);
    expect((await response.json() as any).error.code).toBe('clock_skew');
    expect(Date.parse(response.headers.get('date')!)).toBeGreaterThan(Date.now() - 5000);
    expect((await call(await signed(mac, 'DELETE', '/v1/installs', undefined, { ts: Math.floor(Date.now() / 1000) - 100 }))).status).toBe(204);
  });

  it('rotates the key: the old one stops at once, the id stays', async () => {
    const mac = await newMac();
    await register(mac);
    const next = await newMac();
    const rotated = await call(await signed(mac, 'POST', '/v1/installs/rotate', { newPublicKey: b64url(next.publicKey) }));
    expect(await rotated.json()).toEqual({ installId: mac.installId });
    const moved = { ...next, installId: mac.installId };
    expect((await call(await signed(mac, 'DELETE', `/v1/devices/${randomId()}`))).status).toBe(401);
    expect((await register(mac)).status).toBe(409);
    expect((await call(await signed(moved, 'DELETE', `/v1/devices/${randomId()}`))).status).toBe(204);
  });

  it('deletes the install and everything in it', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    expect((await call(await signed(mac, 'DELETE', '/v1/installs'))).status).toBe(204);
    expect((await call(await signed(mac, 'POST', '/v1/send', {}))).status).toBe(400);
    expect((await phoneCall(phone, 'DELETE', '/v1/device')).status).toBe(401);
    expect((await register(mac)).status).toBe(201);
  });

  it('caps bodies at 8 KB', async () => {
    const mac = await newMac();
    await register(mac);
    const response = await call(await signed(mac, 'POST', '/v1/send', undefined, { raw: JSON.stringify({ pad: 'x'.repeat(8200) }) }));
    expect(response.status).toBe(413);
  });
});

describe('devices', () => {
  it('holds sends until the phone proves it has the token', async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    const put = await putDevice(mac, phone);
    expect(put.status).toBe(201);
    expect(await put.json()).toEqual({ verified: false });

    const challenge = apns.last(phone.apnsToken)!;
    expect(challenge.headers['apns-push-type']).toBe('background');
    expect(challenge.headers['apns-priority']).toBe('5');
    expect(challenge.body).toEqual({ aps: { 'content-available': 1 }, verify: { install: mac.installId, device: phone.deviceId, challenge: expect.any(String) } });

    const before = await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
    expect(await before.json()).toEqual({ results: [{ device: phone.deviceId, result: 'unverified' }] });

    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: b64url(new Uint8Array(16)) })).status).toBe(403);
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: challenge.body.verify.challenge })).status).toBe(204);
    const after = await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
    expect(await after.json()).toMatchObject({ results: [{ device: phone.deviceId, result: 'ok' }] });
  });

  it("can't be claimed by someone who only knows the token", async () => {
    const apns = new FakeApns();
    const { phone: victim } = await paired(apns);
    const thief = await newMac();
    await register(thief);
    const stolen = { ...newPhone(thief), apnsToken: victim.apnsToken };
    await putDevice(thief, stolen);
    // The challenge reaches the victim's phone, which doesn't know this install and drops it.
    const response = await call(await signed(thief, 'POST', '/v1/send', alert(stolen)));
    expect(await response.json()).toEqual({ results: [{ device: stolen.deviceId, result: 'unverified' }] });
  });

  it('stays verified when the Mac re-registers the same token', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const same = await putDevice(mac, phone, { appVersion: '1.1' });
    expect(await same.json()).toEqual({ verified: true });
  });

  it('caps an install at 10 devices', async () => {
    const mac = await newMac();
    await register(mac);
    new FakeApns();
    for (let i = 0; i < 10; i++) expect((await putDevice(mac, newPhone(mac))).status).toBe(201);
    const response = await putDevice(mac, newPhone(mac));
    expect(response.status).toBe(409);
    expect((await response.json() as any).error.code).toBe('too_many_devices');
  });

  it('answers registrations by their fields', async () => {
    const rows: [string, Record<string, unknown>, number][] = [
    ['a token that is not hex', { apnsToken: 'not hex' }, 400],
    ['an unknown environment', { environment: 'staging' }, 400],
    ['an unknown apnsEnvironment', { apnsEnvironment: 'staging' }, 400],
    ['a short secret hash', { secretHash: 'abc' }, 400],
    ['a bundle id not on the allowlist', { bundleID: 'com.example.other' }, 400],
    ['a bundle id that is not a string', { bundleID: 42 }, 400],
    ['the development environment', { environment: 'development' }, 201],
    ['the dev build bundle id', { bundleID: 'com.arnenoori.sidea.remote.dev' }, 201],
    ];
    for (const [what, fields, status] of rows) {
      new FakeApns();
      const mac = await newMac();
      await register(mac);
      const response = await putDevice(mac, newPhone(mac), fields);
      expect(response.status, what).toBe(status);
      if (status === 400) expect((await response.json() as any).error.code, what).toBe('bad_request');
    }
  });

  it('refuses phones with the wrong secret', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const impostor = { ...newPhone(mac), deviceId: phone.deviceId };
    impostor.bearer = `Bearer d1.${mac.installId}.${phone.deviceId}.${b64url(new Uint8Array(32))}`;
    expect((await phoneCall(impostor, 'DELETE', '/v1/device')).status).toBe(401);
    expect((await phoneCall(phone, 'DELETE', '/v1/device')).status).toBe(204);
    const response = await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
    expect(await response.json()).toEqual({ results: [{ device: phone.deviceId, result: 'gone' }] });
  });
});
