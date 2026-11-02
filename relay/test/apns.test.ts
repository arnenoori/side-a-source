import { afterEach, describe, expect, it, vi } from 'vitest';
import { providerToken } from '../src/apns';
import { FakeApns, alert, call, paired, phoneCall, signed, type Mac, type Phone } from './helpers';
import { env } from 'cloudflare:test';

afterEach(() => vi.restoreAllMocks());

const send = async (mac: Mac, phone: Phone) => {
  const response = await call(await signed(mac, 'POST', '/v1/send', alert(phone)));
  return (await response.json() as any).results[0];
};

describe('APNs responses', () => {
  it('marks a 410 token gone, and the Mac sees gone until the phone reports a new one', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 410, reason: 'Unregistered', timestamp: Date.now() + 1000 });
    expect(await send(mac, phone)).toEqual({ device: phone.deviceId, result: 'gone', reason: 'Unregistered' });
    apns.clear();
    expect(await send(mac, phone)).toEqual({ device: phone.deviceId, result: 'gone' });
    expect(apns.pushes).toHaveLength(0);
  });

  it('keeps a token registered after the 410 was issued', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 410, reason: 'Unregistered', timestamp: Date.now() - 60_000 });
    expect((await send(mac, phone)).result).toBe('gone');
    expect((await send(mac, phone)).result).toBe('ok');
  });

  it('drops an activity whose update token is gone', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    const token = 'ab'.repeat(32);
    await phoneCall(phone, 'PUT', '/v1/device/activities/act1', { updateToken: token });
    apns.answer(token, { status: 410, reason: 'Unregistered', timestamp: Date.now() + 1000 });
    const update = { devices: [phone.deviceId], kind: 'liveactivity', event: 'update', activityId: 'act1', contentState: { working: 1, waiting: 0 } };
    const first = await call(await signed(mac, 'POST', '/v1/send', update));
    expect((await first.json() as any).results[0].result).toBe('gone');
    apns.clear();
    const second = await call(await signed(mac, 'POST', '/v1/send', update));
    expect((await second.json() as any).results[0].result).toBe('gone');
    expect(apns.pushes).toHaveLength(0);
    // The device itself is untouched.
    expect((await send(mac, phone)).result).toBe('ok');
  });

  it('tries the other environment once on BadDeviceToken, and remembers it', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 400, reason: 'BadDeviceToken' });
    expect((await send(mac, phone)).result).toBe('ok');
    expect(apns.to(phone.apnsToken).map(push => push.host)).toEqual(['api.push.apple.com', 'api.sandbox.push.apple.com']);
    apns.clear();
    await send(mac, phone);
    expect(apns.last(phone.apnsToken)!.host).toBe('api.sandbox.push.apple.com');
  });

  it('re-mints the provider token once on 403', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 403, reason: 'ExpiredProviderToken' });
    expect((await send(mac, phone)).result).toBe('ok');
    const [first, second] = apns.to(phone.apnsToken);
    expect(second.headers.authorization).not.toBe(first.headers.authorization);

    apns.answer(phone.apnsToken, { status: 403, reason: 'InvalidProviderToken' }, { status: 403, reason: 'InvalidProviderToken' });
    expect(await send(mac, phone)).toEqual({ device: phone.deviceId, result: 'retry', after: 60 });
  });

  it('asks the Mac to retry after a per-device 429', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 429, reason: 'TooManyRequests' });
    expect(await send(mac, phone)).toEqual({ device: phone.deviceId, result: 'retry', after: 60 });
  });

  it('retries 5xx twice with backoff before giving up', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 503, reason: 'ServiceUnavailable' }, { status: 500, reason: 'InternalServerError' });
    expect((await send(mac, phone)).result).toBe('ok');
    expect(apns.to(phone.apnsToken)).toHaveLength(3);
    apns.answer(phone.apnsToken, ...Array(3).fill({ status: 503, reason: 'ServiceUnavailable' }));
    expect(await send(mac, phone)).toEqual({ device: phone.deviceId, result: 'retry', after: 30 });
  });

  it('reports other refusals as rejected, a bug on our side', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    apns.answer(phone.apnsToken, { status: 400, reason: 'TopicDisallowed' });
    expect(await send(mac, phone)).toEqual({ device: phone.deviceId, result: 'rejected', reason: 'TopicDisallowed' });
    apns.answer(phone.apnsToken, { status: 413, reason: 'PayloadTooLarge' });
    expect(await send(mac, phone)).toEqual({ device: phone.deviceId, result: 'rejected', reason: 'PayloadTooLarge' });
  });
});

describe('provider token', () => {
  it('signs the same iat for 40 minutes and a new one after', async () => {
    const at = 1_792_200_000 - (1_792_200_000 % 2400);
    const first = await providerToken(env, at + 10);
    expect(await providerToken(env, at + 2399)).toBe(first);
    const next = await providerToken(env, at + 2400);
    expect(next).not.toBe(first);
    expect(JSON.parse(atob(next.split('.')[1])).iat).toBe(at + 2400);
  });
});
