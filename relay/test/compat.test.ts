// The requests Side A 0.5.43 and Remote Build 11 already make, byte for byte in shape. They can't be changed from
// here, so nothing in the relay may stop answering them. Sources/SideA/Remote/RelayClient.swift, TunnelClient.swift,
// apps/ios/SideARemote/Live/PushRegistrar.swift, apps/ios/Linked/Revocations.swift and RelayBridge.swift send these.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { b64url, sha256 } from '../src/bytes';
import { FRAME, frame, parseFrame } from '../src/tunnel';
import { BASE, FakeApns, call, hexToken, newMac, newPhone, phoneCall, signed } from './helpers';

afterEach(() => vi.restoreAllMocks());

const BUNDLE = 'com.arnenoori.sidea.remote';
const upgrade = { upgrade: 'websocket' };

async function macPutsDevice(mac: Awaited<ReturnType<typeof newMac>>, phone: ReturnType<typeof newPhone>, push = true) {
  return call(await signed(mac, 'PUT', `/v1/devices/${phone.deviceId}`, {
    apnsToken: phone.apnsToken, bundleID: BUNDLE, apnsEnvironment: 'production', secretHash: b64url(await sha256(phone.secret)),
    ...(push ? { pushToStartToken: phone.pushToStartToken } : {}), appVersion: '0.5.43 (11)',
  }));
}

const registerMac = async (mac: Awaited<ReturnType<typeof newMac>>, ip: string) =>
  call(await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }, { headers: { 'cf-connecting-ip': ip } }));

function receiver(ws: WebSocket) {
  const messages: (string | ArrayBuffer)[] = [];
  let reading = Promise.resolve();
  ws.accept();
  ws.addEventListener('message', event => {
    const data = event.data as string | ArrayBuffer | Blob;
    reading = reading.then(async () => { messages.push(data instanceof Blob ? await data.arrayBuffer() : data); });
  });
  const until = async <T>(find: () => T | undefined) => {
    for (const deadline = Date.now() + 10_000; Date.now() < deadline;) {
      const found = find();
      if (found !== undefined) return found;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    throw new Error('nothing arrived');
  };
  return { ws, messages, until };
}

describe('a Mac on 0.5.43 and a phone on Build 11', () => {
  it('register, prove, push, start a Live Activity, refresh and forget', async () => {
    const apns = new FakeApns();
    const mac = await newMac();
    const ip = '203.0.113.40';
    expect((await registerMac(mac, ip)).status).toBe(201);
    expect((await registerMac(mac, ip)).status).toBe(200);

    const phone = newPhone(mac);
    const put = await macPutsDevice(mac, phone);
    expect(put.status).toBe(201);
    expect(await put.json()).toEqual({ verified: false });
    const challenge = apns.last(phone.apnsToken)!.body.verify.challenge;
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge })).status).toBe(204);
    expect(await (await macPutsDevice(mac, phone)).json()).toEqual({ verified: true });

    const start = await call(await signed(mac, 'POST', '/v1/send', {
      devices: [phone.deviceId], kind: 'liveactivity', event: 'start', contentState: { working: 2, waiting: 1 }, priority: 10,
      staleDate: Math.floor(Date.now() / 1000) + 3600,
    }));
    expect(await start.json()).toMatchObject({ results: [{ device: phone.deviceId, result: 'ok' }] });
    expect(apns.last(phone.pushToStartToken)).toBeTruthy();

    // PushRegistrar.report: the device token alone, then the Mac's own registration brings push-to-start back.
    const next = hexToken();
    const refreshed = await phoneCall(phone, 'PUT', '/v1/device/tokens', { apnsToken: next, bundleID: BUNDLE, apnsEnvironment: 'production' });
    expect(refreshed.status).toBe(200);
    expect(await refreshed.json()).toEqual({ verified: false });
    const moved = { ...phone, apnsToken: next };
    await macPutsDevice(mac, moved);
    const proof = apns.last(next)!.body.verify.challenge;
    expect((await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: proof })).status).toBe(204);
    const self = await call(await signed(mac, 'GET', '/v1/installs/self'));
    expect(await self.json()).toMatchObject({ registered: true, devices: 1, verified: 1 });

    // Revocations.relayForget treats 2xx, 401 and 404 as done.
    expect((await phoneCall(phone, 'DELETE', '/v1/device')).status).toBe(204);
    expect((await phoneCall(phone, 'DELETE', '/v1/device')).status).toBe(401);
  });

  it('keep a re-registering Mac working after its network has spent the day\'s new installs', async () => {
    const ip = '203.0.113.41';
    const mac = await newMac();
    expect((await registerMac(mac, ip)).status).toBe(201);
    const worker = (await import('../src/index')).default;
    const { env } = await import('cloudflare:test');
    const { context, incoming } = await import('./helpers');
    const open = { ...env, REGISTER_LIMIT: { limit: async () => ({ success: true }) } } as unknown as Env;
    let last = 0;
    for (let i = 0; i < 50; i++) {
      const other = await newMac();
      const request = await signed(other, 'POST', '/v1/installs', { publicKey: b64url(other.publicKey) }, { headers: { 'cf-connecting-ip': ip } });
      last = (await worker.fetch(incoming(request), open, context)).status;
    }
    expect(last).toBe(429);
    const again = await signed(mac, 'POST', '/v1/installs', { publicKey: b64url(mac.publicKey) }, { headers: { 'cf-connecting-ip': ip } });
    expect((await worker.fetch(incoming(again), open, context)).status).toBe(200);
  });

  it('tunnel a stream both ways with the Mac\'s device list and frames', async () => {
    const mac = await newMac();
    await registerMac(mac, '203.0.113.42');
    const macSocket = await call(await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade }));
    expect(macSocket.status).toBe(101);
    const macEnd = receiver(macSocket.webSocket!);
    const phone = newPhone(mac);
    macEnd.ws.send(JSON.stringify({ type: 'devices', devices: [{ id: phone.deviceId, secretHash: b64url(await sha256(phone.secret)) }] }));
    macEnd.ws.send(frame(FRAME.data, (0xffff << 16 | 1) >>> 0));
    await macEnd.until(() => macEnd.messages.find(m => typeof m !== 'string' && parseFrame(m)!.type === FRAME.reset));

    const phoneSocket = await call(new Request(`${BASE}/v1/tunnel/phone`, { headers: { ...upgrade, authorization: phone.bearer } }));
    expect(phoneSocket.status).toBe(101);
    const phoneEnd = receiver(phoneSocket.webSocket!);
    await phoneEnd.until(() => phoneEnd.messages.find(m => typeof m === 'string' && JSON.parse(m).type === 'mac'));
    phoneEnd.ws.send(frame(FRAME.open, 1));
    const open = await macEnd.until(() => macEnd.messages.map(m => typeof m === 'string' ? null : parseFrame(m)!).find(f => f?.type === FRAME.open));
    expect(JSON.parse(new TextDecoder().decode(open!.payload))).toEqual({ device: phone.deviceId });

    const payload = crypto.getRandomValues(new Uint8Array(1024));
    for (let i = 0; i < 200; i++) macEnd.ws.send(frame(FRAME.data, open!.stream, payload));
    await phoneEnd.until(() => phoneEnd.messages.filter(m => typeof m !== 'string' && parseFrame(m)!.type === FRAME.data).length === 200 ? true : undefined);
  });

  it('pair over the relay with the right ticket, whatever wrong tickets came first', async () => {
    const mac = await newMac();
    await registerMac(mac, '203.0.113.43');
    const macEnd = receiver((await call(await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade }))).webSocket!);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    macEnd.ws.send(JSON.stringify({ type: 'pairing', ticketHash: b64url(await sha256(ticket)), expiresAt: Date.now() / 1000 + 300 }));
    macEnd.ws.send(frame(FRAME.data, (0xffff << 16 | 2) >>> 0));
    await macEnd.until(() => macEnd.messages.find(m => typeof m !== 'string' && parseFrame(m)!.type === FRAME.reset));
    const pair = (bytes: Uint8Array) => call(new Request(`${BASE}/v1/tunnel/phone`, { headers: { ...upgrade, authorization: `SideA-Pair ${mac.installId}.${b64url(bytes)}` } }));
    for (let i = 0; i < 25; i++) expect((await pair(crypto.getRandomValues(new Uint8Array(16)))).status).toBe(403);
    expect((await pair(ticket)).status).toBe(101);
  });
});
