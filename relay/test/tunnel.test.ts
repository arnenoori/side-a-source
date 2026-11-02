import { env, runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { b64url, sha256, utf8 } from '../src/bytes';
import { CLOSE, FRAME, TUNNEL, Tunnel, frame, parseFrame, take } from '../src/tunnel';
import { BASE, type Mac, type Phone, call, context, incoming, newMac, newPhone, randomId, register, signed } from './helpers';

afterEach(() => vi.restoreAllMocks());

// One end of a tunnel socket, as the Mac or the phone holds it.
class End {
  messages: (string | ArrayBuffer)[] = [];
  closed?: { code: number; reason: string };
  constructor(readonly ws: WebSocket) {
    ws.accept();
    // The test's own end gets Blobs; kept in order while they're read.
    let reading = Promise.resolve();
    ws.addEventListener('message', event => {
      const data = event.data as string | ArrayBuffer | Blob;
      reading = reading.then(async () => { this.messages.push(data instanceof Blob ? await data.arrayBuffer() : data); });
    });
    ws.addEventListener('close', event => { this.closed = { code: event.code, reason: event.reason }; });
  }

  send(data: string | Uint8Array) { this.ws.send(data); }

  async until<T>(find: () => T | undefined, what: string): Promise<T> {
    // A deadline, not a count of polls: under load each 5 ms wait can take far longer.
    for (const deadline = Date.now() + 10_000; Date.now() < deadline;) {
      const found = find();
      if (found !== undefined) return found;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    throw new Error(`never got ${what}; have ${JSON.stringify(this.messages.map(m => typeof m === 'string' ? m : `[${m.byteLength}]`))}`);
  }

  control(type: string) {
    return this.until(() => this.messages.filter(m => typeof m === 'string').map(m => JSON.parse(m as string)).find(m => m.type === type), type);
  }

  // Takes the frame so the next call finds the one after it.
  frame(type?: number) {
    return this.until(() => {
      const index = this.messages.findIndex(m => typeof m !== 'string' && (type === undefined || parseFrame(m)!.type === type));
      if (index < 0) return undefined;
      return parseFrame(this.messages.splice(index, 1)[0] as ArrayBuffer)!;
    }, `frame ${type}`);
  }

  closing() { return this.until(() => this.closed, 'close'); }

  // For the Mac's end: returns once the object has handled everything this end sent before it. The object takes a
  // socket's messages in order and answers a frame for a slot no phone holds with a reset, so that reset is the proof.
  async processed() {
    const probe = (0xffff << 16 | Math.floor(Math.random() * 0xffff) + 1) >>> 0;
    this.send(frame(FRAME.data, probe));
    await this.until(() => {
      const index = this.messages.findIndex(m => typeof m !== 'string' && parseFrame(m)!.type === FRAME.reset && parseFrame(m)!.stream === probe);
      return index < 0 ? undefined : this.messages.splice(index, 1);
    }, 'the barrier\'s reset');
  }
}

const upgrade = { upgrade: 'websocket' };

async function connectMac(mac: Mac, options: { nonce?: string } = {}) {
  const response = await call(await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade, nonce: options.nonce }));
  return { response, end: response.webSocket ? new End(response.webSocket) : undefined };
}

async function connectPhone(authorization: string) {
  const response = await call(new Request(BASE + '/v1/tunnel/phone', { headers: { ...upgrade, authorization } }));
  return { response, end: response.webSocket ? new End(response.webSocket) : undefined };
}

const deviceList = async (...phones: Phone[]) =>
  JSON.stringify({ type: 'devices', devices: await Promise.all(phones.map(async phone => ({ id: phone.deviceId, secretHash: b64url(await sha256(phone.secret)) }))) });

async function tunnel(phones = 1) {
  const mac = await newMac();
  await register(mac);
  const { end: macEnd } = await connectMac(mac);
  const list = Array.from({ length: phones }, () => newPhone(mac));
  macEnd!.send(await deviceList(...list));
  await macEnd!.processed();
  return { mac, macEnd: macEnd!, phones: list };
}

describe('the Mac socket', () => {
  it('needs a registered install and a fresh signature', async () => {
    const mac = await newMac();
    expect((await connectMac(mac)).response.status).toBe(401);
    await register(mac);
    const nonce = randomId();
    expect((await connectMac(mac, { nonce })).response.status).toBe(101);
    const replay = await connectMac(mac, { nonce });
    expect(replay.response.status).toBe(401);
    expect((await replay.response.json() as any).error.code).toBe('replay');
    const skewed = await call(await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade, ts: Math.floor(Date.now() / 1000) - 600 }));
    expect((await skewed.json() as any).error.code).toBe('clock_skew');
    expect(skewed.headers.get('date')).toBeTruthy();
    const stranger = await newMac();
    const forged = await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade, key: stranger.privateKey });
    expect((await call(forged)).status).toBe(401);
  });

  it('is only a WebSocket', async () => {
    const mac = await newMac();
    await register(mac);
    expect((await call(await signed(mac, 'GET', '/v1/tunnel/mac'))).status).toBe(426);
  });

  it('replaces the one before it', async () => {
    const { mac, macEnd, phones } = await tunnel();
    const phone = (await connectPhone(phones[0].bearer)).end!;
    await phone.control('mac');
    const second = (await connectMac(mac)).end!;
    expect((await macEnd.closing()).code).toBe(CLOSE.replaced);
    second.send(await deviceList(...phones));
    // The phone hears the Mac go and come back, so it drops streams that were with the old socket.
    await phone.until(() => phone.messages.filter(m => m === '{"type":"mac","online":true}').length >= 2 ? true : undefined, 'online again');
    expect(phone.messages).toContain('{"type":"mac","online":false}');
  });

  it('answers pings without the object', async () => {
    const { macEnd } = await tunnel();
    macEnd.send('ping');
    await macEnd.until(() => macEnd.messages.includes('pong') || undefined, 'pong');
  });

  it('is refused while the tunnel is paused', async () => {
    const mac = await newMac();
    await register(mac);
    const response = await worker.fetch(incoming(await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade })),
      { ...env, RELAY_TUNNEL_PAUSED: '1' } as unknown as Env, context);
    expect(response.status).toBe(503);
  });
});

describe('phones', () => {
  it('connect only when the Mac listed them', async () => {
    const { mac, macEnd, phones } = await tunnel();
    const stranger = newPhone(mac);
    expect((await connectPhone(stranger.bearer)).response.status).toBe(401);
    const wrongSecret = phones[0].bearer.slice(0, -4) + 'AAAA';
    expect((await connectPhone(wrongSecret)).response.status).toBe(401);
    const phone = (await connectPhone(phones[0].bearer)).end!;
    expect(await phone.control('mac')).toEqual({ type: 'mac', online: true });
    macEnd.send(await deviceList(phones[0], stranger));
    await macEnd.processed();
    expect((await connectPhone(stranger.bearer)).response.status).toBe(101);
  });

  it('carry bytes both ways untouched, the stream id carrying the slot', async () => {
    const { macEnd, phones } = await tunnel();
    const phone = (await connectPhone(phones[0].bearer)).end!;
    await phone.control('mac');
    const hello = crypto.getRandomValues(new Uint8Array(TUNNEL.maxPayload));
    phone.send(frame(FRAME.open, 7));
    phone.send(frame(FRAME.data, 7, hello));
    const open = await macEnd.frame(FRAME.open);
    expect(open.stream & 0xffff).toBe(7);
    expect(open.stream >>> 16).toBeGreaterThan(0);
    expect(JSON.parse(new TextDecoder().decode(open.payload))).toEqual({ device: phones[0].deviceId });
    const data = await macEnd.frame(FRAME.data);
    expect(data.stream).toBe(open.stream);
    expect(new Uint8Array(data.payload)).toEqual(hello);

    const answer = utf8('server hello');
    macEnd.send(frame(FRAME.data, open.stream, answer));
    macEnd.send(frame(FRAME.credit, open.stream, new Uint8Array([0, 4, 0, 0])));
    macEnd.send(frame(FRAME.fin, open.stream));
    const back = await phone.frame(FRAME.data);
    expect(back.stream).toBe(7);
    expect(new Uint8Array(back.payload)).toEqual(answer);
    expect((await phone.frame(FRAME.credit)).payload).toEqual(new Uint8Array([0, 4, 0, 0]));
    expect((await phone.frame(FRAME.fin)).stream).toBe(7);
  });

  it('keep their slots apart', async () => {
    const { macEnd, phones } = await tunnel(2);
    const a = (await connectPhone(phones[0].bearer)).end!;
    const b = (await connectPhone(phones[1].bearer)).end!;
    await a.control('mac'); await b.control('mac');
    a.send(frame(FRAME.open, 1));
    b.send(frame(FRAME.open, 1));
    const first = await macEnd.frame(FRAME.open);
    const second = await macEnd.frame(FRAME.open);
    expect(first.stream).not.toBe(second.stream);
    const toB = [first, second].find(open => new TextDecoder().decode(open.payload).includes(phones[1].deviceId))!;
    macEnd.send(frame(FRAME.data, toB.stream, utf8('for b')));
    expect(new TextDecoder().decode((await b.frame(FRAME.data)).payload)).toBe('for b');
    expect(a.messages.filter(m => typeof m !== 'string')).toEqual([]);
  });

  it('hear that the Mac is offline, and their streams are reset', async () => {
    const { macEnd, phones } = await tunnel();
    const phone = (await connectPhone(phones[0].bearer)).end!;
    await phone.control('mac');
    macEnd.ws.close(1000, 'bye');
    await phone.until(() => phone.messages.includes('{"type":"mac","online":false}') || undefined, 'offline');
    phone.send(frame(FRAME.open, 3));
    const reset = await phone.frame(FRAME.reset);
    expect(reset.stream).toBe(3);
    expect(new TextDecoder().decode(reset.payload)).toBe('mac_offline');
  });

  it('tell the Mac when they go', async () => {
    const { macEnd, phones } = await tunnel();
    const phone = (await connectPhone(phones[0].bearer)).end!;
    await phone.control('mac');
    phone.send(frame(FRAME.open, 1));
    const { stream } = await macEnd.frame(FRAME.open);
    phone.ws.close(1000, '');
    expect(await macEnd.control('gone')).toEqual({ type: 'gone', slot: stream >>> 16 });
    // Late bytes for a phone that has gone come back as a reset.
    macEnd.send(frame(FRAME.data, stream, utf8('late')));
    expect((await macEnd.frame(FRAME.reset)).stream).toBe(stream);
  });

  it("don't get a slot that closed within the quarantine, so late frames for it reach nobody", async () => {
    const { macEnd, phones } = await tunnel();
    const first = (await connectPhone(phones[0].bearer)).end!;
    await first.control('mac');
    first.send(frame(FRAME.open, 1));
    const { stream } = await macEnd.frame(FRAME.open);
    first.ws.close(1000, '');
    await macEnd.control('gone');
    const second = (await connectPhone(phones[0].bearer)).end!;
    await second.control('mac');
    second.send(frame(FRAME.open, 1));
    const reopened = await macEnd.frame(FRAME.open);
    expect(reopened.stream >>> 16).not.toBe(stream >>> 16);
    macEnd.send(frame(FRAME.data, stream, utf8('late')));
    expect((await macEnd.frame(FRAME.reset)).stream).toBe(stream);
    expect(second.messages.filter(m => typeof m !== 'string')).toEqual([]);
  });

  it('are closed 4401 when revoked', async () => {
    const { macEnd, phones } = await tunnel(2);
    const kept = (await connectPhone(phones[0].bearer)).end!;
    const revoked = (await connectPhone(phones[1].bearer)).end!;
    await kept.control('mac'); await revoked.control('mac');
    macEnd.send(await deviceList(phones[0]));
    expect((await revoked.closing()).code).toBe(CLOSE.revoked);
    expect(kept.closed).toBeUndefined();
    expect((await connectPhone(phones[1].bearer)).response.status).toBe(401);
  });

  it('are closed 4409 when their device pairs again under the same id', async () => {
    const { mac, macEnd, phones } = await tunnel(2);
    const old = (await connectPhone(phones[0].bearer)).end!;
    const other = (await connectPhone(phones[1].bearer)).end!;
    await old.control('mac'); await other.control('mac');
    const secret = crypto.getRandomValues(new Uint8Array(32));
    const again = { ...phones[0], secret, bearer: `Bearer d1.${mac.installId}.${phones[0].deviceId}.${b64url(secret)}` };
    macEnd.send(await deviceList(again, phones[1]));
    expect((await old.closing()).code).toBe(CLOSE.replaced);
    expect(other.closed).toBeUndefined();
    await macEnd.processed();
    expect((await connectPhone(phones[0].bearer)).response.status).toBe(401);
    expect((await connectPhone(again.bearer)).response.status).toBe(101);
  });

  it('keep two sockets per device, the oldest making room', async () => {
    const { phones } = await tunnel();
    const first = (await connectPhone(phones[0].bearer)).end!;
    await first.control('mac');
    const second = (await connectPhone(phones[0].bearer)).end!;
    await second.control('mac');
    const third = (await connectPhone(phones[0].bearer)).end!;
    await third.control('mac');
    expect((await first.closing()).code).toBe(CLOSE.replaced);
    expect(second.closed).toBeUndefined();
  });

  it('are closed for an oversized or malformed frame', async () => {
    const { phones } = await tunnel();
    const phone = (await connectPhone(phones[0].bearer)).end!;
    await phone.control('mac');
    phone.send(frame(FRAME.data, 1, new Uint8Array(TUNNEL.maxPayload + 1)));
    expect((await phone.closing()).code).toBe(CLOSE.tooBig);
    const other = (await connectPhone(phones[0].bearer)).end!;
    await other.control('mac');
    other.send(frame(9, 1));
    expect((await other.closing()).code).toBe(CLOSE.tooBig);
  });

  it('are held to a byte rate with a burst', () => {
    const bucket = { tokens: TUNNEL.burstBytes, at: 0 };
    expect(take(bucket, TUNNEL.burstBytes, TUNNEL.bytesPerSecond, TUNNEL.burstBytes, 0)).toBe(true);
    expect(take(bucket, 1, TUNNEL.bytesPerSecond, TUNNEL.burstBytes, 0)).toBe(false);
    expect(take(bucket, TUNNEL.bytesPerSecond / 2, TUNNEL.bytesPerSecond, TUNNEL.burstBytes, 500)).toBe(true);
    expect(take(bucket, TUNNEL.bytesPerSecond / 2, TUNNEL.bytesPerSecond, TUNNEL.burstBytes, 500)).toBe(false);
  });
});

describe('pairing over the relay', () => {
  const ticketed = (mac: Mac, ticket: Uint8Array) => `SideA-Pair ${mac.installId}.${b64url(ticket)}`;

  async function window(macEnd: End, ticket: Uint8Array, seconds = 300) {
    macEnd.send(JSON.stringify({ type: 'pairing', ticketHash: b64url(await sha256(ticket)), expiresAt: Date.now() / 1000 + seconds }));
    await macEnd.processed();
  }

  it('needs the open sheet\'s ticket', async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    expect((await connectPhone(ticketed(mac, ticket))).response.status).toBe(403);
    await window(macEnd, ticket);
    const { response, end } = await connectPhone(ticketed(mac, ticket));
    expect(response.status).toBe(101);
    await end!.control('mac');
    end!.send(frame(FRAME.open, 1));
    const open = await macEnd.frame(FRAME.open);
    expect(JSON.parse(new TextDecoder().decode(open.payload))).toEqual({ pairing: true });

    // Closing the sheet lets the pairing under way finish but starts no new one.
    macEnd.send(JSON.stringify({ type: 'pairing' }));
    await macEnd.processed();
    expect((await connectPhone(ticketed(mac, ticket))).response.status).toBe(403);
    expect(end!.closed).toBeUndefined();
  });

  describe('sockets of a ticket that closed', () => {
    const object = (mac: Mac) => env.INSTALLS.get(env.INSTALLS.idFromName(mac.installId));
    const pastGrace = (mac: Mac) => runInDurableObject(object(mac), (instance: any, state: DurableObjectState) => {
      for (const ws of state.getWebSockets('pair')) {
        const attachment = ws.deserializeAttachment();
        if (attachment.orphaned !== undefined) ws.serializeAttachment({ ...attachment, orphaned: Date.now() - TUNNEL.pairGrace });
      }
      return state.storage.setAlarm(Date.now());
    });

    it('close after the grace, and the alarm goes back to its daily round', async () => {
      const { mac, macEnd } = await tunnel(0);
      const ticket = crypto.getRandomValues(new Uint8Array(16));
      await window(macEnd, ticket);
      const { end } = await connectPhone(ticketed(mac, ticket));
      await end!.control('mac');
      macEnd.send(JSON.stringify({ type: 'pairing' }));
      await macEnd.processed();
      // Scheduled for when the grace ends, and not closed before then.
      const scheduled = await runInDurableObject(object(mac), (_: any, state: DurableObjectState) => state.storage.getAlarm());
      expect(scheduled).toBeLessThanOrEqual(Date.now() + TUNNEL.pairGrace);
      expect(end!.closed).toBeUndefined();
      await pastGrace(mac);
      await runDurableObjectAlarm(object(mac));
      expect((await end!.closing()).code).toBe(CLOSE.noPairing);
      const next = await runInDurableObject(object(mac), (_: any, state: DurableObjectState) => state.storage.getAlarm());
      expect(next).toBeGreaterThan(Date.now() + TUNNEL.pairGrace);
    });

    it("don't stand in the way of the next ticket's pairing", async () => {
      const { mac, macEnd } = await tunnel(0);
      const stale = crypto.getRandomValues(new Uint8Array(16));
      await window(macEnd, stale);
      const first = await connectPhone(ticketed(mac, stale));
      const second = await connectPhone(ticketed(mac, stale));
      await first.end!.control('mac');
      await second.end!.control('mac');
      expect((await connectPhone(ticketed(mac, stale))).response.status).toBe(429);
      macEnd.send(JSON.stringify({ type: 'pairing' }));
      await macEnd.processed();

      const fresh = crypto.getRandomValues(new Uint8Array(16));
      await window(macEnd, fresh);
      const real = await connectPhone(ticketed(mac, fresh));
      expect(real.response.status).toBe(101);
      await real.end!.control('mac');
      expect((await first.end!.closing()).code).toBe(CLOSE.noPairing);
      expect(second.end!.closed).toBeUndefined();
      // The open ticket's own sockets are still limited, and its pairing isn't what the grace ends.
      expect((await connectPhone(ticketed(mac, fresh))).response.status).toBe(101);
      expect((await connectPhone(ticketed(mac, fresh))).response.status).toBe(429);
      await pastGrace(mac);
      await runDurableObjectAlarm(object(mac));
      expect((await second.end!.closing()).code).toBe(CLOSE.noPairing);
      expect(real.end!.closed).toBeUndefined();
    });

    it('stay open when the Mac sends the same ticket again', async () => {
      const { mac, macEnd } = await tunnel(0);
      const ticket = crypto.getRandomValues(new Uint8Array(16));
      await window(macEnd, ticket);
      const { end } = await connectPhone(ticketed(mac, ticket));
      await end!.control('mac');
      await window(macEnd, ticket);
      await pastGrace(mac);
      await runDurableObjectAlarm(object(mac));
      await macEnd.processed();
      expect(end!.closed).toBeUndefined();
    });

    it('count as old when they opened before tickets were recorded', async () => {
      const { mac, macEnd } = await tunnel(0);
      const ticket = crypto.getRandomValues(new Uint8Array(16));
      await window(macEnd, ticket);
      const { end } = await connectPhone(ticketed(mac, ticket));
      await end!.control('mac');
      await runInDurableObject(object(mac), (_: any, state: DurableObjectState) => {
        for (const ws of state.getWebSockets('pair')) {
          const { ticket: _ticket, ...older } = ws.deserializeAttachment();
          ws.serializeAttachment(older);
        }
      });
      macEnd.send(JSON.stringify({ type: 'pairing' }));
      await macEnd.processed();
      await pastGrace(mac);
      await runDurableObjectAlarm(object(mac));
      expect((await end!.closing()).code).toBe(CLOSE.noPairing);
    });
  });

  it('expires with the window', async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    await window(macEnd, ticket, -1);
    expect((await connectPhone(ticketed(mac, ticket))).response.status).toBe(403);
  });

  it('can\'t be stopped by anyone guessing tickets', async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    await window(macEnd, ticket);
    for (let i = 0; i < 20; i++) {
      expect((await connectPhone(ticketed(mac, crypto.getRandomValues(new Uint8Array(16))))).response.status).toBe(403);
    }
    expect((await connectPhone(ticketed(mac, ticket))).response.status).toBe(101);
  });

  it('allows two sockets and four streams', async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    await window(macEnd, ticket);
    const one = (await connectPhone(ticketed(mac, ticket))).end!;
    await one.control('mac');
    expect((await connectPhone(ticketed(mac, ticket))).response.status).toBe(101);
    expect((await connectPhone(ticketed(mac, ticket))).response.status).toBe(429);
    for (let stream = 1; stream <= TUNNEL.pairStreams + 1; stream++) one.send(frame(FRAME.open, stream));
    const reset = await one.frame(FRAME.reset);
    expect(reset.stream).toBe(TUNNEL.pairStreams + 1);
    expect(new TextDecoder().decode(reset.payload)).toBe('too_many_streams');
  });

  it('counts open streams, not every stream it ever opened', async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    await window(macEnd, ticket);
    const phone = (await connectPhone(ticketed(mac, ticket))).end!;
    await phone.control('mac');
    for (let stream = 1; stream <= TUNNEL.pairStreams; stream++) phone.send(frame(FRAME.open, stream));
    const opens = [];
    for (let i = 0; i < TUNNEL.pairStreams; i++) opens.push(await macEnd.frame(FRAME.open));
    // One ends with a FIN each way and one with a reset: two more may open. A FIN from one side only (stream 3)
    // still counts, so opening and half-closing can't get past the limit.
    macEnd.send(frame(FRAME.fin, opens[0].stream));
    const fin = await phone.frame(FRAME.fin);
    phone.send(frame(FRAME.fin, fin.stream));
    phone.send(frame(FRAME.reset, 2));
    phone.send(frame(FRAME.fin, 3));
    phone.send(frame(FRAME.open, 11));
    phone.send(frame(FRAME.open, 12));
    phone.send(frame(FRAME.open, 13));
    expect((await macEnd.frame(FRAME.open)).stream & 0xffff).toBe(11);
    expect((await macEnd.frame(FRAME.open)).stream & 0xffff).toBe(12);
    const reset = await phone.frame(FRAME.reset);
    expect(reset.stream).toBe(13);
  });

  it("stops counting a pairing socket's streams when the Mac they went to is gone", async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    await window(macEnd, ticket);
    const phone = (await connectPhone(ticketed(mac, ticket))).end!;
    await phone.control('mac');
    for (let stream = 1; stream <= TUNNEL.pairStreams; stream++) phone.send(frame(FRAME.open, stream));
    for (let i = 0; i < TUNNEL.pairStreams; i++) await macEnd.frame(FRAME.open);
    macEnd.ws.close(1000);
    await phone.until(() => phone.messages.filter(m => typeof m === 'string').map(m => JSON.parse(m as string)).find(m => m.type === 'mac' && !m.online), 'mac offline');
    // The phone ends one stream with a FIN and is answered with a reset, since no Mac holds the other half.
    phone.send(frame(FRAME.fin, 1));
    expect((await phone.frame(FRAME.reset)).stream).toBe(1);
    const back = (await connectMac(mac)).end!;
    phone.send(frame(FRAME.open, 21));
    expect((await back.frame(FRAME.open)).stream & 0xffff).toBe(21);
  });

  it("stops counting a pairing socket's streams when a new Mac socket replaces the one they went to", async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    await window(macEnd, ticket);
    const phone = (await connectPhone(ticketed(mac, ticket))).end!;
    await phone.control('mac');
    for (let stream = 1; stream <= TUNNEL.pairStreams; stream++) phone.send(frame(FRAME.open, stream));
    for (let i = 0; i < TUNNEL.pairStreams; i++) await macEnd.frame(FRAME.open);
    const next = (await connectMac(mac)).end!;
    expect((await macEnd.closing()).code).toBe(CLOSE.replaced);
    phone.send(frame(FRAME.open, 21));
    expect((await next.frame(FRAME.open)).stream & 0xffff).toBe(21);
  });

  it('carries 2 MiB at most', async () => {
    const { mac, macEnd } = await tunnel(0);
    const ticket = crypto.getRandomValues(new Uint8Array(16));
    await window(macEnd, ticket);
    const phone = (await connectPhone(ticketed(mac, ticket))).end!;
    await phone.control('mac');
    phone.send(frame(FRAME.open, 1));
    const chunk = new Uint8Array(TUNNEL.maxPayload);
    for (let i = 0; i <= TUNNEL.pairBytes / chunk.length; i++) phone.send(frame(FRAME.data, 1, chunk));
    expect((await phone.closing()).code).toBe(CLOSE.limited);
  });
});

describe('what a tunnel can cost', () => {
  const inObject = (mac: Mac, run: (instance: any, state: DurableObjectState) => unknown): Promise<any> =>
    (runInDurableObject as any)(env.INSTALLS.get(env.INSTALLS.idFromName(mac.installId)), run);
  const budget = (mac: Mac, bytes: number, at = Date.now()) => inObject(mac, (instance, state) => {
    instance.tunnel.schema();
    state.storage.sql.exec('INSERT OR REPLACE INTO tunnel_budget VALUES (1, ?, ?, 0)', Math.floor(at / 86_400_000), bytes);
  });

  it('closes a Mac flooding frames, as it does a phone', async () => {
    const { mac, macEnd } = await tunnel(0);
    const probe = frame(FRAME.reset, (0xfffe << 16 | 1) >>> 0).buffer as ArrayBuffer;
    const at = Date.now();
    await inObject(mac, async (instance, state) => {
      const ws = state.getWebSockets('mac')[0];
      for (let i = 0; i < TUNNEL.macBurstFrames; i++) await instance.tunnel.message(ws, probe, at);
      expect(ws.readyState).toBe(WebSocket.OPEN);
      await instance.tunnel.message(ws, probe, at);
    });
    expect((await macEnd.closing()).code).toBe(CLOSE.limited);
  });

  it('refuses every socket once the install has spent its day', async () => {
    const { mac, phones } = await tunnel(1);
    await budget(mac, TUNNEL.dayBytes);
    const refused = await connectPhone(phones[0].bearer);
    expect(refused.response.status).toBe(429);
    const wait = Number(refused.response.headers.get('retry-after'));
    expect(wait).toBeGreaterThan(0);
    expect(wait).toBeLessThanOrEqual(86_400);
    expect((await connectMac(mac)).response.status).toBe(429);
  });

  it('closes open sockets when the day runs out, and a new day starts clean', async () => {
    const { mac, macEnd, phones } = await tunnel(1);
    const phone = (await connectPhone(phones[0].bearer)).end!;
    await phone.control('mac');
    const later = Date.now() + TUNNEL.budgetFlushEvery + 1;
    await budget(mac, TUNNEL.dayBytes - 1, later);
    await inObject(mac, async (instance, state) => {
      await instance.tunnel.message(state.getWebSockets('phone')[0], frame(FRAME.data, 1, new Uint8Array(16)).buffer, later);
    });
    expect((await phone.closing()).code).toBe(CLOSE.limited);
    expect((await macEnd.closing()).code).toBe(CLOSE.limited);

    await inObject(mac, (_, state) => {
      state.storage.sql.exec('UPDATE tunnel_budget SET day = day - 1');
    });
    expect((await connectMac(mac)).response.status).toBe(101);
  });

  it('turns away a malformed pairing header without waking an object', async () => {
    const spy = vi.spyOn(env.INSTALLS, 'get');
    const open = { ...env, TUNNEL_LIMIT: { limit: async () => ({ success: true }) } } as unknown as Env;
    const response = await worker.fetch(incoming(new Request(BASE + '/v1/tunnel/phone', { headers: { ...upgrade, authorization: `SideA-Pair ${randomId()}.nope` } })), open, context);
    expect(response.status).toBe(401);
    expect(spy).not.toHaveBeenCalled();
  });

  it('limits unproved upgrades per network before waking an object', async () => {
    const closed = { ...env, TUNNEL_LIMIT: { limit: async () => ({ success: false }) } } as unknown as Env;
    const get = vi.fn();
    const response = await worker.fetch(incoming(new Request(BASE + '/v1/tunnel/phone', {
      headers: { ...upgrade, authorization: `SideA-Pair ${randomId()}.${randomId()}`, 'cf-connecting-ip': '198.51.100.20' },
    })), { ...closed, INSTALLS: { ...env.INSTALLS, get, idFromName: () => 'x' } } as unknown as Env, context);
    expect(response.status).toBe(429);
    expect(response.headers.get('retry-after')).toBe('10');
    expect(get).not.toHaveBeenCalled();
  });

  it('leaves no storage behind for a junk install id', async () => {
    const install = randomId();
    expect((await connectPhone(`SideA-Pair ${install}.${randomId()}`)).response.status).toBe(401);
    const tables = await inObject({ installId: install } as Mac, (_, state) =>
      state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite%'").toArray());
    expect(tables).toEqual([]);
  });
});

describe('the tunnel and the install', () => {
  it('closes every socket when the install is deleted', async () => {
    const { mac, macEnd, phones } = await tunnel();
    const { end: phoneEnd } = await connectPhone(phones[0].bearer);
    await phoneEnd!.control('mac');
    expect((await call(await signed(mac, 'DELETE', '/v1/installs'))).status).toBe(204);
    expect((await macEnd.closing()).code).toBe(CLOSE.revoked);
    expect((await phoneEnd!.closing()).code).toBe(CLOSE.revoked);
    expect((await connectMac(mac)).response.status).toBe(401);
    // The phone's socket closing after the erase mustn't write its slot back into the object.
    await new Promise(resolve => setTimeout(resolve, 50));
    const stub = env.INSTALLS.get(env.INSTALLS.idFromName(mac.installId));
    const tables = await runInDurableObject(stub, (_, state) =>
      state.storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'").toArray().map(row => row.name));
    expect(tables.filter(name => !name.startsWith('_') && !name.startsWith('sqlite'))).toEqual([]);
  });

  it('refuses a Mac signed with a key that rotated while the signature was checked', async () => {
    const mac = await newMac();
    const next = await newMac();
    let reads = 0;
    // The first read is the key the signature is checked with; the second, the key after a rotation landed meanwhile.
    const tunnel = new Tunnel({} as DurableObjectState, () => (reads++ === 0 ? mac.publicKey : next.publicKey));
    const request = await signed(mac, 'GET', '/v1/tunnel/mac', undefined, { headers: upgrade });
    expect(await tunnel.accept(request, 'mac')).toMatchObject({ status: 401, code: 'unauthorized' });
  });

  it("closes the Mac's socket when the install key rotates, and takes one signed with the new key", async () => {
    const { mac, macEnd } = await tunnel();
    const next = await newMac();
    const rotated = await call(await signed(mac, 'POST', '/v1/installs/rotate', { newPublicKey: b64url(next.publicKey) }));
    expect(rotated.status).toBe(200);
    expect((await macEnd.closing()).code).toBe(CLOSE.revoked);
    expect((await connectMac(mac)).response.status).toBe(401);
    const { response } = await connectMac({ ...next, installId: mac.installId });
    expect(response.status).toBe(101);
  });
});
