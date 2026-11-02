import { createScheduledController, env } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { CANARY_TOKEN } from '../src/health';
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
});
