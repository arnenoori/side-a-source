import { createScheduledController, env, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { CANARY_TOKEN, type Health, type Probe } from '../src/health';
import { FakeApns } from './helpers';

afterEach(() => vi.restoreAllMocks());

const run = () => worker.scheduled(createScheduledController({ cron: '*/15 * * * *' }), env);
const events = (spy: { mock: { calls: unknown[][] } }) => spy.mock.calls.map(([line]) => JSON.parse(line as string).event);

describe('canary', () => {
  it('probes both environments with a token that cannot exist and stays quiet on BadDeviceToken', async () => {
    const apns = new FakeApns();
    apns.fallback = { status: 400, reason: 'BadDeviceToken' };
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    await run();
    expect(apns.pushes.map(push => [push.host, push.token])).toEqual([
      ['api.sandbox.push.apple.com', CANARY_TOKEN], ['api.push.apple.com', CANARY_TOKEN],
    ]);
    expect(errors).not.toHaveBeenCalled();
  });

  it('pages on the second failure in a row, and resets after a success', async () => {
    const apns = new FakeApns();
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    apns.fallback = push => push.host.startsWith('api.sandbox') ? { status: 400, reason: 'BadDeviceToken' } : { status: 403, reason: 'InvalidProviderToken' };
    await run();
    expect(events(errors)).toEqual(['canary.fail']);
    await run();
    expect(events(errors)).toEqual(['canary.fail', 'canary.page']);

    apns.fallback = { status: 400, reason: 'BadDeviceToken' };
    await run();
    apns.fallback = push => push.host.startsWith('api.sandbox') ? { status: 400, reason: 'BadDeviceToken' } : { status: 500 };
    await run();
    expect(events(errors)).toEqual(['canary.fail', 'canary.page', 'canary.fail']);
  });

  it('writes a streak only when it changes', async () => {
    const object = env.HEALTH.get(env.HEALTH.idFromName(`streaks-${crypto.randomUUID()}`));
    const probes = (sandbox: boolean, production: boolean): Probe[] =>
      [{ environment: 'sandbox', ok: sandbox, status: 400 }, { environment: 'production', ok: production, status: 400 }];
    const writes = await runInDurableObject(object, async (instance: Health, state) => {
      const put = vi.spyOn(state.storage, 'put');
      const counted: unknown[][] = [];
      for (const run of [probes(true, true), probes(true, false), probes(true, false), probes(true, true), probes(true, true)]) {
        put.mockClear();
        await instance.record(run);
        counted.push(put.mock.calls.map(([key, value]) => [key, value]));
      }
      return counted;
    });
    expect(writes).toEqual([[], [['failures:production', 1]], [['failures:production', 2]], [['failures:production', 0]], []]);
  });
});
