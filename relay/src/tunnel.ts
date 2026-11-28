// The tunnel: one Mac socket and its phones' sockets on the install's object, bytes passed through
// unread. Spec: docs/remote/tunnel.md. What crosses is the phone's TLS to the Mac, so the relay
// forwards frames and keeps no state per stream: the phone socket's slot is in the stream id.
import { CLOCK_SKEW, ID, NONCE_WINDOW, parseDeviceBearer, parseSignature, signedString, verifyEd25519 } from './auth';
import { b64url, equalBytes, fromB64url, sha256, utf8 } from './bytes';
import { isObject } from './send';

export const FRAME = { open: 1, data: 2, fin: 3, reset: 4, credit: 5 } as const;
export const HEADER = 5;

export const TUNNEL = {
  maxPayload: 32 << 10,
  socketsPerDevice: 2,
  devicesOnline: 8,
  pairSockets: 2,
  pairStreams: 4,
  pairBytes: 2 << 20,
  pairGrace: 60_000,
  ticketLifetime: 10 * 60_000,
  slotQuarantine: 60_000,
  bytesPerSecond: 8 << 20,
  burstBytes: 32 << 20,
  framesPerSecond: 2000,
  burstFrames: 4000,
  macBytesPerSecond: 16 << 20,
  macBurstBytes: 64 << 20,
  macFramesPerSecond: 4000,
  macBurstFrames: 8000,
  dayBytes: 64 * 2 ** 30,
  dayFrames: 30_000_000,
  budgetFlushBytes: 16 << 20,
  budgetFlushFrames: 20_000,
  budgetFlushEvery: 60_000,
  quietAfter: 10 * 60_000,
  asleepAfter: 24 * 3_600_000,
  goodbyeWindow: 2 * 60_000,
};

// What the Mac may say as it goes. `sleep` waits asleepAfter; the others are the owner's doing, and never alert.
export const GOODBYES = ['quit', 'off', 'sleep'] as const;
export type Goodbye = typeof GOODBYES[number];

export const CLOSE = { revoked: 4401, noPairing: 4403, silent: 4408, replaced: 4409, limited: 4429, tooBig: 1009 } as const;

const DAY = 86_400_000;

interface MacAttachment { kind: 'mac'; opened?: number }
// `streams`: open streams, counted for pairing sockets only. `live` holds each one's id and which sides sent FIN
// (1 the phone, 2 the Mac): a stream ends with a RESET from either side, or a FIN from both.
// `secret`: base64url of the secret hash the socket authenticated with, so a re-pairing under the same device id ends it.
// Pairing sockets: `ticket`, base64url of the ticket hash they opened with (absent on one older than this field), and
// `orphaned`, when that ticket stopped being the open one.
interface PhoneAttachment {
  kind: 'phone'; device: string | null; secret?: string; slot: number; opened: number; streams: number; live?: [number, number][];
  ticket?: string; orphaned?: number;
}
type Attachment = MacAttachment | PhoneAttachment;

// The Mac's liveness, one row once it has connected and said it can be watched. `up`: a socket is open. `since`: when it
// connected, or when it was last heard before it went. `watch`: it announced itself for watching on this connection (an older
// Mac doesn't, and is never alerted about). `goodbye`: what it said on the way out. `alerted`: the push for this outage is made.
interface MacRow { up: number; since: number; watch: number; goodbye: string | null; goodbye_at: number | null; alerted: number; [key: string]: SqlStorageValue }

export interface Quiet { alert?: 'quiet' | 'asleep'; next: number | null }

export interface Refusal { status: number; code: string; message: string; retryAfter?: number }

interface Bucket { tokens: number; at: number }

export function take(bucket: Bucket, cost: number, rate: number, burst: number, now: number): boolean {
  bucket.tokens = Math.min(burst, bucket.tokens + (now - bucket.at) / 1000 * rate);
  bucket.at = now;
  if (bucket.tokens < cost) return false;
  bucket.tokens -= cost;
  return true;
}

export function frame(type: number, stream: number, payload: Uint8Array = new Uint8Array()): Uint8Array {
  const bytes = new Uint8Array(HEADER + payload.length);
  bytes[0] = type;
  new DataView(bytes.buffer).setUint32(1, stream >>> 0);
  bytes.set(payload, HEADER);
  return bytes;
}

export function parseFrame(data: ArrayBuffer | Uint8Array): { type: number; stream: number; payload: Uint8Array } | null {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < HEADER || bytes.length > HEADER + TUNNEL.maxPayload) return null;
  const [type = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0] = bytes;
  if (type < FRAME.open || type > FRAME.credit) return null;
  return { type, stream: (b1 << 24 | b2 << 16 | b3 << 8 | b4) >>> 0, payload: bytes.subarray(HEADER) };
}

const json = (value: unknown) => JSON.stringify(value);

// One per install object. The object's SQLite holds the device list, the pairing window and when
// the tunnel was last used; everything else lives on the sockets' attachments or in memory.
export class Tunnel {
  private buckets = new Map<WebSocket, { bytes: Bucket; frames: Bucket; pairBytes: number }>();
  // Spent since the budget row was last written. Lost with the object if it hibernates, which takes a quiet socket.
  private spent = { bytes: 0, frames: 0, flushed: Date.now() };

  constructor(private ctx: DurableObjectState, private publicKey: () => Uint8Array | null,
              // The Mac connected: true when it had been alerted about.
              private macConnected: (alerted: boolean, now: number) => void = () => {}) {}

  private get sql() {
    return this.ctx.storage.sql;
  }

  schema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS tunnel_devices(id TEXT PRIMARY KEY, secret_hash BLOB);
      CREATE TABLE IF NOT EXISTS tunnel(id INTEGER PRIMARY KEY, ticket_hash BLOB, ticket_expires INTEGER, last_used INTEGER,
                                        bad_tickets INTEGER, bad_since INTEGER, nonces TEXT);
      CREATE TABLE IF NOT EXISTS tunnel_slots(slot INTEGER PRIMARY KEY, until INTEGER);
      CREATE TABLE IF NOT EXISTS tunnel_budget(id INTEGER PRIMARY KEY, day INTEGER, bytes INTEGER, frames INTEGER);
      CREATE TABLE IF NOT EXISTS tunnel_mac(id INTEGER PRIMARY KEY, up INTEGER, since INTEGER, watch INTEGER, goodbye TEXT,
                                            goodbye_at INTEGER, alerted INTEGER);`);
    this.sql.exec('INSERT OR IGNORE INTO tunnel VALUES (1, NULL, NULL, NULL, 0, 0, ?)', '{}');
  }

  private row() {
    this.schema();
    return this.sql.exec<{ ticket_hash: ArrayBuffer | null; ticket_expires: number | null; last_used: number | null;
      bad_tickets: number; bad_since: number; nonces: string }>('SELECT * FROM tunnel WHERE id = 1').one();
  }

  lastUsed(): number | null {
    const exists = this.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'tunnel'").toArray().length > 0;
    return exists ? this.row().last_used : null;
  }

  devices(): number {
    this.schema();
    return this.sql.exec<{ n: number }>('SELECT COUNT(*) AS n FROM tunnel_devices').one().n;
  }

  private attachment(ws: WebSocket): Attachment | null {
    return ws.deserializeAttachment() as Attachment | null;
  }

  private phoneAttachment(ws: WebSocket): PhoneAttachment {
    const attachment = this.attachment(ws);
    if (attachment?.kind !== 'phone') throw new Error('a phone socket without its attachment');
    return attachment;
  }

  private open(tag: string) {
    return this.ctx.getWebSockets(tag).filter(ws => ws.readyState === WebSocket.OPEN);
  }

  private mac(): WebSocket | undefined {
    return this.open('mac')[0];
  }

  private touch(now: number) {
    if (now - (this.row().last_used ?? 0) > 86_400_000) this.sql.exec('UPDATE tunnel SET last_used = ? WHERE id = 1', now);
  }

  async accept(request: Request, role: 'mac' | 'phone', now = Date.now()): Promise<Response | Refusal> {
    const authorization = request.headers.get('authorization');
    if (role === 'mac') return this.acceptMac(authorization, now);
    if (authorization?.startsWith('SideA-Pair ')) return this.acceptPairing(authorization, now);
    return this.acceptPhone(authorization, now);
  }

  private async acceptMac(authorization: string | null, now: number): Promise<Response | Refusal> {
    const signature = parseSignature(authorization);
    const publicKey = this.publicKey();
    if (!signature || !publicKey) return { status: 401, code: 'unauthorized', message: 'Unknown install' };
    if (Math.abs(now / 1000 - signature.ts) > CLOCK_SKEW) return { status: 401, code: 'clock_skew', message: 'Timestamp is more than 120 seconds from the relay clock; see Date' };
    const message = await signedString('GET', '/v1/tunnel/mac', signature.ts, signature.nonce, new Uint8Array());
    if (!await verifyEd25519(publicKey, signature.sig, message)) return { status: 401, code: 'unauthorized', message: 'Bad signature' };
    // A rotation while the signature was checked: only the current key connects.
    const current = this.publicKey();
    if (!current || !equalBytes(current, publicKey)) return { status: 401, code: 'unauthorized', message: 'Bad signature' };
    if (this.overBudget(now)) return this.spentForToday(now);
    // From here on nothing awaits, so a second connect can't reuse the nonce.
    const nonces: Record<string, number> = JSON.parse(this.row().nonces);
    for (const [nonce, seen] of Object.entries(nonces)) if (seen < now - NONCE_WINDOW * 1000) delete nonces[nonce];
    if (nonces[signature.nonce] !== undefined) return { status: 401, code: 'replay', message: 'Nonce already used' };
    if (Object.keys(nonces).length >= 200) return { status: 429, code: 'rate_limited', message: 'Too many connects', retryAfter: 60 };
    nonces[signature.nonce] = now;
    this.sql.exec('UPDATE tunnel SET nonces = ? WHERE id = 1', json(nonces));
    this.touch(now);

    for (const old of this.open('mac')) old.close(CLOSE.replaced, 'replaced');
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, ['mac']);
    server.serializeAttachment({ kind: 'mac', opened: now } satisfies MacAttachment);
    for (const phone of this.open('phone')) {
      this.restart(phone);
      phone.send(json({ type: 'mac', online: false }));
      phone.send(json({ type: 'mac', online: true }));
    }
    const alerted = this.macUp(now);
    await this.arm(now + TUNNEL.quietAfter);
    this.macConnected(alerted, now);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async acceptPhone(authorization: string | null, now: number): Promise<Response | Refusal> {
    const credential = await parseDeviceBearer(authorization);
    if (!credential) return { status: 401, code: 'unauthorized', message: 'Missing or malformed device token' };
    this.schema();
    const row = this.sql.exec<{ secret_hash: ArrayBuffer }>('SELECT secret_hash FROM tunnel_devices WHERE id = ?', credential.device).toArray()[0];
    if (!row || !equalBytes(new Uint8Array(row.secret_hash), credential.secretHash)) return { status: 401, code: 'unauthorized', message: 'Unknown device' };
    if (this.overBudget(now)) return this.spentForToday(now);
    const phones = this.open('phone').map(ws => ({ ws, attachment: this.phoneAttachment(ws) }));
    const online = new Set(phones.map(phone => phone.attachment.device).filter(Boolean));
    if (!online.has(credential.device) && online.size >= TUNNEL.devicesOnline) {
      return { status: 429, code: 'rate_limited', message: 'Too many devices online', retryAfter: 10 };
    }
    const own = phones.filter(phone => phone.attachment.device === credential.device).sort((a, b) => a.attachment.opened - b.attachment.opened);
    for (const phone of own.slice(0, Math.max(0, own.length - TUNNEL.socketsPerDevice + 1))) phone.ws.close(CLOSE.replaced, 'replaced');
    this.touch(now);
    return this.acceptPhoneSocket(credential.device, phones.map(phone => phone.attachment.slot), now, b64url(credential.secretHash));
  }

  private async acceptPairing(authorization: string, now: number): Promise<Response | Refusal> {
    const match = authorization.match(/^SideA-Pair ([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{22})$/);
    const encoded = match?.[2];
    const ticket = encoded ? fromB64url(encoded) : null;
    if (ticket?.length !== 16) return { status: 401, code: 'unauthorized', message: 'Malformed pairing ticket' };
    const hash = await sha256(ticket);
    const row = this.row();
    const storedHash = row.ticket_hash;
    const open = storedHash !== null && (row.ticket_expires ?? 0) > now;
    if (!open || !equalBytes(new Uint8Array(storedHash), hash)) {
      return { status: 403, code: 'no_pairing', message: 'This Mac isn\'t pairing right now' };
    }
    if (this.overBudget(now)) return this.spentForToday(now);
    const phones = this.open('phone').map(ws => this.phoneAttachment(ws));
    const ticketHash = b64url(hash);
    const pairing = this.open('pair').map(ws => ({ ws, ticket: (this.phoneAttachment(ws)).ticket }));
    if (pairing.filter(socket => socket.ticket === ticketHash).length >= TUNNEL.pairSockets) {
      return { status: 429, code: 'rate_limited', message: 'Too many pairing connections', retryAfter: 10 };
    }
    const old = pairing.filter(socket => socket.ticket !== ticketHash);
    for (const socket of old.slice(0, Math.max(0, pairing.length - TUNNEL.pairSockets + 1))) socket.ws.close(CLOSE.noPairing, 'pairing ended');
    return this.acceptPhoneSocket(null, phones.map(phone => phone.slot), now, undefined, ticketHash);
  }

  private acceptPhoneSocket(device: string | null, taken: number[], now: number, secret?: string, ticket?: string): Response | Refusal {
    this.schema();
    this.sql.exec('DELETE FROM tunnel_slots WHERE until <= ?', now);
    const resting = this.sql.exec<{ slot: number }>('SELECT slot FROM tunnel_slots').toArray().map(row => row.slot);
    const used = new Set([...taken, ...resting]);
    let slot = 1;
    while (used.has(slot)) slot++;
    if (slot > 0xffff) return { status: 429, code: 'rate_limited', message: 'Too many connections', retryAfter: 10 };
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, device ? ['phone', `device:${device}`] : ['phone', 'pair']);
    server.serializeAttachment({ kind: 'phone', device, secret, ticket, slot, opened: now, streams: 0, live: device ? undefined : [] } satisfies PhoneAttachment);
    server.send(json({ type: 'mac', online: this.mac() !== undefined }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async message(ws: WebSocket, message: string | ArrayBuffer, now = Date.now()) {
    const attachment = this.attachment(ws);
    if (!attachment || ws.readyState !== WebSocket.OPEN) return;
    const size = typeof message === 'string' ? message.length : message.byteLength;
    if (!this.within(ws, attachment, size, now)) return ws.close(CLOSE.limited, 'too fast');
    if (this.charge(size, now)) return;
    if (attachment.kind === 'mac') {
      if (typeof message === 'string') return this.control(message, now);
      return this.fromMac(ws, message);
    }
    if (typeof message === 'string') return;
    this.fromPhone(ws, attachment, message, now);
  }

  private spentForToday(now: number): Refusal {
    return { status: 429, code: 'rate_limited', message: 'This install has used its tunnel for today', retryAfter: Math.ceil((DAY - now % DAY) / 1000) };
  }

  private overBudget(now: number): boolean {
    if (!this.publicKey()) return false;
    this.schema();
    const row = this.sql.exec<{ day: number; bytes: number; frames: number }>('SELECT day, bytes, frames FROM tunnel_budget WHERE id = 1').toArray()[0];
    return row?.day === Math.floor(now / DAY) && (row.bytes >= TUNNEL.dayBytes || row.frames >= TUNNEL.dayFrames);
  }

  private flushBudget(now: number) {
    if (!this.publicKey()) return;
    this.schema();
    const day = Math.floor(now / DAY);
    this.sql.exec(`INSERT INTO tunnel_budget(id, day, bytes, frames) VALUES (1, ?1, ?2, ?3)
                   ON CONFLICT(id) DO UPDATE SET bytes = CASE WHEN day = ?1 THEN bytes + ?2 ELSE ?2 END,
                                                 frames = CASE WHEN day = ?1 THEN frames + ?3 ELSE ?3 END, day = ?1`,
      day, this.spent.bytes, this.spent.frames);
    this.spent = { bytes: 0, frames: 0, flushed: now };
  }

  // True when this message spent the last of today's budget and every socket has gone.
  private charge(size: number, now: number): boolean {
    this.spent.bytes += size;
    this.spent.frames += 1;
    if (this.spent.bytes < TUNNEL.budgetFlushBytes && this.spent.frames < TUNNEL.budgetFlushFrames
        && now - this.spent.flushed < TUNNEL.budgetFlushEvery) return false;
    this.flushBudget(now);
    if (!this.overBudget(now)) return false;
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.close(CLOSE.limited, 'daily budget'); } catch {}
    }
    return true;
  }

  private async control(text: string, now: number) {
    let value: unknown;
    try { value = JSON.parse(text); } catch { return; }
    if (!isObject(value)) return;
    if (value.type === 'devices' && Array.isArray(value.devices)) {
      const devices: { id: string; hash: Uint8Array }[] = [];
      for (const device of value.devices.slice(0, 64)) {
        const hash = typeof device?.secretHash === 'string' ? fromB64url(device.secretHash) : null;
        if (typeof device?.id === 'string' && ID.test(device.id) && hash?.length === 32) devices.push({ id: device.id, hash });
      }
      this.schema();
      this.sql.exec('DELETE FROM tunnel_devices');
      for (const device of devices) this.sql.exec('INSERT OR REPLACE INTO tunnel_devices VALUES (?, ?)', device.id, device.hash.slice().buffer);
      const known = new Map(devices.map(device => [device.id, device.hash]));
      for (const phone of this.open('phone')) {
        const { device, secret } = this.phoneAttachment(phone);
        if (!device) continue;
        const expected = known.get(device);
        if (!expected) phone.close(CLOSE.revoked, 'revoked');
        else if (secret !== undefined && b64url(expected) !== secret) phone.close(CLOSE.replaced, 'replaced');
      }
    } else if (value.type === 'watch') {
      this.sql.exec('UPDATE tunnel_mac SET watch = 1 WHERE id = 1');
    } else if (value.type === 'goodbye' && GOODBYES.some(reason => reason === value.reason)) {
      this.sql.exec('UPDATE tunnel_mac SET goodbye = ?, goodbye_at = ? WHERE id = 1', value.reason, now);
    } else if (value.type === 'pairing') {
      const hash = typeof value.ticketHash === 'string' ? fromB64url(value.ticketHash) : null;
      const expires = typeof value.expiresAt === 'number' ? Math.min(value.expiresAt * 1000, now + TUNNEL.ticketLifetime) : 0;
      this.row();
      const open = hash?.length === 32 && expires > now;
      if (open) {
        this.sql.exec('UPDATE tunnel SET ticket_hash = ?, ticket_expires = ? WHERE id = 1', hash.slice().buffer, expires);
      } else {
        this.sql.exec('UPDATE tunnel SET ticket_hash = NULL, ticket_expires = NULL WHERE id = 1');
      }
      await this.orphanPairing(open ? b64url(hash) : null, now);
    }
  }

  // The sockets of any ticket but `current` get the grace to finish, and the object an alarm to end them. A Mac that
  // sends the same ticket again, as it does on reconnecting, changes nothing.
  private async orphanPairing(current: string | null, now: number) {
    let orphaned = false;
    for (const ws of this.open('pair')) {
      const attachment = this.phoneAttachment(ws);
      if (attachment.ticket === current) {
        if (attachment.orphaned !== undefined) {
          delete attachment.orphaned;
          ws.serializeAttachment(attachment);
        }
      } else if (attachment.orphaned === undefined) {
        attachment.orphaned = now;
        ws.serializeAttachment(attachment);
        orphaned = true;
      }
    }
    if (!orphaned) return;
    const due = now + TUNNEL.pairGrace;
    const alarm = await this.ctx.storage.getAlarm();
    if (alarm === null || alarm > due) await this.ctx.storage.setAlarm(due);
  }

  // From the object's alarm: closes the pairing sockets past their grace, and says when the next one will be.
  sweepPairing(now: number): number | null {
    let next: number | null = null;
    for (const ws of this.open('pair')) {
      const { orphaned } = this.phoneAttachment(ws);
      if (orphaned === undefined) continue;
      const due = orphaned + TUNNEL.pairGrace;
      if (due <= now) ws.close(CLOSE.noPairing, 'pairing ended');
      else next = next === null ? due : Math.min(next, due);
    }
    return next;
  }

  private fromMac(mac: WebSocket, data: ArrayBuffer) {
    const parsed = parseFrame(data);
    if (!parsed) return mac.close(CLOSE.tooBig, 'bad frame');
    const slot = parsed.stream >>> 16;
    const stream = parsed.stream & 0xffff;
    const phone = this.open('phone').find(ws => (this.phoneAttachment(ws)).slot === slot);
    if (!phone) {
      if (parsed.type !== FRAME.reset) mac.send(frame(FRAME.reset, parsed.stream, utf8('gone')));
      return;
    }
    if (parsed.type === FRAME.fin || parsed.type === FRAME.reset) this.ended(phone, this.phoneAttachment(phone), stream, parsed.type, 2);
    phone.send(frame(parsed.type, stream, parsed.payload));
  }

  private ended(ws: WebSocket, attachment: PhoneAttachment, stream: number, type: number, side: 1 | 2) {
    if (!attachment.live) return;
    const index = attachment.live.findIndex(([id]) => id === stream);
    if (index < 0) return;
    const entry = attachment.live[index];
    if (!entry) return;
    const fins = entry[1] | side;
    if (type === FRAME.reset || fins === 3) attachment.live.splice(index, 1);
    else entry[1] = fins;
    attachment.streams = attachment.live.length;
    ws.serializeAttachment(attachment);
  }

  private limits(ws: WebSocket, mac: boolean, now: number) {
    let limits = this.buckets.get(ws);
    if (!limits) {
      limits = {
        bytes: { tokens: mac ? TUNNEL.macBurstBytes : TUNNEL.burstBytes, at: now },
        frames: { tokens: mac ? TUNNEL.macBurstFrames : TUNNEL.burstFrames, at: now },
        pairBytes: 0,
      };
      this.buckets.set(ws, limits);
    }
    return limits;
  }

  private within(ws: WebSocket, attachment: Attachment, size: number, now: number): boolean {
    const mac = attachment.kind === 'mac';
    const limits = this.limits(ws, mac, now);
    return take(limits.frames, 1, mac ? TUNNEL.macFramesPerSecond : TUNNEL.framesPerSecond, mac ? TUNNEL.macBurstFrames : TUNNEL.burstFrames, now)
      && take(limits.bytes, size, mac ? TUNNEL.macBytesPerSecond : TUNNEL.bytesPerSecond, mac ? TUNNEL.macBurstBytes : TUNNEL.burstBytes, now);
  }

  private fromPhone(ws: WebSocket, attachment: PhoneAttachment, data: ArrayBuffer, now: number) {
    const parsed = parseFrame(data);
    if (!parsed || parsed.stream < 1 || parsed.stream > 0xffff) return ws.close(CLOSE.tooBig, 'bad frame');
    const limits = this.limits(ws, false, now);
    const pairing = attachment.device === null;
    if (pairing) {
      limits.pairBytes += data.byteLength;
      if (limits.pairBytes > TUNNEL.pairBytes) return ws.close(CLOSE.limited, 'pairing is small');
    }
    const stream = (attachment.slot << 16 | parsed.stream) >>> 0;
    const mac = this.mac();
    if (parsed.type === FRAME.open) {
      if (pairing && attachment.streams >= TUNNEL.pairStreams) return ws.send(frame(FRAME.reset, parsed.stream, utf8('too_many_streams')));
      if (pairing) {
        const live = attachment.live ??= [];
        live.push([parsed.stream, 0]);
        attachment.streams = live.length;
        ws.serializeAttachment(attachment);
      }
      if (!mac) {
        this.ended(ws, attachment, parsed.stream, FRAME.reset, 1);
        return ws.send(frame(FRAME.reset, parsed.stream, utf8('mac_offline')));
      }
      return mac.send(frame(FRAME.open, stream, utf8(json(pairing ? { pairing: true } : { device: attachment.device }))));
    }
    if (parsed.type === FRAME.fin || parsed.type === FRAME.reset) this.ended(ws, attachment, parsed.stream, parsed.type, 1);
    if (!mac) {
      if (parsed.type !== FRAME.reset) ws.send(frame(FRAME.reset, parsed.stream, utf8('mac_offline')));
      return;
    }
    mac.send(frame(parsed.type, stream, parsed.payload));
  }

  forget(device: string) {
    this.schema();
    this.sql.exec('DELETE FROM tunnel_devices WHERE id = ?', device);
    for (const ws of this.ctx.getWebSockets(`device:${device}`)) {
      try { ws.close(CLOSE.revoked, 'forgotten'); } catch {}
    }
  }

  dropMac() {
    for (const mac of this.open('mac')) mac.close(CLOSE.revoked, 'key rotated');
  }

  dropAll() {
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.close(CLOSE.revoked, 'install deleted'); } catch {}
    }
  }

  private restart(phone: WebSocket) {
    const attachment = this.phoneAttachment(phone);
    if (!attachment.live?.length) return;
    attachment.live = [];
    attachment.streams = 0;
    phone.serializeAttachment(attachment);
  }

  async closed(ws: WebSocket, now = Date.now()) {
    const attachment = this.attachment(ws);
    this.buckets.delete(ws);
    if (!attachment) return;
    if (attachment.kind === 'phone') {
      // A deleted install's sockets close after its erase; writing the slot then would bring its tables back.
      if (this.publicKey()) {
        this.flushBudget(Date.now());
        this.sql.exec('INSERT OR REPLACE INTO tunnel_slots VALUES (?, ?)', attachment.slot, Date.now() + TUNNEL.slotQuarantine);
      }
      this.mac()?.send(json({ type: 'gone', slot: attachment.slot }));
    } else if (!this.mac()) {
      for (const phone of this.open('phone')) {
        this.restart(phone);
        phone.send(json({ type: 'mac', online: false }));
      }
      // A deleted install's sockets close after its erase; its tables stay gone.
      if (this.publicKey()) {
        const due = this.macDown(now, now);
        if (due !== null) await this.arm(due);
      }
    }
  }

  private macRow(): MacRow | undefined {
    this.schema();
    return this.sql.exec<MacRow>('SELECT up, since, watch, goodbye, goodbye_at, alerted FROM tunnel_mac WHERE id = 1').toArray()[0];
  }

  // The Mac's socket opened: it is up, with nothing yet said about itself. True when this ends an outage it was alerted to.
  private macUp(now: number): boolean {
    const alerted = this.macRow()?.alerted === 1;
    this.sql.exec(`INSERT INTO tunnel_mac VALUES (1, 1, ?1, 0, NULL, NULL, 0)
                   ON CONFLICT(id) DO UPDATE SET up = 1, since = ?1, watch = 0, goodbye = NULL, goodbye_at = NULL, alerted = 0`, now);
    return alerted;
  }

  // No Mac socket is open. `heard` is the last word from it: a socket the relay never saw close ends where the pings did.
  // A goodbye holds if it came near that last word. Past the day's budget the relay is what shut the Mac out, and that is
  // no reason to tell anyone. Returns when the outage is worth a push, or null if it never will be.
  private macDown(now: number, heard: number): number | null {
    const row = this.macRow();
    if (!row?.up) return null;
    const said = row.goodbye_at !== null && row.goodbye_at >= heard - TUNNEL.goodbyeWindow ? row.goodbye : null;
    const goodbye = this.overBudget(now) ? 'quit' : said;
    this.sql.exec('UPDATE tunnel_mac SET up = 0, since = ?, goodbye = ? WHERE id = 1', heard, goodbye);
    const wait = this.waitFor(goodbye);
    return wait === null ? null : Math.max(now, heard + wait);
  }

  // How long a Mac that left like this may stay away before it is worth a push; null for never.
  private waitFor(goodbye: string | null): number | null {
    if (goodbye === 'quit' || goodbye === 'off') return null;
    return goodbye === 'sleep' ? TUNNEL.asleepAfter : TUNNEL.quietAfter;
  }

  private async arm(when: number) {
    const alarm = await this.ctx.storage.getAlarm();
    if (alarm === null || alarm > when) await this.ctx.storage.setAlarm(when);
  }

  // Where a Mac stands. Called from the alarm: a Mac whose socket never closed but stopped pinging is marked down here,
  // so a crash, a power cut and a lid closed on an older Mac are all found the same way. Once it says an outage is
  // due, the row is marked, so each outage is told once.
  quiet(now: number): Quiet {
    let row = this.macRow();
    if (!row?.watch) return { next: null };
    if (row.up) {
      const mac = this.mac();
      const heard = mac ? this.heard(mac) : row.since;
      if (heard + TUNNEL.quietAfter > now) return { next: heard + TUNNEL.quietAfter };
      for (const ws of this.open('mac')) {
        try { ws.close(CLOSE.silent, 'silent'); } catch {}
      }
      this.macDown(now, heard);
      row = this.macRow();
      if (!row) return { next: null };
    }
    const wait = this.waitFor(row.goodbye);
    if (row.alerted || wait === null) return { next: null };
    const due = row.since + wait;
    if (due > now) return { next: due };
    this.sql.exec('UPDATE tunnel_mac SET alerted = 1 WHERE id = 1');
    return { alert: row.goodbye === 'sleep' ? 'asleep' : 'quiet', next: null };
  }

  unalert() {
    this.sql.exec('UPDATE tunnel_mac SET alerted = 0 WHERE id = 1 AND up = 0');
  }

  private heard(mac: WebSocket): number {
    const attachment = this.attachment(mac);
    const opened = (attachment?.kind === 'mac' ? attachment.opened : undefined) ?? 0;
    return Math.max(opened, this.ctx.getWebSocketAutoResponseTimestamp(mac)?.getTime() ?? 0);
  }
}
