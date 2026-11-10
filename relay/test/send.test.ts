import { env, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { fromB64url, utf8 } from '../src/bytes';
import worker from '../src/index';
import { LIMITS, type Install } from '../src/install';
import { FakeApns, alert, call, context, incoming, hexToken, newPhone, paired, phoneCall, putDevice, randomId, sealed, signed, stub, type Mac, type Phone } from './helpers';

afterEach(() => vi.restoreAllMocks());

const send = async (mac: Mac, body: unknown) => call(await signed(mac, 'POST', '/v1/send', body));

describe('alerts', () => {
  it('builds the APNs request itself, with fixed text and the device’s own envelope', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const body = alert(phone);
    const before = Math.floor(Date.now() / 1000);
    const response = await send(mac, body);
    expect(await response.json()).toEqual({ results: [{ device: phone.deviceId, result: 'ok', apnsId: expect.any(String) }] });

    const push = apns.last(phone.apnsToken)!;
    expect(push.host).toBe('api.push.apple.com');
    expect(push.body).toEqual({
      aps: {
        alert: { 'loc-key': 'PUSH_REQUEST_FALLBACK' }, 'mutable-content': 1, category: 'REQUEST', sound: 'default',
        'interruption-level': 'time-sensitive',
      },
      e: body.sealed[phone.deviceId],
    });
    expect(push.headers).toMatchObject({
      'apns-push-type': 'alert', 'apns-topic': 'com.arnenoori.sidea.remote', 'apns-priority': '10', 'apns-collapse-id': body.collapseId,
    });
    expect(Number(push.headers['apns-expiration'])).toBeGreaterThanOrEqual(before + 3600);
  });

  it('signs a provider token Apple accepts', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await send(mac, alert(phone));
    const [header, claims, signature] = apns.last(phone.apnsToken)!.headers.authorization.replace(/^bearer /, '').split('.');
    expect(JSON.parse(new TextDecoder().decode(fromB64url(header)!))).toEqual({ alg: 'ES256', kid: 'TESTKEY123' });
    const { iss, iat } = JSON.parse(new TextDecoder().decode(fromB64url(claims)!));
    expect(iss).toBe('NV46KL65S9');
    expect(iat % 2400).toBe(0);
    expect(Date.now() / 1000 - iat).toBeLessThan(2400);
    const key = await crypto.subtle.importKey('jwk', JSON.parse(env.TEST_APNS_PUBLIC_JWK), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    expect(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, fromB64url(signature)!, utf8(`${header}.${claims}`))).toBe(true);
  });

  it('maps each category to its fallback and leaves out sound when asked', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    for (const [category, key] of [['QUESTION', 'PUSH_QUESTION_FALLBACK'], ['PLAN', 'PUSH_PLAN_FALLBACK'], ['FINISHED', 'PUSH_FINISHED_FALLBACK'], ['LIMIT', 'PUSH_LIMIT_FALLBACK'], ['ROTATION', 'PUSH_ROTATION_FALLBACK'], ['REQUEST_DESTRUCTIVE', 'PUSH_REQUEST_FALLBACK']]) {
      await send(mac, alert(phone, { category, sound: false, level: 'active' }));
      const { aps } = apns.last(phone.apnsToken)!.body;
      expect(aps.alert).toEqual({ 'loc-key': key });
      expect(aps.category).toBe(category);
      expect(aps.sound).toBeUndefined();
    }
  });

  it('keeps session health alerts passive whatever the Mac asks', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const body = alert(phone, { category: 'HEALTH', priority: 5, level: 'time-sensitive', sound: false });
    await send(mac, body);
    const push = apns.last(phone.apnsToken)!;
    expect(push.body).toEqual({
      aps: { alert: { 'loc-key': 'PUSH_HEALTH_FALLBACK' }, 'mutable-content': 1, category: 'HEALTH', 'interruption-level': 'passive' },
      e: body.sealed[phone.deviceId],
    });
    expect(push.headers).toMatchObject({ 'apns-priority': '5', 'apns-collapse-id': body.collapseId });
  });

  it('sends a passive Test Connection push, 5 an hour per install', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const body = alert(phone, { category: 'TEST', level: 'active' });
    for (let i = 0; i < 5; i++) expect((await send(mac, { ...body, collapseId: randomId() })).status).toBe(200);
    const push = apns.last(phone.apnsToken)!;
    expect(push.body.aps).toMatchObject({ alert: { 'loc-key': 'PUSH_TEST_FALLBACK' }, category: 'TEST', 'interruption-level': 'passive' });
    expect(push.body.e).toBe(body.sealed[phone.deviceId]);
    const limited = await send(mac, body);
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get('retry-after'))).toBeGreaterThan(3000);
    expect((await send(mac, alert(phone))).status).toBe(200);
  });

  it('sends one envelope to each of several devices', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const second = newPhone(mac);
    await putDevice(mac, second);
    await phoneCall(second, 'POST', '/v1/device/verify', { challenge: apns.last(second.apnsToken)!.body.verify.challenge });
    const body = alert([phone, second]);
    const response = await send(mac, body);
    expect((await response.json() as any).results.map((item: any) => [item.device, item.result])).toEqual([[phone.deviceId, 'ok'], [second.deviceId, 'ok']]);
    expect(apns.last(phone.apnsToken)!.body.e).toBe(body.sealed[phone.deviceId]);
    expect(apns.last(second.apnsToken)!.body.e).toBe(body.sealed[second.deviceId]);
  });

  it('answers unknown devices as gone without asking APNs', async () => {
    const apns = new FakeApns();
    const { mac } = await paired(apns);
    const stranger = newPhone(mac);
    const response = await send(mac, alert(stranger));
    expect(await response.json()).toEqual({ results: [{ device: stranger.deviceId, result: 'gone' }] });
    expect(apns.pushes).toHaveLength(0);
  });

  it('replaces an answered request with a passive, silent dismissal', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const collapseId = randomId();
    await send(mac, { devices: [phone.deviceId], kind: 'dismiss', collapseId });
    const push = apns.last(phone.apnsToken)!;
    expect(push.body).toEqual({ aps: { alert: { 'loc-key': 'PUSH_ANSWERED' }, category: 'ANSWERED', 'interruption-level': 'passive' } });
    expect(push.headers['apns-collapse-id']).toBe(collapseId);
  });
});

describe('the allowlist', () => {
  let mac: Mac;
  let phone: Phone;
  const rejects = async (body: unknown) => {
    const response = await send(mac, body);
    expect(response.status).toBe(400);
    return (await response.json() as any).error.message as string;
  };

  it('refuses anything outside it', async () => {
    const apns = new FakeApns();
    ({ mac, phone } = await paired(apns));
    expect(await rejects(alert(phone, { aps: { alert: 'Your bank needs you' } }))).toMatch(/unknown field aps/);
    expect(await rejects(alert(phone, { title: 'hello' }))).toMatch(/unknown field title/);
    expect(await rejects(alert(phone, { category: 'CUSTOM' }))).toMatch(/category/);
    expect(await rejects(alert(phone, { category: 'constructor' }))).toMatch(/category/);
    expect(await rejects(alert(phone, { level: 'critical' }))).toMatch(/level/);
    expect(await rejects(alert(phone, { priority: 1 }))).toMatch(/priority/);
    expect(await rejects(alert(phone, { expiresIn: 90_000 }))).toMatch(/expiresIn/);
    expect(await rejects(alert(phone, { collapseId: 'x'.repeat(65) }))).toMatch(/collapseId/);
    expect(await rejects(alert(phone, { sealed: sealed() }))).toMatch(/sealed/);
    expect(await rejects(alert(phone, { sealed: {} }))).toMatch(/sealed/);
    expect(await rejects(alert(phone, { sealed: { [phone.deviceId]: sealed(), [randomId()]: sealed() } }))).toMatch(/unknown field/);
    expect(await rejects(alert(phone, { sealed: { [phone.deviceId]: sealed(2300) } }))).toMatch(/too long/);
    const v1 = fromB64url(sealed())!;
    v1[0] = 1;
    expect(await rejects(alert(phone, { sealed: { [phone.deviceId]: btoa(String.fromCharCode(...v1)).replace(/=+$/, '') } }))).toMatch(/v2 envelope/);
    expect(await rejects({ ...alert(phone), devices: [phone.deviceId, phone.deviceId] })).toMatch(/duplicates/);
    expect(await rejects({ ...alert(phone), kind: 'raw' })).toMatch(/kind/);
    expect(apns.pushes).toHaveLength(0);
  });

  it('keeps words out of Live Activity content', async () => {
    const apns = new FakeApns();
    ({ mac, phone } = await paired(apns));
    const activity = (contentState: unknown) => ({ devices: [phone.deviceId], kind: 'liveactivity', event: 'start', contentState });
    expect(await rejects(activity({ working: 1, waiting: 0, sessionTitle: 'rm -rf' }))).toMatch(/unknown field sessionTitle/);
    expect(await rejects(activity({ working: 1, waiting: 0, topRequest: 'Bash in side-a' }))).toMatch(/opaque/);
    expect(await rejects(activity({ working: '3', waiting: 0 }))).toMatch(/counts/);
    expect(await rejects(activity({ working: 1, waiting: 0, tightestPercent: 101 }))).toMatch(/0-100/);
  });
});

describe('Live Activities', () => {
  const content = { working: 3, waiting: 1, topRequest: 'r_8h2k', soonestReset: 814000000, tightestPercent: 72 };

  it('starts with the push-to-start token, fixed attributes and the generic alert', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const response = await send(mac, { devices: [phone.deviceId], kind: 'liveactivity', event: 'start', contentState: content, priority: 10 });
    expect((await response.json() as any).results[0].result).toBe('ok');
    const push = apns.last(phone.pushToStartToken)!;
    expect(push.headers).toMatchObject({ 'apns-push-type': 'liveactivity', 'apns-topic': 'com.arnenoori.sidea.remote.push-type.liveactivity', 'apns-priority': '10' });
    expect(push.body.aps).toEqual({
      timestamp: expect.any(Number), event: 'start', 'content-state': content, 'attributes-type': 'MacActivityAttributes',
      attributes: { macID: expect.stringMatching(/^[A-Za-z0-9_-]{16}$/) },
      alert: { title: { 'loc-key': 'ACTIVITY_START_TITLE' }, body: { 'loc-key': 'ACTIVITY_START_BODY' } },
    });
    expect(push.body.aps.attributes.macID).not.toContain(mac.installId.slice(0, 6));
  });

  it('updates through the token the phone reported, downgrading bursts to priority 5, and forgets it after end', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const activityId = randomId();
    const updateToken = hexToken();
    expect((await phoneCall(phone, 'PUT', `/v1/device/activities/${activityId}`, { updateToken })).status).toBe(204);
    const update = { devices: [phone.deviceId], kind: 'liveactivity', event: 'update', activityId, contentState: content, priority: 10, staleDate: 1792201800 };
    await send(mac, update);
    await send(mac, update);
    const [first, second] = apns.to(updateToken);
    expect(first.headers['apns-priority']).toBe('10');
    expect(second.headers['apns-priority']).toBe('5');
    expect(first.body.aps['stale-date']).toBe(1792201800);

    await send(mac, { ...update, event: 'end', dismissalDate: 1792202000 });
    expect(apns.last(updateToken)!.body.aps).toMatchObject({ event: 'end', 'dismissal-date': 1792202000 });
    const after = await send(mac, update);
    expect((await after.json() as any).results[0].result).toBe('gone');
  });

  it('stops using an activity token once it is 12 hours old, and deletes it then', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const fresh = randomId();
    const old = randomId();
    const oldToken = hexToken();
    await phoneCall(phone, 'PUT', `/v1/device/activities/${fresh}`, { updateToken: hexToken() });
    await phoneCall(phone, 'PUT', `/v1/device/activities/${old}`, { updateToken: oldToken });
    await runInDurableObject(stub(mac.installId), (_: Install, state) => {
      state.storage.sql.exec('UPDATE activities SET created = ? WHERE id = ?', Date.now() - LIMITS.activityLifetime - 1000, old);
    });
    const response = await send(mac, { devices: [phone.deviceId], kind: 'liveactivity', event: 'update', activityId: old, contentState: content });
    expect(await response.json()).toEqual({ results: [{ device: phone.deviceId, result: 'gone' }] });
    expect(apns.to(oldToken)).toHaveLength(0);
    const left = await runInDurableObject(stub(mac.installId), (_: Install, state) =>
      state.storage.sql.exec<{ id: string }>('SELECT id FROM activities').toArray().map(row => row.id));
    expect(left).toEqual([fresh]);
  });

  it("won't let one device's phone touch another's activity", async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const other = newPhone(mac);
    await putDevice(mac, other);
    const activityId = randomId();
    await phoneCall(phone, 'PUT', `/v1/device/activities/${activityId}`, { updateToken: hexToken() });
    expect((await phoneCall(other, 'PUT', `/v1/device/activities/${activityId}`, { updateToken: hexToken() })).status).toBe(409);
  });

  it('refuses a start for a phone without a push-to-start token', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await putDevice(mac, phone, { pushToStartToken: null });
    const response = await send(mac, { devices: [phone.deviceId], kind: 'liveactivity', event: 'start', contentState: content });
    expect(await response.json()).toEqual({ results: [{ device: phone.deviceId, result: 'rejected', reason: 'NoPushToStartToken' }] });
  });
});

describe('pausing', () => {
  it('stops every send with 503 when RELAY_PAUSED is set', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const response = await worker.fetch(incoming(await signed(mac, 'POST', '/v1/send', alert(phone))), { ...env, RELAY_PAUSED: '1' } as unknown as Env, context);
    expect(response.status).toBe(503);
    expect(apns.pushes).toHaveLength(0);
  });
});
