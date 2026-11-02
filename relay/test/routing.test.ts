import { env } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { FakeApns, alert, call, context, incoming, newMac, newPhone, paired, phoneCall, putDevice, register, signed } from './helpers';

afterEach(() => vi.restoreAllMocks());

const APP = 'com.arnenoori.sidea.remote';
const DEV = 'com.arnenoori.sidea.remote.dev';
const DEV_BUILD = { bundleID: DEV, apnsEnvironment: 'sandbox', environment: undefined };

const start = (phone: { deviceId: string }) => ({
  devices: [phone.deviceId], kind: 'liveactivity', event: 'start', priority: 5, expiresIn: 0,
  contentState: { working: 1, waiting: 0 },
});
const update = (phone: { deviceId: string }, activityId: string) => ({ ...start(phone), event: 'update', activityId });

describe('APNs routing per registration', () => {
  it('defaults to the App Store app in production', async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    expect((await putDevice(mac, phone, { environment: undefined })).status).toBe(201);
    const challenge = apns.last(phone.apnsToken)!;
    expect([challenge.host, challenge.headers['apns-topic']]).toEqual(['api.push.apple.com', APP]);
  });

  it('sends a dev build its challenge, alerts and Live Activities under its own topic on the sandbox host', async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    await putDevice(mac, phone, DEV_BUILD);
    const challenge = apns.last(phone.apnsToken)!;
    expect([challenge.host, challenge.headers['apns-topic']]).toEqual(['api.sandbox.push.apple.com', DEV]);
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: challenge.body.verify.challenge })).status).toBe(204);

    await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
    const pushed = apns.last(phone.apnsToken)!;
    expect([pushed.host, pushed.headers['apns-topic'], pushed.headers['apns-push-type']]).toEqual(['api.sandbox.push.apple.com', DEV, 'alert']);

    await call(await signed(mac, 'POST', '/v1/send', start(phone)));
    const started = apns.last(phone.pushToStartToken)!;
    expect([started.host, started.headers['apns-topic']]).toEqual(['api.sandbox.push.apple.com', `${DEV}.push-type.liveactivity`]);

    const token = 'ab'.repeat(32);
    expect((await phoneCall(phone, 'PUT', '/v1/device/activities/a1', { updateToken: token })).status).toBe(204);
    await call(await signed(mac, 'POST', '/v1/send', update(phone, 'a1')));
    const updated = apns.last(token)!;
    expect([updated.host, updated.headers['apns-topic']]).toEqual(['api.sandbox.push.apple.com', `${DEV}.push-type.liveactivity`]);
  });

  it('routes an activity token by its own registration when it names one', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const token = 'cd'.repeat(32);
    await phoneCall(phone, 'PUT', '/v1/device/activities/a2', { updateToken: token, bundleID: DEV, apnsEnvironment: 'sandbox' });
    await call(await signed(mac, 'POST', '/v1/send', update(phone, 'a2')));
    const updated = apns.last(token)!;
    expect([updated.host, updated.headers['apns-topic']]).toEqual(['api.sandbox.push.apple.com', `${DEV}.push-type.liveactivity`]);
  });

  it('takes apnsEnvironment over the older environment, and development as sandbox', async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    await register(mac);
    const both = newPhone(mac);
    await putDevice(mac, both, { environment: 'production', apnsEnvironment: 'development' });
    const legacy = newPhone(mac);
    await putDevice(mac, legacy, { environment: 'sandbox' });
    expect(apns.last(both.apnsToken)!.host).toBe('api.sandbox.push.apple.com');
    expect(apns.last(legacy.apnsToken)!.host).toBe('api.sandbox.push.apple.com');
  });

  it('turns away a disallowed bundle id from the phone, for its tokens and its activities', async () => {
    const apns = new FakeApns();
    const { phone } = await paired(apns);
    expect((await phoneCall(phone, 'PUT', '/v1/device/tokens', { apnsToken: phone.apnsToken, bundleID: 'com.example.other' })).status).toBe(400);
    expect((await phoneCall(phone, 'PUT', '/v1/device/activities/a3', { updateToken: 'ef'.repeat(32), bundleID: 'com.example.other' })).status).toBe(400);
  });

  it('reads the allowlist from APNS_BUNDLES', async () => {
    new FakeApns();
    const narrow = { ...env, APNS_BUNDLES: APP } as unknown as Env;
    const mac = await newMac();
    await register(mac);
    const phone = newPhone(mac);
    const body = (bundleID: string) => ({ apnsToken: phone.apnsToken, secretHash: 'A'.repeat(43), appVersion: '1.0', bundleID });
    const pending: Promise<unknown>[] = [];
    const waiting = { ...context, waitUntil: (promise: Promise<unknown>) => pending.push(promise) } as ExecutionContext;
    const put = async (bundleID: string) => worker.fetch(incoming(await signed(mac, 'PUT', `/v1/devices/${phone.deviceId}`, body(bundleID))), narrow, waiting);
    expect((await put(DEV)).status).toBe(400);
    expect((await put(APP)).status).toBe(201);
    await Promise.all(pending);
  });

  it('needs a new proof when the phone moves its token to another app or host', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const moved = await phoneCall(phone, 'PUT', '/v1/device/tokens', { apnsToken: phone.apnsToken, bundleID: DEV, apnsEnvironment: 'sandbox' });
    expect(await moved.json()).toEqual({ verified: false });
    const challenge = apns.last(phone.apnsToken)!;
    expect([challenge.host, challenge.headers['apns-topic']]).toEqual(['api.sandbox.push.apple.com', DEV]);
    expect((await (await call(await signed(mac, 'POST', '/v1/send', alert(phone)))).json() as any).results[0].result).toBe('unverified');
  });

  it('records BadDeviceToken once neither host knows the token', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns, undefined, DEV_BUILD);
    apns.answer(phone.apnsToken, { status: 400, reason: 'BadDeviceToken' }, { status: 400, reason: 'BadDeviceToken' });
    const send = async () => (await (await call(await signed(mac, 'POST', '/v1/send', alert(phone)))).json() as any).results[0].result;
    expect(await send()).toBe('gone');
    expect(apns.to(phone.apnsToken).map(push => [push.host, push.headers['apns-topic']])).toEqual([
      ['api.sandbox.push.apple.com', DEV], ['api.push.apple.com', DEV],
    ]);
    const status = await (await call(await signed(mac, 'GET', '/v1/installs/self'))).json() as any;
    expect(status.gone).toEqual([{ device: phone.deviceId, reason: 'BadDeviceToken' }]);
    expect(await send()).toBe('gone');
  });

  it('forgets the reason once the phone brings a new token', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 400, reason: 'DeviceTokenNotForTopic' });
    await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
    await phoneCall(phone, 'PUT', '/v1/device/tokens', { apnsToken: 'ee'.repeat(32) });
    const status = await (await call(await signed(mac, 'GET', '/v1/installs/self'))).json() as any;
    expect(status.gone).toEqual([]);
  });
});
