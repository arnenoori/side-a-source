import { b64url, fromBase64, utf8 } from './bytes';
import type { ApnsRequest } from './send';

export type Environment = 'sandbox' | 'production';

export const HOSTS: Record<Environment, string> = {
  sandbox: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
};

export interface ApnsKey {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
}

// Apple wants a token no fresher than 20 minutes and no older than an hour. Every isolate signs the
// same iat for 40 minutes, so no shared cache is needed to stay under the refresh limit.
const BUCKET = 2400;
let cached: { keyId: string; iat: number; jwt: string } | null = null;

export async function providerToken(env: ApnsKey, now: number, fresh = false): Promise<string> {
  const iat = now - (now % BUCKET);
  if (!fresh && cached?.keyId === env.APNS_KEY_ID && cached.iat === iat) return cached.jwt;
  const der = fromBase64(env.APNS_KEY_P8.replace(/-----[^-]+-----|\s/g, ''));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const input = b64url(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID })) + '.' +
    b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat }));
  // Web Crypto returns raw r‖s, which is already the JWS form.
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, utf8(input));
  cached = { keyId: env.APNS_KEY_ID, iat, jwt: `${input}.${b64url(sig)}` };
  return cached.jwt;
}

export function forgetProviderToken() {
  cached = null;
}

export interface ApnsResponse {
  status: number;
  reason?: string;
  timestamp?: number;   // ms, on 410
  apnsId?: string;
}

export async function post(env: ApnsKey, environment: Environment, token: string, request: ApnsRequest, now: number, fresh = false): Promise<ApnsResponse> {
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken(env, now, fresh)}`,
    'apns-push-type': request.pushType,
    'apns-topic': request.topic,
    'apns-priority': String(request.priority),
    'apns-expiration': String(request.expiration),
    'content-type': 'application/json',
  };
  if (request.collapseId) headers['apns-collapse-id'] = request.collapseId;
  const response = await fetch(`${HOSTS[environment]}/3/device/${token}`, { method: 'POST', headers, body: request.payload });
  const apnsId = response.headers.get('apns-id') ?? undefined;
  if (response.status === 200) return { status: 200, apnsId };
  let body: { reason?: unknown; timestamp?: unknown } = {};
  try { body = await response.json(); } catch { /* APNs always sends JSON on errors; a proxy may not */ }
  return {
    status: response.status,
    reason: typeof body.reason === 'string' ? body.reason : undefined,
    timestamp: typeof body.timestamp === 'number' ? body.timestamp : undefined,
    apnsId,
  };
}

export type Outcome =
  | { result: 'ok'; apnsId?: string; environment?: Environment }
  | { result: 'gone'; reason: string; timestamp?: number }
  | { result: 'retry'; after: number; reason?: string }
  | { result: 'rejected'; reason: string };

const PROVIDER = ['ExpiredProviderToken', 'InvalidProviderToken', 'MissingProviderToken'];
const BACKOFF = [250, 1000];

export interface Delivery {
  token: string;
  environment: Environment;
  request: ApnsRequest;
  canFlip: boolean;   // a device token may have been registered under the wrong environment
}

export interface DeliverOptions {
  now: number;
  sleep?: (ms: number) => Promise<void>;
  log?: (event: string, fields: Record<string, unknown>) => void;
}

// One push to one token, with the retries the spec allows. `environment` in an ok outcome means
// the token answered from the other environment and the device should be moved there.
export async function deliver(env: ApnsKey, delivery: Delivery, options: DeliverOptions): Promise<Outcome> {
  const sleep = options.sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms)));
  let environment = delivery.environment;
  let flipped = false;
  let reminted = false;
  let attempt = 0;
  for (;;) {
    let response: ApnsResponse;
    try {
      response = await post(env, environment, delivery.token, delivery.request, options.now, reminted);
    } catch {
      response = { status: 503, reason: 'Unreachable' };
    }
    const { status, reason } = response;
    if (status === 200) return { result: 'ok', apnsId: response.apnsId, ...(flipped ? { environment } : {}) };
    if (status === 410) return { result: 'gone', reason: reason ?? 'Unregistered', timestamp: response.timestamp };
    if (status === 400 && reason === 'BadDeviceToken') {
      if (delivery.canFlip && !flipped) {
        flipped = true;
        environment = environment === 'sandbox' ? 'production' : 'sandbox';
        continue;
      }
      return { result: 'gone', reason };
    }
    // A dev build's token sent under the App Store app's topic, or the other way round.
    if (status === 400 && reason === 'DeviceTokenNotForTopic') return { result: 'gone', reason };
    if (status === 403 && reason && PROVIDER.includes(reason)) {
      if (reminted) return { result: 'retry', after: 60, reason };
      reminted = true;
      forgetProviderToken();
      continue;
    }
    if (status === 429) {
      if (reason === 'TooManyProviderTokenUpdates') options.log?.('apns.token_updates', { reason });
      return { result: 'retry', after: 60, reason };
    }
    if (status >= 500) {
      if (attempt < BACKOFF.length) {
        await sleep(BACKOFF[attempt++]);
        continue;
      }
      return { result: 'retry', after: 30, reason };
    }
    return { result: 'rejected', reason: reason ?? `HTTP ${status}` };
  }
}
