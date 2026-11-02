import { runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Install, LIMITS } from '../src/install';
import { FakeApns, alert, call, hexToken, newMac, newPhone, paired, phoneCall, putDevice, randomId, register, signed, stub } from './helpers';

afterEach(() => vi.restoreAllMocks());

describe('a challenge proves one token', () => {
  it("doesn't let token A's challenge verify the token that replaced it", async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    await putDevice(mac, phone);
    const first = apns.last(phone.apnsToken)!.body.verify.challenge;

    // Within the minute between challenges, the phone swaps in token B.
    const replacement = hexToken();
    expect(await (await phoneCall(phone, 'PUT', '/v1/device/tokens', { apnsToken: replacement })).json()).toEqual({ verified: false });
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: first })).status).toBe(403);
    expect((await (await call(await signed(mac, 'POST', '/v1/send', alert(phone)))).json() as any).results[0].result).toBe('unverified');

    // B got its own challenge straight away, and that one works.
    const second = apns.last(replacement)!.body.verify.challenge;
    expect(second).not.toBe(first);
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: second })).status).toBe(204);
  });

  it("doesn't carry a challenge across a change of app or host", async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    await putDevice(mac, phone);
    const first = apns.last(phone.apnsToken)!.body.verify.challenge;
    await phoneCall(phone, 'PUT', '/v1/device/tokens', { apnsToken: phone.apnsToken, apnsEnvironment: 'sandbox' });
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: first })).status).toBe(403);
  });

  it("refuses a proof whose challenge went to another route, even if one wasn't cleared", async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    await putDevice(mac, phone);
    const challenge = apns.last(phone.apnsToken)!.body.verify.challenge;
    await runInDurableObject(stub(mac.installId), (_: Install, state) => {
      state.storage.sql.exec('UPDATE devices SET apns_token = ?', hexToken());
    });
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge })).status).toBe(403);
  });
});

describe('replay protection under concurrency', () => {
  it('accepts one of many copies of a signed request that arrive together', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const nonce = randomId();
    const ts = Math.floor(Date.now() / 1000);
    const body = alert(phone);
    const requests = await Promise.all(Array.from({ length: 10 }, () => signed(mac, 'POST', '/v1/send', body, { nonce, ts })));
    const statuses = (await Promise.all(requests.map(call))).map(response => response.status);
    expect(statuses.filter(status => status === 200)).toHaveLength(1);
    expect(statuses.filter(status => status === 401)).toHaveLength(9);
    expect(apns.to(phone.apnsToken)).toHaveLength(1);
  });

  it('counts every one of many concurrent sends against the minute', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const requests = await Promise.all(Array.from({ length: LIMITS.sendsPerMinute + 5 }, () => signed(mac, 'POST', '/v1/send', alert(phone))));
    const statuses = (await Promise.all(requests.map(call))).map(response => response.status);
    expect(statuses.filter(status => status === 200)).toHaveLength(LIMITS.sendsPerMinute);
    expect(statuses.filter(status => status === 429)).toHaveLength(5);
  });
});

describe('the nonce table', () => {
  const fill = (installId: string, seen: number) => runInDurableObject(stub(installId), (_: Install, state) => {
    const nonces = Object.fromEntries(Array.from({ length: LIMITS.nonces }, (_, i) => [`n${i}`, seen]));
    state.storage.sql.exec('INSERT OR REPLACE INTO state VALUES (1, ?)', JSON.stringify({ nonces, windows: {} }));
  });

  it('empties itself once its entries expire', async () => {
    const mac = await newMac();
    await register(mac);
    await fill(mac.installId, Date.now() - 10 * 60_000);
    expect((await call(await signed(mac, 'GET', '/v1/installs/self'))).status).toBe(200);
  });

  it('still refuses requests while it is full of live nonces', async () => {
    const mac = await newMac();
    await register(mac);
    await fill(mac.installId, Date.now());
    expect((await call(await signed(mac, 'GET', '/v1/installs/self'))).status).toBe(429);
  });
});
