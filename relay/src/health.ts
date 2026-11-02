// The canary. APNs over HTTP/2 from Workers works because of Cloudflare's proxy, not a promise, so
// every 15 minutes each environment gets a push to a token that can't exist. 400 BadDeviceToken
// proves HTTP/2, the JWT and the route without waking a phone. Two failures in a row page us.
import { DurableObject } from 'cloudflare:workers';
import { post, type ApnsKey, type Environment } from './apns';
import { DEFAULT_BUNDLE } from './send';

export const CANARY_TOKEN = '00'.repeat(32);
export const PAGE_AFTER = 2;

export interface Probe {
  environment: Environment;
  ok: boolean;
  status: number;
  reason?: string;
}

export async function probe(env: ApnsKey, environment: Environment, now: number): Promise<Probe> {
  try {
    const { status, reason } = await post(env, environment, CANARY_TOKEN, {
      pushType: 'alert', topic: DEFAULT_BUNDLE, priority: 5, expiration: 0,
      payload: JSON.stringify({ aps: { alert: { 'loc-key': 'PUSH_REQUEST_FALLBACK' } } }),
    }, now);
    return { environment, ok: status === 400 && reason === 'BadDeviceToken', status, reason };
  } catch (error) {
    return { environment, ok: false, status: 0, reason: error instanceof Error ? error.name : 'Error' };
  }
}

// Counts consecutive failures per environment across cron runs.
export class Health extends DurableObject<Env> {
  async record(probes: Probe[]): Promise<Record<string, number>> {
    const streaks: Record<string, number> = {};
    for (const { environment, ok } of probes) {
      const key = `failures:${environment}`;
      const streak = ok ? 0 : ((await this.ctx.storage.get<number>(key)) ?? 0) + 1;
      await this.ctx.storage.put(key, streak);
      streaks[environment] = streak;
    }
    return streaks;
  }
}
