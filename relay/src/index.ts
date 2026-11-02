// sidea-push: holds the APNs key and nothing worth reading. Spec: docs/remote/relay-and-release.md.
import { CLOCK_SKEW, ID, parseDeviceBearer, parseSignature, signedString } from './auth';
import { b64url, fromB64url, sha256, utf8 } from './bytes';
import { deliver, type Outcome } from './apns';
import { PAGE_AFTER, probe } from './health';
import { type Ledger } from './ledger';
import type { ApnsRoute, Answer, DeviceInput, DeviceResult, Install, MacOp, PhoneOp, Plan, Reply, Report, Target } from './install';
import { DEFAULT_BUNDLE, DEFAULT_BUNDLES, Invalid, MAX_APNS_PAYLOAD, parseSend } from './send';

export { Install } from './install';
export { Health } from './health';
export { Ledger } from './ledger';

const MAX_BODY = 8192;
const REGISTRATIONS_PER_DAY = 50;
const TOKEN = /^[0-9a-fA-F]{64,200}$/;
const OPAQUE = /^[A-Za-z0-9_-]{1,64}$/;
const VERSION = /^[0-9A-Za-z.+() -]{1,32}$/;

type Json = Record<string, unknown>;

function respond(reply: Reply): Response {
  const headers: Record<string, string> = { date: new Date().toUTCString() };
  if (reply.retryAfter !== undefined) headers['retry-after'] = String(reply.retryAfter);
  if (reply.code) {
    const retryable = reply.status === 429 || reply.status >= 500;
    return Response.json({ error: { code: reply.code, message: reply.message ?? '', retryable } }, { status: reply.status, headers });
  }
  if (reply.body === undefined) return new Response(null, { status: reply.status, headers });
  return Response.json(reply.body, { status: reply.status, headers });
}

const failure = (status: number, code: string, message: string, retryAfter?: number): Reply => ({ status, code, message, retryAfter });
const isPlan = (value: Answer | Plan): value is Plan => 'targets' in value;
const configured = (env: Env) => Boolean(env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID);

async function readBody(request: Request): Promise<Uint8Array | null> {
  if (Number(request.headers.get('content-length') ?? 0) > MAX_BODY) return null;
  if (!request.body) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let size = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function parseJson(body: Uint8Array): Json {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(body));
  } catch {
    throw new Invalid('body: not JSON');
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Invalid('body: not an object');
  return value as Json;
}

function key32(value: unknown, what: string): Uint8Array {
  const bytes = typeof value === 'string' ? fromB64url(value) : null;
  if (bytes?.length !== 32) throw new Invalid(`${what}: 32 bytes, base64url`);
  return bytes;
}

function token(value: unknown, what: string): string {
  if (typeof value !== 'string' || !TOKEN.test(value)) throw new Invalid(`${what}: a hex token`);
  return value.toLowerCase();
}

const allowedBundles = (env: Env) => {
  const listed = (env.APNS_BUNDLES ?? '').split(',').map(bundle => bundle.trim()).filter(Boolean);
  return listed.length ? listed : DEFAULT_BUNDLES;
};

// `bundleID` and `apnsEnvironment`, as the phone's PushRegistration names them. `environment` is
// the older name; `apnsEnvironment` wins when both are there.
function apnsRoute(body: Json, env: Env): Partial<ApnsRoute> {
  const { bundleID } = body;
  if (bundleID != null && (typeof bundleID !== 'string' || !allowedBundles(env).includes(bundleID))) {
    throw new Invalid('bundleID: not one of this relay\'s apps');
  }
  const named = body.apnsEnvironment ?? body.environment;
  // `development` is the aps-environment entitlement's own name for sandbox.
  const environment = named === 'development' ? 'sandbox' : named;
  if (environment != null && environment !== 'sandbox' && environment !== 'production') {
    throw new Invalid('apnsEnvironment: sandbox, development or production');
  }
  return { bundle: bundleID ?? undefined, environment: environment ?? undefined };
}

function deviceInput(body: Json, env: Env): DeviceInput {
  const { appVersion, pushToStartToken } = body;
  const route = apnsRoute(body, env);
  if (typeof appVersion !== 'string' || !VERSION.test(appVersion)) throw new Invalid('appVersion: a short version string');
  return {
    apnsToken: token(body.apnsToken, 'apnsToken'),
    bundle: route.bundle ?? DEFAULT_BUNDLE,
    environment: route.environment ?? 'production',
    secretHash: key32(body.secretHash, 'secretHash'),
    pushToStartToken: pushToStartToken == null ? undefined : token(pushToStartToken, 'pushToStartToken'),
    appVersion,
  };
}

const paused = (env: Env) => /^(1|true|yes)$/i.test(env.RELAY_PAUSED ?? '');
const tunnelPaused = (env: Env) => /^(1|true|yes)$/i.test(env.RELAY_TUNNEL_PAUSED ?? '');

// An IPv6 customer usually holds a whole /64, so that's what counts as one address.
export function network(ip: string): string {
  if (!ip.includes(':')) return ip;
  const [head, tail = ''] = ip.toLowerCase().split('::');
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  const groups = [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill('0'), ...right];
  return groups.slice(0, 4).map(group => group.replace(/^0+(?=.)/, '')).join(':');
}

// The IP is only ever held as HMAC(today's key, network) for the rest of the day, never logged.
async function clientKey(env: Env, ip: string, day: number): Promise<string> {
  const hmac = async (secret: Uint8Array, text: string) => {
    const key = await crypto.subtle.importKey('raw', secret, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    return new Uint8Array(await crypto.subtle.sign('HMAC', key, utf8(text)));
  };
  const todaysKey = await hmac(utf8(env.RATE_KEY), `register day ${day}`);
  return b64url(await hmac(todaysKey, network(ip)));
}

interface RegistrationGate {
  limited?: Reply;
  ledger?: DurableObjectStub<Ledger>;
  dayEnds: number;
  fullFor: number;
}

// POST /installs: 10 a minute per network and location (the binding), and 50 new installs a day per
// network everywhere (the ledger). A Mac already registered never counts and is never turned away.
async function registrationGate(request: Request, env: Env, now: number): Promise<RegistrationGate> {
  const day = Math.floor(now / 86_400_000);
  const dayEnds = (day + 1) * 86_400_000;
  const client = await clientKey(env, request.headers.get('cf-connecting-ip') ?? 'unknown', day);
  const { success } = await env.REGISTER_LIMIT.limit({ key: client });
  if (!success) return { limited: failure(429, 'rate_limited', 'Too many registrations from this network', 60), dayEnds, fullFor: 0 };
  const ledger = env.LEDGER.get(env.LEDGER.idFromName(`registrations:${day}:${client}`));
  const full = await ledger.registrations() >= REGISTRATIONS_PER_DAY;
  return { ledger, dayEnds, fullFor: full ? Math.ceil((dayEnds - now) / 1000) : 0 };
}

function macOp(method: string, path: string, body: Json, env: Env): MacOp | null {
  if (path === '/v1/installs/self' && method === 'GET') return { op: 'self', paused: paused(env) };
  if (path === '/v1/installs' && method === 'POST') return { op: 'register', publicKey: key32(body.publicKey, 'publicKey'), fullFor: 0 };
  if (path === '/v1/installs/rotate' && method === 'POST') return { op: 'rotate', newPublicKey: key32(body.newPublicKey, 'newPublicKey') };
  if (path === '/v1/installs' && method === 'DELETE') return { op: 'delete' };
  if (path === '/v1/send' && method === 'POST') return { op: 'send', send: parseSend(body) };
  const device = path.match(/^\/v1\/devices\/([^/]+)$/);
  if (device && ID.test(device[1])) {
    if (method === 'PUT') return { op: 'putDevice', deviceId: device[1], device: deviceInput(body, env) };
    if (method === 'DELETE') return { op: 'deleteDevice', deviceId: device[1] };
  }
  return null;
}

function phoneOp(method: string, path: string, body: Json, env: Env): PhoneOp | null {
  if (path === '/v1/device/tokens' && method === 'PUT') {
    const apnsToken = body.apnsToken == null ? undefined : token(body.apnsToken, 'apnsToken');
    const pushToStartToken = body.pushToStartToken == null ? undefined : token(body.pushToStartToken, 'pushToStartToken');
    if (!apnsToken && !pushToStartToken) throw new Invalid('apnsToken or pushToStartToken');
    return { op: 'tokens', apnsToken, pushToStartToken, route: apnsRoute(body, env) };
  }
  if (path === '/v1/device/verify' && method === 'POST') {
    const challenge = typeof body.challenge === 'string' ? fromB64url(body.challenge) : null;
    if (challenge?.length !== 16) throw new Invalid('challenge: 16 bytes, base64url');
    return { op: 'verify', challenge };
  }
  if (path === '/v1/device' && method === 'DELETE') return { op: 'unpair' };
  const activity = path.match(/^\/v1\/device\/activities\/([^/]+)$/);
  if (activity && OPAQUE.test(activity[1])) {
    if (method === 'PUT') {
      return { op: 'putActivity', activityId: activity[1], updateToken: token(body.updateToken, 'updateToken'), route: apnsRoute(body, env) };
    }
    if (method === 'DELETE') return { op: 'deleteActivity', activityId: activity[1] };
  }
  return null;
}

function deviceResult(device: string, outcome: Outcome): DeviceResult {
  switch (outcome.result) {
    case 'ok': return { device, result: 'ok', apnsId: outcome.apnsId };
    case 'gone': return { device, result: 'gone', reason: outcome.reason };
    case 'retry': return { device, result: 'retry', after: outcome.after };
    case 'rejected': return { device, result: 'rejected', reason: outcome.reason };
  }
}

function count(env: Env, event: string, reason = '', value = 1) {
  env.METRICS?.writeDataPoint({ blobs: [event, reason], doubles: [value] });
}

const log = (event: string, fields: Record<string, unknown>) => console.error(JSON.stringify({ event, ...fields }));

// Whether this Live Activity token belongs to the proven device that wants to use it.
async function ownsToken(env: Env, target: Target, now: number): Promise<boolean> {
  const name = b64url(await sha256(utf8(target.delivery.token)));
  const owner = b64url(await sha256(utf8(target.owner!)));
  return env.LEDGER.get(env.LEDGER.idFromName(`token:${name}`)).claim(owner, now);
}

async function push(env: Env, target: Target, now: number): Promise<Report> {
  if (target.owner) {
    let owns: boolean;
    try {
      owns = await ownsToken(env, target, now);
    } catch {
      return { target, outcome: { result: 'retry', after: 5, reason: 'LedgerUnavailable' } };
    }
    if (!owns) return { target, outcome: { result: 'rejected', reason: 'TokenHeldByAnotherDevice' } };
  }
  if (utf8(target.delivery.request.payload).length >= MAX_APNS_PAYLOAD) return { target, outcome: { result: 'rejected', reason: 'PayloadTooLarge' } };
  return { target, outcome: await deliver(env, target.delivery, { now: Math.floor(now / 1000), log }) };
}

async function send(env: Env, stub: DurableObjectStub<Install>, devices: string[], plan: Plan, now: number): Promise<Reply> {
  if (!configured(env)) return failure(503, 'not_configured', 'The relay has no APNs key');
  const reports = await Promise.all(plan.targets.map(target => push(env, target, now)));
  // Successes too: the object keeps a last-send date for its 90-day cleanup.
  const settle = reports.filter(({ outcome }) => outcome.result === 'ok' || outcome.result === 'gone');
  if (settle.length) await stub.settle(settle);
  for (const { outcome } of reports) {
    count(env, `send.${outcome.result}`, outcome.result === 'rejected' || outcome.result === 'retry' ? outcome.reason : '');
  }
  const results = [...plan.results, ...reports.map(({ target, outcome }) => deviceResult(target.deviceId, outcome))];
  results.sort((a, b) => devices.indexOf(a.device) - devices.indexOf(b.device));
  return { status: 200, body: { results } };
}

// The verification push for a new token. Its outcome only matters if APNs says the token is gone.
async function challenge(env: Env, stub: DurableObjectStub<Install>, result: Answer, now: number, ctx: ExecutionContext): Promise<Reply> {
  if (result.challenge && configured(env)) {
    const target = result.challenge;
    ctx.waitUntil(push(env, target, now).then(async report => {
      count(env, `challenge.${report.outcome.result}`);
      if (report.outcome.result === 'gone' || (report.outcome.result === 'ok' && report.outcome.environment)) await stub.settle([report]);
    }));
  }
  return result.reply;
}

async function route(request: Request, env: Env, ctx: ExecutionContext, url: URL, now: number): Promise<{ reply: Reply; install?: string; socket?: Response }> {
  const { pathname: path } = url;
  const method = request.method;
  if (path === '/v1/health' && (method === 'GET' || method === 'HEAD')) return { reply: { status: 200 } };
  if (!path.startsWith('/v1/')) return { reply: failure(404, 'not_found', 'No such route') };
  if (path === '/v1/tunnel/mac' || path === '/v1/tunnel/phone') return tunnel(request, env, path, now);

  const body = await readBody(request);
  if (!body) return { reply: failure(413, 'too_large', `Bodies are at most ${MAX_BODY} bytes`) };
  const json = body.length ? parseJson(body) : {};
  const authorization = request.headers.get('authorization');

  if (path === '/v1/device' || path.startsWith('/v1/device/')) {
    const credential = await parseDeviceBearer(authorization);
    if (!credential) return { reply: failure(401, 'unauthorized', 'Missing or malformed device token') };
    const op = phoneOp(method, path, json, env);
    if (!op) return { reply: failure(404, 'not_found', 'No such route'), install: credential.install };
    const stub = env.INSTALLS.get(env.INSTALLS.idFromName(credential.install));
    const result = await stub.phone(credential.device, credential.secretHash, op, now);
    return { reply: await challenge(env, stub, result, now, ctx), install: credential.install };
  }

  const signature = parseSignature(authorization);
  if (!signature) return { reply: failure(401, 'unauthorized', 'Missing or malformed signature') };
  if (Math.abs(now / 1000 - signature.ts) > CLOCK_SKEW) {
    return { reply: failure(401, 'clock_skew', 'Timestamp is more than 120 seconds from the relay clock; see Date'), install: signature.install };
  }
  const op = macOp(method, path, json, env);
  if (!op) return { reply: failure(404, 'not_found', 'No such route'), install: signature.install };
  if (op.op === 'send' && paused(env)) return { reply: failure(503, 'paused', 'Sending is paused', 300), install: signature.install };
  const gate = op.op === 'register' ? await registrationGate(request, env, now) : undefined;
  if (gate?.limited) return { reply: gate.limited, install: signature.install };
  if (op.op === 'register') op.fullFor = gate!.fullFor;
  const stub = env.INSTALLS.get(env.INSTALLS.idFromName(signature.install));
  const message = await signedString(method, path, signature.ts, signature.nonce, body);
  const result = await stub.mac(signature.install, { message, sig: signature.sig, nonce: signature.nonce, ts: signature.ts }, op, now);
  if (gate && 'reply' in result && (result.reply as Reply).status === 201) await gate.ledger!.registered(gate.dayEnds);
  if (!isPlan(result)) return { reply: await challenge(env, stub, result, now, ctx), install: signature.install };
  return { reply: await send(env, stub, op.op === 'send' ? op.send.devices : [], result, now), install: signature.install };
}

// The upgrade only says which install; the install's object checks the signature, credential or ticket.
async function tunnel(request: Request, env: Env, path: string, now: number): Promise<{ reply: Reply; install?: string; socket?: Response }> {
  if (request.method !== 'GET') return { reply: failure(405, 'method_not_allowed', 'GET with Upgrade: websocket') };
  if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return { reply: failure(426, 'upgrade_required', 'This route is a WebSocket') };
  if (tunnelPaused(env)) return { reply: failure(503, 'paused', 'The tunnel is paused', 300) };
  const authorization = request.headers.get('authorization');
  const install = path === '/v1/tunnel/mac' ? parseSignature(authorization)?.install
    : (await parseDeviceBearer(authorization))?.install ?? authorization?.match(/^SideA-Pair ([A-Za-z0-9_-]{22})\.[A-Za-z0-9_-]{22}$/)?.[1];
  if (!install) return { reply: failure(401, 'unauthorized', 'Missing or malformed credential') };
  // Nothing has been proved yet, and what follows wakes an object: a well-formed guess costs its sender.
  const ip = request.headers.get('cf-connecting-ip');
  if (ip && !(await env.TUNNEL_LIMIT.limit({ key: await clientKey(env, ip, Math.floor(now / 86_400_000)) })).success) {
    return { reply: failure(429, 'rate_limited', 'Too many tunnel connections from this network', 10), install };
  }
  const response = await env.INSTALLS.get(env.INSTALLS.idFromName(install)).fetch(request);
  count(env, `tunnel.${path.endsWith('mac') ? 'mac' : 'phone'}`, String(response.status));
  if (response.webSocket) return { reply: { status: response.status }, install, socket: response };
  // Refusals go out like every other reply, with the relay's Date for a Mac whose clock is off.
  const error = (await response.json<{ error?: { code: string; message: string } }>().catch(() => null))?.error;
  const retryAfter = response.headers.get('retry-after');
  return { reply: failure(response.status, error?.code ?? 'tunnel_refused', error?.message ?? '', retryAfter === null ? undefined : Number(retryAfter)), install };
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const started = Date.now();
    const url = new URL(request.url);
    let outcome: { reply: Reply; install?: string; socket?: Response };
    try {
      outcome = await route(request, env, ctx, url, started);
    } catch (error) {
      if (!(error instanceof Invalid)) throw error;
      outcome = { reply: failure(400, 'bad_request', error.message) };
    }
    // Never the body, a token, a secret, an IP address or a header.
    console.log(JSON.stringify({
      route: `${request.method} ${url.pathname.replace(/\/[A-Za-z0-9_-]{16,}$/, '/:id')}`,
      status: outcome.reply.status, code: outcome.reply.code, ms: Date.now() - started, install: outcome.install?.slice(0, 6),
    }));
    return outcome.socket ?? respond(outcome.reply);
  },

  async scheduled(_controller, env): Promise<void> {
    if (!configured(env)) {
      console.error(JSON.stringify({ event: 'canary.page', reason: 'not_configured' }));
      return;
    }
    const now = Math.floor(Date.now() / 1000);
    const probes = await Promise.all([probe(env, 'sandbox', now), probe(env, 'production', now)]);
    const streaks = await env.HEALTH.get(env.HEALTH.idFromName('canary')).record(probes);
    for (const result of probes) {
      count(env, result.ok ? 'canary.ok' : 'canary.fail', result.environment);
      if (result.ok) continue;
      const fields = { environment: result.environment, status: result.status, reason: result.reason, streak: streaks[result.environment] };
      // Observability alerts on `canary.page`.
      console.error(JSON.stringify({ event: streaks[result.environment] >= PAGE_AFTER ? 'canary.page' : 'canary.fail', ...fields }));
    }
  },
} satisfies ExportedHandler<Env>;
