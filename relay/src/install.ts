// One SQLite-backed Durable Object per install (idFromName(installId)). Single-threaded per install,
// so a send can't race a revoke. Nonces and rate-limit windows survive eviction in one `state` row,
// so a signed request costs one row write.
import { DurableObject } from 'cloudflare:workers';
import { NONCE_WINDOW, installIdFor, verifyEd25519 } from './auth';
import { b64url, equalBytes, sha256 } from './bytes';
import type { Delivery, Environment, Outcome } from './apns';
import { MAX_DEVICES, activityRequest, alertRequest, challengeRequest, macIDFor, type Send } from './send';
import { Tunnel, type Refusal } from './tunnel';

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export const LIMITS = {
  sendsPerMinute: 60,
  sendsPerDay: 2000,
  testsPerHour: 5,
  phonePerMinute: 30,
  activitiesPerDevice: 4,
  urgentActivityGap: 10_000,
  urgentActivityPerHour: 60,
  challengeGap: 60_000,
  challengesPerHour: 5,
  challengeLifetime: HOUR,
  activityLifetime: 12 * HOUR,
  emptyInstall: 30 * DAY,
  silentInstall: 90 * DAY,
  nonces: 2000,
};

export interface Reply {
  status: number;
  code?: string;
  message?: string;
  retryAfter?: number;
  body?: unknown;
}

export interface Signed {
  message: Uint8Array;   // the signed string
  sig: Uint8Array;
  nonce: string;
  ts: number;
}

// Which app a token belongs to, and which APNs host knows it.
export interface ApnsRoute {
  bundle: string;
  environment: Environment;
}

export interface DeviceInput extends ApnsRoute {
  apnsToken: string;
  secretHash: Uint8Array;
  pushToStartToken?: string;
  appVersion: string;
}

export type MacOp =
  | { op: 'register'; publicKey: Uint8Array; fullFor: number }
  | { op: 'rotate'; newPublicKey: Uint8Array }
  | { op: 'delete' }
  | { op: 'self'; paused: boolean }
  | { op: 'putDevice'; deviceId: string; device: DeviceInput }
  | { op: 'deleteDevice'; deviceId: string }
  | { op: 'send'; send: Send };

export type PhoneOp =
  | { op: 'tokens'; apnsToken?: string; pushToStartToken?: string; route: Partial<ApnsRoute> }
  | { op: 'verify'; challenge: Uint8Array }
  | { op: 'putActivity'; activityId: string; updateToken: string; route: Partial<ApnsRoute> }
  | { op: 'deleteActivity'; activityId: string }
  | { op: 'unpair' };

export type TokenKind = 'device' | 'start' | 'activity' | 'challenge';

export interface Target {
  deviceId: string;
  kind: TokenKind;
  activityId?: string;
  ending?: boolean;
  // A Live Activity token can't be challenged, so it's tied to the proven APNs token that first uses it (src/ledger.ts).
  owner?: string;
  delivery: Delivery;
}

export type DeviceResult =
  | { device: string; result: 'ok'; apnsId?: string }
  | { device: string; result: 'gone'; reason?: string }
  | { device: string; result: 'unverified' }
  | { device: string; result: 'retry'; after: number }
  | { device: string; result: 'rejected'; reason: string };

// A send: what to push, and the devices decided without asking APNs.
export interface Plan {
  targets: Target[];
  results: DeviceResult[];
}

// Anything else: the reply, and a verification push to make when a device brought a new token.
export interface Answer {
  reply: Reply;
  challenge?: Target;
}

export interface Report {
  target: Target;
  outcome: Outcome;
}

interface DeviceRow {
  id: string;
  apns_token: string | null;
  bundle: string;
  environment: Environment;
  gone_reason: string | null;
  secret_hash: ArrayBuffer;
  push_to_start: string | null;
  token_updated: number;
  verified: number;
  challenge_hash: ArrayBuffer | null;
  challenge_route: string | null;
  challenge_sent: number | null;
  [key: string]: SqlStorageValue;
}

interface Window {
  start: number;
  count: number;
  last?: number;
}

interface State {
  nonces: Record<string, number>;
  windows: Record<string, Window>;
}

const buffer = (bytes: Uint8Array) => bytes.slice().buffer as ArrayBuffer;

// The token, app and host a challenge went to. A proof only counts for the route it was sent on.
const routeOf = (device: { apns_token: string | null; bundle: string; environment: string }) =>
  `${device.apns_token} ${device.bundle} ${device.environment}`;

// Made before the object reads its state: see `mac`.
interface Fresh {
  challenge: Uint8Array;
  hash: Uint8Array;
}

async function freshChallenge(): Promise<Fresh> {
  const challenge = crypto.getRandomValues(new Uint8Array(16));
  return { challenge, hash: await sha256(challenge) };
}
const error = (status: number, code: string, message: string, retryAfter?: number): Reply => ({ status, code, message, retryAfter });
const answer = (reply: Reply, challenge?: Target): Answer => ({ reply, challenge });

export class Install extends DurableObject<Env> {
  private readonly tunnel: Tunnel;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.tunnel = new Tunnel(ctx, () => this.exists() ? new Uint8Array(this.install().public_key) : null);
    // Keepalives are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  // The tunnel's WebSocket upgrades, routed by the Worker. Only a registered install tunnels.
  async fetch(request: Request): Promise<Response> {
    const role = new URL(request.url).pathname === '/v1/tunnel/mac' ? 'mac' : 'phone';
    const result: Response | Refusal = this.exists() ? await this.tunnel.accept(request, role)
      : { status: 401, code: 'unauthorized', message: 'Unknown install' };
    if (result instanceof Response) return result;
    const headers: Record<string, string> = result.retryAfter === undefined ? {} : { 'retry-after': String(result.retryAfter) };
    const retryable = result.status === 429 || result.status >= 500;
    return Response.json({ error: { code: result.code, message: result.message, retryable } }, { status: result.status, headers });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    await this.tunnel.message(ws, message);
  }

  async webSocketClose(ws: WebSocket, code: number) {
    this.tunnel.closed(ws);
    try { ws.close(code === 1005 || code === 1006 ? 1000 : code, ''); } catch {}
  }

  async webSocketError(ws: WebSocket) {
    this.tunnel.closed(ws);
  }

  private exists(): boolean {
    return this.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'install'").toArray().length > 0
      && this.sql.exec('SELECT 1 FROM install').toArray().length > 0;
  }

  private createSchema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS install(install_id TEXT, public_key BLOB, created INTEGER, rotated INTEGER,
                                         last_send INTEGER, empty_since INTEGER);
      CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, apns_token TEXT, bundle TEXT, environment TEXT, secret_hash BLOB,
                                         push_to_start TEXT, app_version TEXT, token_updated INTEGER, gone_at INTEGER,
                                         gone_reason TEXT, verified INTEGER, challenge_hash BLOB, challenge_sent INTEGER,
                                         challenge_route TEXT);
      CREATE TABLE IF NOT EXISTS activities(id TEXT PRIMARY KEY, device_id TEXT, update_token TEXT, bundle TEXT,
                                            environment TEXT, created INTEGER);
      CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY, data TEXT);`);
  }

  private install() {
    return this.sql.exec<{ install_id: string; public_key: ArrayBuffer; last_send: number | null }>(
      'SELECT install_id, public_key, last_send FROM install').one();
  }

  private device(id: string): DeviceRow | undefined {
    return this.sql.exec<DeviceRow>('SELECT * FROM devices WHERE id = ?', id).toArray()[0];
  }

  // Expired nonces go before anything counts them, so a full table empties itself as they age.
  private load(now: number): State {
    const row = this.sql.exec<{ data: string }>('SELECT data FROM state WHERE id = 1').toArray()[0];
    const state: State = row ? JSON.parse(row.data) : { nonces: {}, windows: {} };
    for (const [nonce, seen] of Object.entries(state.nonces)) if (seen < now - NONCE_WINDOW * 1000) delete state.nonces[nonce];
    return state;
  }

  private save(state: State, now: number) {
    for (const [key, window] of Object.entries(state.windows)) if (window.start < now - DAY && (window.last ?? 0) < now - HOUR) delete state.windows[key];
    this.sql.exec('INSERT OR REPLACE INTO state VALUES (1, ?)', JSON.stringify(state));
  }

  // A fixed window of `period` from its first event. Returns seconds to wait, or 0 and counts one.
  private take(state: State, key: string, period: number, limit: number, now: number): number {
    let window = state.windows[key];
    if (!window || now - window.start >= period) window = state.windows[key] = { start: now, count: 0, last: window?.last };
    if (window.count >= limit) return Math.max(1, Math.ceil((window.start + period - now) / 1000));
    window.count++;
    return 0;
  }

  // Everything that awaits happens first. From `load` to `save` the object doesn't yield, so a
  // concurrent request can't read the same nonce as unused or write back a stale copy of the state.
  async mac(installId: string, signed: Signed, op: MacOp, now = Date.now()): Promise<Answer | Plan> {
    let publicKey: Uint8Array;
    if (op.op === 'register') {
      if (await installIdFor(op.publicKey) !== installId) return answer(error(400, 'bad_request', 'installId is not derived from publicKey'));
      publicKey = op.publicKey;
    } else {
      if (!this.exists()) return answer(op.op === 'self' ? error(404, 'not_found', 'Unknown install') : error(401, 'unauthorized', 'Unknown install'));
      publicKey = new Uint8Array(this.install().public_key);
    }
    if (!await verifyEd25519(publicKey, signed.sig, signed.message)) return answer(error(401, 'unauthorized', 'Bad signature'));
    const fresh = op.op === 'putDevice' ? await freshChallenge() : undefined;
    const macID = op.op === 'send' ? await macIDFor(installId) : '';

    const known = this.exists();
    if (op.op !== 'register' && !known) return answer(error(401, 'unauthorized', 'Unknown install'));
    if (known && !equalBytes(new Uint8Array(this.install().public_key), publicKey)) {
      return answer(op.op === 'register' ? error(409, 'conflict', 'This install has rotated its key') : error(401, 'unauthorized', 'Bad signature'));
    }
    if (!known && op.op === 'register' && op.fullFor > 0) {
      return answer(error(429, 'rate_limited', 'Too many registrations from this network today', op.fullFor));
    }
    if (!known) {
      this.createSchema();
      this.sql.exec('INSERT INTO install VALUES (?, ?, ?, NULL, NULL, NULL)', installId, buffer(publicKey), now);
    }
    const state = this.load(now);
    if (state.nonces[signed.nonce] !== undefined) return answer(error(401, 'replay', 'Nonce already used'));
    if (Object.keys(state.nonces).length >= LIMITS.nonces) return answer(error(429, 'rate_limited', 'Too many requests', 60));
    state.nonces[signed.nonce] = now;
    const result = this.macOp(state, installId, op, known, now, fresh, macID);
    this.save(state, now);

    if (!known) await this.ctx.storage.setAlarm(now + DAY);
    if (op.op === 'delete') await this.erase();
    return result;
  }

  private macOp(state: State, installId: string, op: MacOp, known: boolean, now: number, fresh: Fresh | undefined, macID: string): Answer | Plan {
    switch (op.op) {
      case 'register':
        return answer({ status: known ? 200 : 201, body: { installId } });
      case 'rotate':
        this.sql.exec('UPDATE install SET public_key = ?, rotated = ?', buffer(op.newPublicKey), now);
        this.tunnel.dropMac();
        return answer({ status: 200, body: { installId } });
      case 'self': {
        // A gone device stays listed until the Mac removes it, but can't be verified.
        const { devices, verified } = this.sql.exec<{ devices: number; verified: number }>(
          'SELECT COUNT(*) AS devices, COUNT(CASE WHEN verified = 1 AND apns_token IS NOT NULL THEN 1 END) AS verified FROM devices').one();
        const activities = this.sql.exec('SELECT COUNT(*) AS n FROM activities').one().n as number;
        const gone = this.sql.exec<{ device: string; reason: string | null }>(
          'SELECT id AS device, gone_reason AS reason FROM devices WHERE apns_token IS NULL ORDER BY gone_at').toArray();
        return answer({ status: 200, body: { registered: true, devices, verified, activities, gone, paused: op.paused } });
      }
      case 'delete':
        return answer({ status: 204 });
      case 'putDevice':
        return this.putDevice(state, installId, op.deviceId, op.device, now, fresh!);
      case 'deleteDevice':
        this.sql.exec('DELETE FROM activities WHERE device_id = ?', op.deviceId);
        this.sql.exec('DELETE FROM devices WHERE id = ?', op.deviceId);
        return answer({ status: 204 });
      case 'send':
        return this.plan(state, op.send, now, macID);
      default:
        return op satisfies never;
    }
  }

  private putDevice(state: State, installId: string, id: string, input: DeviceInput, now: number, fresh: Fresh): Answer {
    const existing = this.device(id);
    if (!existing && this.sql.exec('SELECT COUNT(*) AS n FROM devices').one().n as number >= MAX_DEVICES) {
      return answer(error(409, 'too_many_devices', `An install has at most ${MAX_DEVICES} devices`));
    }
    // The proof was for one token at one app and host; moving any of them needs a new one.
    const sameToken = existing?.apns_token === input.apnsToken && existing.bundle === input.bundle && existing.environment === input.environment;
    this.sql.exec(
      `INSERT OR REPLACE INTO devices(id, apns_token, bundle, environment, secret_hash, push_to_start, app_version, token_updated,
                                      gone_at, gone_reason, verified, challenge_hash, challenge_sent, challenge_route)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?)`,
      id, input.apnsToken, input.bundle, input.environment, buffer(input.secretHash), input.pushToStartToken ?? null, input.appVersion,
      sameToken ? existing!.token_updated : now, sameToken ? existing!.verified : 0,
      sameToken ? existing!.challenge_hash : null, sameToken ? existing!.challenge_sent : null, sameToken ? existing!.challenge_route : null);
    // Activity tokens were reported under the old proof or the old pairing.
    const samePairing = existing !== undefined && equalBytes(new Uint8Array(existing.secret_hash), input.secretHash);
    if (!sameToken || !samePairing) this.sql.exec('DELETE FROM activities WHERE device_id = ?', id);
    const verified = sameToken && existing!.verified === 1;
    const challenge = verified ? undefined : this.challenge(state, installId, id, now, fresh);
    return answer({ status: existing ? 200 : 201, body: { verified } }, challenge);
  }

  // A device only receives pushes once the phone has proved it holds the token: the relay sends a
  // random challenge to the token as a silent push and the phone posts it back with its bearer.
  // Otherwise anyone could register a token they'd seen under an install of their own.
  private challenge(state: State, installId: string, deviceId: string, now: number, fresh: Fresh): Target | undefined {
    const device = this.device(deviceId);
    if (!device?.apns_token || device.verified) return undefined;
    if (device.challenge_sent && now - device.challenge_sent < LIMITS.challengeGap) return undefined;
    if (this.take(state, `challenge:${deviceId}`, HOUR, LIMITS.challengesPerHour, now)) return undefined;
    this.sql.exec('UPDATE devices SET challenge_hash = ?, challenge_sent = ?, challenge_route = ? WHERE id = ?',
      buffer(fresh.hash), now, routeOf(device), deviceId);
    return {
      deviceId, kind: 'challenge',
      delivery: {
        token: device.apns_token, environment: device.environment, canFlip: true,
        request: challengeRequest(installId, deviceId, b64url(fresh.challenge), device.bundle),
      },
    };
  }

  // Priority 10 for one activity at most once per 10 s and 60 times an hour; beyond that, 5.
  private activityPriority(state: State, key: string, wanted: 5 | 10, now: number): 5 | 10 {
    if (wanted === 5) return 5;
    const last = state.windows[key]?.last ?? 0;
    if (now - last < LIMITS.urgentActivityGap || this.take(state, key, HOUR, LIMITS.urgentActivityPerHour, now)) return 5;
    state.windows[key].last = now;
    return 10;
  }

  private plan(state: State, send: Send, now: number, macID: string): Answer | Plan {
    const wait = this.take(state, 'send.minute', MINUTE, LIMITS.sendsPerMinute, now)
      || this.take(state, 'send.day', DAY, LIMITS.sendsPerDay, now);
    if (wait) return answer(error(429, 'rate_limited', 'Too many sends', wait));
    if (send.kind === 'alert' && send.category === 'TEST') {
      const test = this.take(state, 'send.test', HOUR, LIMITS.testsPerHour, now);
      if (test) return answer(error(429, 'rate_limited', 'Too many test pushes this hour', test));
    }
    const { install_id: installId } = this.install();
    const seconds = Math.floor(now / 1000);
    const plan: Plan = { targets: [], results: [] };
    // The privacy page promises activity tokens last 12 hours; the daily alarm alone would keep them up to 36.
    const activitiesFrom = now - LIMITS.activityLifetime;
    if (send.kind === 'liveactivity' && send.event !== 'start') this.sql.exec('DELETE FROM activities WHERE created <= ?', activitiesFrom);
    for (const deviceId of send.devices) {
      const device = this.device(deviceId);
      if (!device || !device.apns_token) {
        plan.results.push({ device: deviceId, result: 'gone' });
      } else if (!device.verified) {
        plan.results.push({ device: deviceId, result: 'unverified' });
      } else if (send.kind !== 'liveactivity') {
        plan.targets.push({
          deviceId, kind: 'device',
          delivery: { token: device.apns_token, environment: device.environment, request: alertRequest(send, deviceId, seconds, device.bundle), canFlip: true },
        });
      } else if (send.event === 'start') {
        if (!device.push_to_start) plan.results.push({ device: deviceId, result: 'rejected', reason: 'NoPushToStartToken' });
        else plan.targets.push({
          deviceId, kind: 'start', owner: device.apns_token,
          delivery: {
            token: device.push_to_start, environment: device.environment, canFlip: false,
            request: activityRequest(send, this.activityPriority(state, `urgent:start:${deviceId}`, send.priority, now), macID, seconds, device.bundle),
          },
        });
      } else {
        const activity = this.sql.exec<{ update_token: string; bundle: string; environment: Environment }>(
          'SELECT update_token, bundle, environment FROM activities WHERE id = ? AND device_id = ? AND created > ?',
          send.activityId!, deviceId, activitiesFrom).toArray()[0];
        if (!activity) plan.results.push({ device: deviceId, result: 'gone' });
        else plan.targets.push({
          deviceId, kind: 'activity', activityId: send.activityId, ending: send.event === 'end', owner: device.apns_token,
          delivery: {
            token: activity.update_token, environment: activity.environment, canFlip: false,
            request: activityRequest(send, this.activityPriority(state, `urgent:activity:${send.activityId}`, send.priority, now), macID, seconds,
              activity.bundle),
          },
        });
      }
    }
    return plan;
  }

  // What APNs said: successes (for the 90-day cleanup), gone tokens and environment flips.
  async settle(reports: Report[], now = Date.now()) {
    if (!this.exists()) return;
    const { last_send: lastSend } = this.install();
    // A day's precision is all the cleanup needs; don't write a row per push for it.
    if (reports.some(({ target, outcome }) => outcome.result === 'ok' && target.kind !== 'challenge') && now - (lastSend ?? 0) > DAY) {
      this.sql.exec('UPDATE install SET last_send = ?', now);
    }
    for (const { target, outcome } of reports) {
      const { deviceId, kind, delivery } = target;
      if (outcome.result === 'ok' && outcome.environment) {
        this.sql.exec('UPDATE devices SET environment = ? WHERE id = ? AND apns_token = ?', outcome.environment, deviceId, delivery.token);
      }
      if (outcome.result === 'ok' && target.ending) {
        this.sql.exec('DELETE FROM activities WHERE id = ? AND update_token = ?', target.activityId!, delivery.token);
      }
      if (outcome.result !== 'gone') continue;
      // A phone that registered again after APNs's 410 keeps its new token.
      const before = outcome.timestamp ?? now + 1;
      if (kind === 'activity') {
        this.sql.exec('DELETE FROM activities WHERE id = ? AND update_token = ? AND created < ?', target.activityId!, delivery.token, before);
      } else if (kind === 'start') {
        this.sql.exec('UPDATE devices SET push_to_start = NULL WHERE id = ? AND push_to_start = ? AND token_updated < ?', deviceId, delivery.token, before);
      } else {
        this.sql.exec('UPDATE devices SET apns_token = NULL, gone_at = ?, gone_reason = ? WHERE id = ? AND apns_token = ? AND token_updated < ?',
          now, outcome.reason, deviceId, delivery.token, before);
      }
    }
  }

  // As in `mac`: the awaits first, then read, change and save the state without yielding.
  async phone(deviceId: string, secretHash: Uint8Array, op: PhoneOp, now = Date.now()): Promise<Answer> {
    const fresh = op.op === 'tokens' ? await freshChallenge() : undefined;
    const proof = op.op === 'verify' ? await sha256(op.challenge) : undefined;
    const device = this.exists() ? this.device(deviceId) : undefined;
    if (!device || !equalBytes(new Uint8Array(device.secret_hash), secretHash)) return answer(error(401, 'unauthorized', 'Unknown device'));
    const state = this.load(now);
    const wait = this.take(state, `phone:${deviceId}`, MINUTE, LIMITS.phonePerMinute, now);
    const result = wait ? answer(error(429, 'rate_limited', 'Too many requests this minute', wait)) : this.phoneOp(state, device, op, now, fresh, proof);
    this.save(state, now);
    return result;
  }

  private phoneOp(state: State, device: DeviceRow, op: PhoneOp, now: number, fresh?: Fresh, proof?: Uint8Array): Answer {
    const deviceId = device.id;
    switch (op.op) {
      case 'tokens': {
        const bundle = op.route.bundle ?? device.bundle;
        const environment = op.route.environment ?? device.environment;
        const newToken = (op.apnsToken !== undefined && op.apnsToken !== device.apns_token)
          || bundle !== device.bundle || environment !== device.environment;
        this.sql.exec(
          `UPDATE devices SET apns_token = COALESCE(?1, apns_token),
                              push_to_start = CASE WHEN ?6 THEN ?2 ELSE COALESCE(?2, push_to_start) END, bundle = ?3,
                              environment = ?4, token_updated = ?5,
                              gone_at = CASE WHEN ?6 THEN NULL ELSE gone_at END, gone_reason = CASE WHEN ?6 THEN NULL ELSE gone_reason END,
                              verified = CASE WHEN ?6 THEN 0 ELSE verified END, challenge_hash = CASE WHEN ?6 THEN NULL ELSE challenge_hash END,
                              challenge_sent = CASE WHEN ?6 THEN NULL ELSE challenge_sent END,
                              challenge_route = CASE WHEN ?6 THEN NULL ELSE challenge_route END
           WHERE id = ?7`,
          op.apnsToken ?? null, op.pushToStartToken ?? null, bundle, environment, now, newToken ? 1 : 0, deviceId);
        // Live Activity tokens hang off the proof, so they go with it; the Mac's next registration brings push-to-start back.
        if (newToken) this.sql.exec('DELETE FROM activities WHERE device_id = ?', deviceId);
        // The old token's challenge dies with it, so the next one goes out at once.
        const challenge = newToken ? this.challenge(state, this.install().install_id, deviceId, now, fresh!) : undefined;
        return answer({ status: 200, body: { verified: !newToken && device.verified === 1 } }, challenge);
      }
      case 'verify': {
        const expected = device.challenge_hash && new Uint8Array(device.challenge_hash);
        const current = device.challenge_sent !== null && now - device.challenge_sent < LIMITS.challengeLifetime
          && device.challenge_route === routeOf(device);
        if (!expected || !current || !equalBytes(expected, proof!)) {
          return answer(error(403, 'bad_challenge', 'Challenge is wrong or expired'));
        }
        this.sql.exec('UPDATE devices SET verified = 1, challenge_hash = NULL, challenge_sent = NULL, challenge_route = NULL WHERE id = ?', deviceId);
        return answer({ status: 204 });
      }
      case 'putActivity': {
        const owner = this.sql.exec<{ device_id: string }>('SELECT device_id FROM activities WHERE id = ?', op.activityId).toArray()[0];
        if (owner && owner.device_id !== deviceId) return answer(error(409, 'conflict', 'Activity belongs to another device'));
        if (!device.verified || !device.apns_token) return answer(error(403, 'unverified', 'Prove the device\'s push token first'));
        // Started by the same app as the device's own token, unless the phone says otherwise.
        this.sql.exec('INSERT OR REPLACE INTO activities(id, device_id, update_token, bundle, environment, created) VALUES (?, ?, ?, ?, ?, ?)',
          op.activityId, deviceId, op.updateToken, op.route.bundle ?? device.bundle, op.route.environment ?? device.environment, now);
        this.sql.exec(
          `DELETE FROM activities WHERE device_id = ? AND id NOT IN
             (SELECT id FROM activities WHERE device_id = ? ORDER BY created DESC LIMIT ?)`,
          deviceId, deviceId, LIMITS.activitiesPerDevice);
        return answer({ status: 204 });
      }
      case 'deleteActivity':
        this.sql.exec('DELETE FROM activities WHERE id = ? AND device_id = ?', op.activityId, deviceId);
        return answer({ status: 204 });
      case 'unpair':
        this.sql.exec('DELETE FROM activities WHERE device_id = ?', deviceId);
        this.sql.exec('DELETE FROM devices WHERE id = ?', deviceId);
        this.tunnel.forget(deviceId);
        return answer({ status: 204 });
    }
  }

  async alarm() {
    const now = Date.now();
    if (!this.exists()) return;
    const nextPairingEnd = this.tunnel.sweepPairing(now);
    this.sql.exec('DELETE FROM activities WHERE created < ?', now - LIMITS.activityLifetime);
    const { created, last_send: lastSend, empty_since: emptySince } = this.sql.exec<{ created: number; last_send: number | null; empty_since: number | null }>(
      'SELECT created, last_send, empty_since FROM install').one();
    // A Mac that only tunnels is as alive as one that sends.
    const lastUsed = Math.max(lastSend ?? created, this.tunnel.lastUsed() ?? 0);
    const live = (this.sql.exec('SELECT COUNT(*) AS n FROM devices WHERE apns_token IS NOT NULL').one().n as number) + this.tunnel.devices();
    if (now - lastUsed > LIMITS.silentInstall || (!live && emptySince !== null && now - emptySince > LIMITS.emptyInstall)) {
      await this.erase();
      return;
    }
    if (!live && emptySince === null) this.sql.exec('UPDATE install SET empty_since = ?', now);
    if (live && emptySince !== null) this.sql.exec('UPDATE install SET empty_since = NULL');
    await this.ctx.storage.setAlarm(Math.min(now + DAY, nextPairingEnd ?? Infinity));
  }

  private async erase() {
    this.tunnel.dropAll();
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }
}
