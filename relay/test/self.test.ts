import { env } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { FakeApns, alert, call, context, incoming, newMac, newPhone, paired, phoneCall, putDevice, register, signed } from './helpers';

afterEach(() => vi.restoreAllMocks());

describe('GET /v1/installs/self', () => {
  it('is 404 for an install the relay has never seen', async () => {
    const response = await call(await signed(await newMac(), 'GET', '/v1/installs/self'));
    expect(response.status).toBe(404);
    expect((await response.json() as any).error.code).toBe('not_found');
  });

  it('describes a registered install with nothing paired', async () => {
    const mac = await newMac();
    await register(mac);
    const response = await call(await signed(mac, 'GET', '/v1/installs/self'));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ registered: true, devices: 0, verified: 0, activities: 0, gone: [], paused: false });
  });

  it('counts devices, verified devices and activities', async () => {
    const apns = new FakeApns();
    const { mac, phone } = await paired(apns);
    await putDevice(mac, newPhone(mac));
    await phoneCall(phone, 'PUT', '/v1/device/activities/a', { updateToken: 'cd'.repeat(32) });
    const response = await call(await signed(mac, 'GET', '/v1/installs/self'));
    expect(await response.json()).toEqual({ registered: true, devices: 2, verified: 1, activities: 1, gone: [], paused: false });
  });

  it('stops counting a device as verified once APNs says it is gone, and says why', async () => {
    for (const [code, reason] of [[410, 'Unregistered'], [400, 'DeviceTokenNotForTopic']] as const) {
      const apns = new FakeApns();
      const { mac, phone } = await paired(apns);
      apns.answer(phone.apnsToken, { status: code, reason, timestamp: Date.now() + 1000 });
      const sent = await (await call(await signed(mac, 'POST', '/v1/send', alert(phone)))).json() as any;
      expect(sent.results[0], reason).toEqual({ device: phone.deviceId, result: 'gone', reason });
      expect(apns.to(phone.apnsToken), reason).toHaveLength(1);
      const body = await (await call(await signed(mac, 'GET', '/v1/installs/self'))).json() as any;
      expect(body, reason).toMatchObject({ devices: 1, verified: 0, gone: [{ device: phone.deviceId, reason }] });
    }
  });

  it('reports a paused relay', async () => {
    const mac = await newMac();
    await register(mac);
    const response = await worker.fetch(incoming(await signed(mac, 'GET', '/v1/installs/self')), { ...env, RELAY_PAUSED: '1' } as unknown as Env, context);
    expect(((await response.json()) as any).paused).toBe(true);
  });
});
