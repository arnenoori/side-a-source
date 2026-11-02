import { createExecutionContext, env, waitOnExecutionContext } from 'cloudflare:test';
import { vi } from 'vitest';
import worker from '../src/index';
import { installIdFor, signedString } from '../src/auth';
import { b64url, sha256, utf8 } from '../src/bytes';

// The relay never reads its own hostname; any will do.
export const BASE = 'https://relay.test';

// Every request's waitUntil work (a verification push, a cleanup) is done before the test looks: no guessing how long.
export async function call(request: Request): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch!(incoming(request), env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

// For calling the handler directly with a changed env.
export const incoming = (request: Request) => request as Request<unknown, IncomingRequestCfProperties>;
export const context = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

export const randomId = () => b64url(crypto.getRandomValues(new Uint8Array(16)));
export const hexToken = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, '0')).join('');

export interface Mac {
  installId: string;
  publicKey: Uint8Array;
  privateKey: CryptoKey;
}

export async function newMac(): Promise<Mac> {
  const pair = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const publicKey = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey) as ArrayBuffer);
  return { installId: await installIdFor(publicKey), publicKey, privateKey: pair.privateKey };
}

export interface SignOptions {
  ts?: number;
  nonce?: string;
  key?: CryptoKey;
  headers?: Record<string, string>;
  raw?: string;
}

export async function signed(mac: Mac, method: string, path: string, body?: unknown, options: SignOptions = {}): Promise<Request> {
  const text = options.raw ?? (body === undefined ? '' : JSON.stringify(body));
  const ts = options.ts ?? Math.floor(Date.now() / 1000);
  const nonce = options.nonce ?? randomId();
  const message = await signedString(method, path, ts, nonce, utf8(text));
  const sig = b64url(await crypto.subtle.sign({ name: 'Ed25519' }, options.key ?? mac.privateKey, message));
  return new Request(BASE + path, {
    method,
    body: text || undefined,
    headers: {
      authorization: `SideA-Sig v=1, install=${mac.installId}, ts=${ts}, nonce=${nonce}, sig=${sig}`,
      'content-type': 'application/json',
      ...options.headers,
    },
  });
}

// Each test Mac gets its own address, so the per-IP registration limit only bites where a test wants it.
export const randomIp = () => `2001:db8:${Array.from(crypto.getRandomValues(new Uint16Array(2)), word => word.toString(16)).join(':')}::1`;

export const register = async (mac: Mac, ip = randomIp()) =>
  call(await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }, { headers: { 'cf-connecting-ip': ip } }));

export interface Phone {
  deviceId: string;
  secret: Uint8Array;
  apnsToken: string;
  pushToStartToken: string;
  bearer: string;
}

export function newPhone(mac: Mac): Phone {
  const deviceId = randomId();
  const secret = crypto.getRandomValues(new Uint8Array(32));
  return { deviceId, secret, apnsToken: hexToken(), pushToStartToken: hexToken(), bearer: `Bearer d1.${mac.installId}.${deviceId}.${b64url(secret)}` };
}

export const phoneCall = (phone: Phone, method: string, path: string, body?: unknown) =>
  call(new Request(BASE + path, {
    method, body: body === undefined ? undefined : JSON.stringify(body),
    headers: { authorization: phone.bearer, 'content-type': 'application/json' },
  }));

export async function putDevice(mac: Mac, phone: Phone, extra: Record<string, unknown> = {}) {
  return call(await signed(mac, 'PUT', `/v1/devices/${phone.deviceId}`, {
    apnsToken: phone.apnsToken, environment: 'production', secretHash: b64url(await sha256(phone.secret)),
    pushToStartToken: phone.pushToStartToken, appVersion: '1.0 (202610171200)', ...extra,
  }));
}

// A pretend APNs. Answers by token, records every request.
export interface Pushed {
  host: string;
  token: string;
  headers: Record<string, string>;
  body: any;
}

type Answer = { status: number; reason?: string; timestamp?: number } | ((push: Pushed) => { status: number; reason?: string; timestamp?: number });

export class FakeApns {
  pushes: Pushed[] = [];
  answers = new Map<string, Answer[]>();
  fallback: Answer = { status: 200 };

  constructor() {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      const match = url.pathname.match(/^\/3\/device\/([0-9a-f]+)$/);
      if (!url.host.endsWith('push.apple.com') || !match) throw new Error(`unexpected fetch ${request.url}`);
      const push: Pushed = {
        host: url.host, token: match[1], headers: Object.fromEntries(request.headers), body: JSON.parse(await request.text()),
      };
      this.pushes.push(push);
      const queued = this.answers.get(push.token);
      const answer = queued?.length ? queued.shift()! : this.fallback;
      const { status, reason, timestamp } = typeof answer === 'function' ? answer(push) : answer;
      if (status === 200) return new Response(null, { status, headers: { 'apns-id': crypto.randomUUID() } });
      return Response.json({ reason, ...(timestamp !== undefined ? { timestamp } : {}) }, { status });
    });
  }

  answer(token: string, ...answers: Answer[]) {
    this.answers.set(token, [...(this.answers.get(token) ?? []), ...answers]);
  }

  to(token: string) {
    return this.pushes.filter(push => push.token === token);
  }

  last(token: string) {
    return this.to(token).at(-1);
  }

  clear() {
    this.pushes = [];
  }
}

// Registers, adds a phone, and answers the verification push the way the app would.
export async function paired(apns: FakeApns, mac?: Mac, device: Record<string, unknown> = {}) {
  mac ??= await newMac();
  await register(mac);
  const phone = newPhone(mac);
  await putDevice(mac, phone, device);
  const challenge = apns.last(phone.apnsToken)!.body.verify.challenge;
  const verified = await phoneCall(phone, 'POST', '/v1/device/verify', { challenge });
  if (verified.status !== 204) throw new Error(`verify failed: ${verified.status}`);
  apns.clear();
  return { mac, phone };
}

export const sealed = (bytes = 64) => {
  const envelope = crypto.getRandomValues(new Uint8Array(bytes));
  envelope[0] = 0x02;
  return b64url(envelope);
};

export function alert(phone: Phone | Phone[], extra: Record<string, unknown> = {}) {
  const phones = Array.isArray(phone) ? phone : [phone];
  return {
    devices: phones.map(item => item.deviceId), kind: 'alert', category: 'REQUEST', collapseId: randomId(), priority: 10,
    expiresIn: 3600, sound: true, level: 'time-sensitive', sealed: Object.fromEntries(phones.map(item => [item.deviceId, sealed()])),
    ...extra,
  };
}

export const stub = (installId: string) => env.INSTALLS.get(env.INSTALLS.idFromName(installId));
