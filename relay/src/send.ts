// What the Mac may ask for, and the only APNs payloads the relay builds from it. The Mac never
// sends an `aps` dictionary or any visible text.
import { ID } from './auth';
import { b64url, fromB64url, sha256 } from './bytes';

export const MAX_DEVICES = 10;
export const MAX_SEALED = 3000;
export const MAX_APNS_PAYLOAD = 4096;

// The App Store app. A token belongs to one app and one APNs environment, so each registration says
// which; the topic is that bundle id, plus a suffix for Live Activities.
export const DEFAULT_BUNDLE = 'com.arnenoori.sidea.remote';
export const DEFAULT_BUNDLES = [DEFAULT_BUNDLE, `${DEFAULT_BUNDLE}.dev`];
const activityTopic = (bundle: string) => `${bundle}.push-type.liveactivity`;

// Shown when the Notification Service Extension can't run; the words live in the app's
// Localizable.strings.
export const FALLBACK: Record<string, string> = {
  REQUEST: 'PUSH_REQUEST_FALLBACK',
  REQUEST_DESTRUCTIVE: 'PUSH_REQUEST_FALLBACK',
  QUESTION: 'PUSH_QUESTION_FALLBACK',
  PLAN: 'PUSH_PLAN_FALLBACK',
  FINISHED: 'PUSH_FINISHED_FALLBACK',
  LIMIT: 'PUSH_LIMIT_FALLBACK',
  HEALTH: 'PUSH_HEALTH_FALLBACK',
  ROTATION: 'PUSH_ROTATION_FALLBACK',
  TEST: 'PUSH_TEST_FALLBACK',
};
export const ANSWERED = 'PUSH_ANSWERED';
const LEVELS = ['passive', 'active', 'time-sensitive'];
// A stuck session and setup's Test Connection are worth showing, never worth interrupting for.
const PASSIVE = ['HEALTH', 'TEST'];
const OPAQUE = /^[A-Za-z0-9_-]{1,64}$/;   // collapse, request and activity ids: random, short

interface Common {
  devices: string[];
  priority: 5 | 10;
  expiresIn: number;
}

export interface Alert extends Common {
  kind: 'alert';
  category: string;
  collapseId: string;
  sound: boolean;
  level: string;
  sealed: Record<string, string>;   // per device: the AAD binds each envelope to one deviceId
}

export interface Dismiss extends Common {
  kind: 'dismiss';
  collapseId: string;
}

export interface ContentState {
  working: number;
  waiting: number;
  topRequest?: string | null;
  soonestReset?: number | null;   // passed through as the Mac encodes it for ActivityKit
  tightestPercent?: number | null;
}

export interface LiveActivity extends Common {
  kind: 'liveactivity';
  event: 'start' | 'update' | 'end';
  activityId?: string;
  contentState: ContentState;
  staleDate?: number;
  dismissalDate?: number;
  relevance?: number;
}

export type Send = Alert | Dismiss | LiveActivity;

export class Invalid extends Error {}

function fail(message: string): never {
  throw new Invalid(message);
}
const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const isCount = (value: unknown, max = 10_000) => Number.isInteger(value) && (value as number) >= 0 && (value as number) <= max;
const isTime = (value: unknown) => isCount(value, 2 ** 32);

function only(value: Record<string, unknown>, keys: string[], what: string) {
  for (const key of Object.keys(value)) if (!keys.includes(key)) fail(`${what}: unknown field ${key}`);
}

function sealedEnvelope(value: unknown): string {
  if (typeof value !== 'string' || value.length > MAX_SEALED) return fail('sealed: too long or not a string');
  const bytes = fromB64url(value);
  // 0x02 ‖ keyId(4) ‖ nonce(12) ‖ ciphertext ‖ tag(16). Version 1's AAD joined its fields bare; phones refuse it.
  if (!bytes || bytes.length < 1 + 4 + 12 + 1 + 16 || bytes[0] !== 0x02) fail('sealed: not a v2 envelope');
  return value;
}

function contentState(value: unknown): ContentState {
  if (!isObject(value)) return fail('contentState: not an object');
  only(value, ['working', 'waiting', 'topRequest', 'soonestReset', 'tightestPercent'], 'contentState');
  const { working, waiting, topRequest, soonestReset, tightestPercent } = value;
  if (!isCount(working) || !isCount(waiting)) fail('contentState: working and waiting are counts');
  if (topRequest != null && (typeof topRequest !== 'string' || !OPAQUE.test(topRequest))) fail('contentState: topRequest is an opaque id');
  if (soonestReset != null && (typeof soonestReset !== 'number' || !Number.isFinite(soonestReset))) fail('contentState: soonestReset is a number');
  if (tightestPercent != null && !isCount(tightestPercent, 100)) fail('contentState: tightestPercent is 0-100');
  return value as unknown as ContentState;
}

export function parseSend(value: unknown): Send {
  if (!isObject(value)) return fail('body: not an object');
  const { devices, kind } = value;
  if (!Array.isArray(devices) || devices.length === 0 || devices.length > MAX_DEVICES) fail(`devices: 1 to ${MAX_DEVICES}`);
  if (!(devices as unknown[]).every(id => typeof id === 'string' && ID.test(id))) fail('devices: not device ids');
  if (new Set(devices).size !== (devices as string[]).length) fail('devices: duplicates');
  const priority = value.priority ?? (kind === 'alert' ? 10 : 5);
  if (priority !== 5 && priority !== 10) fail('priority: 5 or 10');
  const expiresIn = value.expiresIn ?? 3600;
  if (!isCount(expiresIn, 86_400)) fail('expiresIn: 0 to 86400 seconds');
  const common = { devices: devices as string[], priority: priority as 5 | 10, expiresIn: expiresIn as number };

  if (kind === 'alert') {
    only(value, ['devices', 'kind', 'category', 'collapseId', 'priority', 'expiresIn', 'sound', 'level', 'sealed'], 'alert');
    const { category, collapseId, sound = true, level = 'active', sealed } = value;
    if (typeof category !== 'string' || !Object.hasOwn(FALLBACK, category)) fail('category: unknown');
    if (typeof collapseId !== 'string' || !OPAQUE.test(collapseId)) fail('collapseId: an opaque id up to 64 characters');
    if (typeof sound !== 'boolean') fail('sound: a boolean');
    if (typeof level !== 'string' || !LEVELS.includes(level)) fail('level: passive, active or time-sensitive');
    if (!isObject(sealed)) return fail('sealed: an object of device id to envelope');
    only(sealed, common.devices, 'sealed');
    const envelopes: Record<string, string> = {};
    for (const id of common.devices) envelopes[id] = sealedEnvelope(sealed[id]);
    return { ...common, kind, category: category as string, collapseId: collapseId as string, sound, level: level as string, sealed: envelopes };
  }
  if (kind === 'dismiss') {
    only(value, ['devices', 'kind', 'collapseId', 'priority', 'expiresIn'], 'dismiss');
    if (typeof value.collapseId !== 'string' || !OPAQUE.test(value.collapseId)) fail('collapseId: an opaque id up to 64 characters');
    return { ...common, kind, collapseId: value.collapseId as string };
  }
  if (kind === 'liveactivity') {
    only(value, ['devices', 'kind', 'event', 'activityId', 'contentState', 'staleDate', 'dismissalDate', 'relevance', 'priority', 'expiresIn'], 'liveactivity');
    const { event, activityId, staleDate, dismissalDate, relevance } = value;
    if (event !== 'start' && event !== 'update' && event !== 'end') fail('event: start, update or end');
    if (event !== 'start' && (typeof activityId !== 'string' || !OPAQUE.test(activityId))) fail('activityId: required for update and end');
    if (event === 'start' && activityId !== undefined) fail('activityId: the phone reports it after a start');
    if (staleDate !== undefined && !isTime(staleDate)) fail('staleDate: unix seconds');
    if (dismissalDate !== undefined && !isTime(dismissalDate)) fail('dismissalDate: unix seconds');
    if (relevance !== undefined && !isCount(relevance, 100)) fail('relevance: 0-100');
    return {
      ...common, kind, event: event as LiveActivity['event'], activityId: activityId as string | undefined,
      contentState: contentState(value.contentState), staleDate: staleDate as number | undefined,
      dismissalDate: dismissalDate as number | undefined, relevance: relevance as number | undefined,
    };
  }
  return fail('kind: alert, dismiss or liveactivity');
}

export interface ApnsRequest {
  pushType: 'alert' | 'liveactivity' | 'background';
  topic: string;
  priority: 5 | 10;
  expiration: number;
  collapseId?: string;
  payload: string;
}

export function alertRequest(send: Alert | Dismiss, deviceId: string, now: number, bundle = DEFAULT_BUNDLE): ApnsRequest {
  const aps: Record<string, unknown> = send.kind === 'alert'
    ? {
        alert: { 'loc-key': FALLBACK[send.category] },
        'mutable-content': 1,
        category: send.category,
        ...(send.sound ? { sound: 'default' } : {}),
        'interruption-level': PASSIVE.includes(send.category) ? 'passive' : send.level,
      }
    : { alert: { 'loc-key': ANSWERED }, category: 'ANSWERED', 'interruption-level': 'passive' };
  const body = send.kind === 'alert' ? { aps, e: send.sealed[deviceId] } : { aps };
  return {
    pushType: 'alert', topic: bundle, priority: send.priority, collapseId: send.collapseId,
    expiration: send.expiresIn ? now + send.expiresIn : 0, payload: JSON.stringify(body),
  };
}

// The only identity a Live Activity's plaintext attributes carry; the phone computes the same.
export const macIDFor = async (installId: string) => b64url((await sha256(`SideA macID v1\n${installId}`)).slice(0, 12));

export function activityRequest(send: LiveActivity, priority: 5 | 10, macID: string, now: number, bundle: string): ApnsRequest {
  const aps: Record<string, unknown> = { timestamp: now, event: send.event, 'content-state': send.contentState };
  if (send.staleDate !== undefined) aps['stale-date'] = send.staleDate;
  if (send.dismissalDate !== undefined) aps['dismissal-date'] = send.dismissalDate;
  if (send.relevance !== undefined) aps['relevance-score'] = send.relevance;
  if (send.event === 'start') {
    aps['attributes-type'] = 'MacActivityAttributes';
    aps.attributes = { macID };
    aps.alert = { title: { 'loc-key': 'ACTIVITY_START_TITLE' }, body: { 'loc-key': 'ACTIVITY_START_BODY' } };
  }
  return {
    pushType: 'liveactivity', topic: activityTopic(bundle), priority,
    expiration: send.expiresIn ? now + send.expiresIn : 0, payload: JSON.stringify({ aps }),
  };
}

// The silent push that proves a phone holds a token: the app posts `challenge` back to
// POST /v1/device/verify. Background pushes must go at priority 5.
export function challengeRequest(installId: string, deviceId: string, challenge: string, bundle: string): ApnsRequest {
  return {
    pushType: 'background', topic: bundle, priority: 5, expiration: 0,
    payload: JSON.stringify({ aps: { 'content-available': 1 }, verify: { install: installId, device: deviceId, challenge } }),
  };
}
