// Proves a deployed relay's tunnel end to end short of a real Mac and phone: registers a throwaway
// install, opens its Mac socket, lets a made-up device in, passes a stream both ways, pairs with a
// ticket, revokes the device and deletes the install. Leaves nothing behind. Node 22+, no dependencies.
//   node scripts/smoke-tunnel.mjs https://<staging relay host>
import { request as http } from 'node:http';
import { request as https } from 'node:https';

const base = (process.argv[2] ?? '').replace(/\/$/, '');
if (!/^https?:\/\//.test(base)) {
  console.error('usage: node scripts/smoke-tunnel.mjs <relay url>');
  process.exit(2);
}
const socketBase = base.replace(/^http/, 'ws');

const b64url = bytes => Buffer.from(bytes).toString('base64url');
const hex = bytes => Buffer.from(bytes).toString('hex');
const sha256 = async data => new Uint8Array(await crypto.subtle.digest('SHA-256', data));
const random = count => crypto.getRandomValues(new Uint8Array(count));

const pair = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
const publicKey = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
const installId = b64url((await sha256(publicKey)).slice(0, 16));

async function signature(method, path, text = '') {
  const ts = Math.floor(Date.now() / 1000);
  const nonce = b64url(random(16));
  const message = `SideA-Sig-v1\n${method}\n${path}\n${ts}\n${nonce}\n${hex(await sha256(new TextEncoder().encode(text)))}`;
  const sig = b64url(new Uint8Array(await crypto.subtle.sign('Ed25519', pair.privateKey, new TextEncoder().encode(message))));
  return `SideA-Sig v=1, install=${installId}, ts=${ts}, nonce=${nonce}, sig=${sig}`;
}

async function signed(method, path, body) {
  const text = body === undefined ? '' : JSON.stringify(body);
  const response = await fetch(base + path, {
    method, body: text || undefined,
    headers: { authorization: await signature(method, path, text), 'content-type': 'application/json' },
  });
  return response.status;
}

// An upgrade the relay refuses answers in plain HTTP, which WebSocket doesn't show: ask by hand.
function upgradeStatus(path, authorization) {
  const url = new URL(base + path);
  return new Promise(resolve => {
    const headers = { connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-version': '13', 'sec-websocket-key': b64url(random(16)) };
    if (authorization) headers.authorization = authorization;
    const req = (url.protocol === 'https:' ? https : http)(url, { headers });
    req.on('response', response => { response.resume(); resolve(response.statusCode); });
    req.on('upgrade', (_response, socket) => { socket.destroy(); resolve(101); });
    req.on('error', error => resolve(error.code));
    req.end();
  });
}

// A socket whose messages queue up for `next`, so each step can wait for what it expects.
function open(path, authorization) {
  const ws = new WebSocket(socketBase + path, { headers: { authorization } });
  ws.binaryType = 'arraybuffer';
  const queue = [];
  const waiting = [];
  const push = item => (waiting.length ? waiting.shift()(item) : queue.push(item));
  ws.onmessage = event => push({ data: event.data });
  ws.onclose = event => push({ closed: event.code });
  const opened = new Promise(resolve => {
    ws.onopen = () => resolve(true);
    ws.onerror = () => resolve(false);
  });
  const next = (ms = 5000) => new Promise(resolve => {
    if (queue.length) return resolve(queue.shift());
    const timer = setTimeout(() => resolve({ timeout: true }), ms);
    waiting.push(item => { clearTimeout(timer); resolve(item); });
  });
  return { ws, opened, next };
}

const frame = (type, stream, payload = new Uint8Array()) => {
  const bytes = new Uint8Array(5 + payload.length);
  bytes[0] = type;
  new DataView(bytes.buffer).setUint32(1, stream);
  bytes.set(payload, 5);
  return bytes;
};
const parse = data => {
  const bytes = new Uint8Array(data);
  return { type: bytes[0], stream: new DataView(bytes.buffer).getUint32(1), payload: new TextDecoder().decode(bytes.subarray(5)) };
};
const control = item => { try { return JSON.parse(item.data); } catch { return null; } };

let failed = false;
function step(name, ok, detail) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail === undefined ? '' : `  ${JSON.stringify(detail)}`}`);
  if (!ok) failed = true;
}

const plain = await fetch(`${base}/v1/tunnel/mac`);
step('GET /v1/tunnel/mac without an upgrade is 426', plain.status === 426, plain.status);
const anonymous = await upgradeStatus('/v1/tunnel/phone');
if (anonymous === 503) {
  console.log('note RELAY_TUNNEL_PAUSED is set: every tunnel socket answers 503 paused. Clear it and run again.');
  process.exit(1);
}
step('phone upgrade without a credential is 401', anonymous === 401, anonymous);

const registered = await signed('POST', '/v1/installs', { publicKey: b64url(publicKey) });
step('POST /v1/installs', registered === 201, registered);

const mac = open('/v1/tunnel/mac', await signature('GET', '/v1/tunnel/mac'));
step('Mac socket opens with a signature', await mac.opened);
mac.ws.send('ping');
const pong = await mac.next();
step('ping is answered pong', pong.data === 'pong', pong);

const device = b64url(random(16));
const secret = random(32);
mac.ws.send(JSON.stringify({ type: 'devices', devices: [{ id: device, secretHash: b64url(await sha256(secret)) }] }));
const stranger = await upgradeStatus('/v1/tunnel/phone', `Bearer d1.${installId}.${device}.${b64url(random(32))}`);
step('phone with the wrong secret is 401', stranger === 401, stranger);

const phone = open('/v1/tunnel/phone', `Bearer d1.${installId}.${device}.${b64url(secret)}`);
step('phone socket opens with its device credential', await phone.opened);
const online = control(await phone.next());
step('phone hears the Mac is online', online?.type === 'mac' && online.online === true, online);

phone.ws.send(frame(1, 7));
phone.ws.send(frame(2, 7, new TextEncoder().encode('hello mac')));
const opened = parse((await mac.next()).data);
step('Mac gets OPEN for slot 1 stream 7 from the device', opened.type === 1 && opened.stream === (1 << 16 | 7) && JSON.parse(opened.payload).device === device, opened);
const data = parse((await mac.next()).data);
step('Mac gets the phone\'s bytes', data.type === 2 && data.payload === 'hello mac', data);
mac.ws.send(frame(2, opened.stream, new TextEncoder().encode('hello phone')));
const back = parse((await phone.next()).data);
step('phone gets the Mac\'s bytes on its own stream id', back.type === 2 && back.stream === 7 && back.payload === 'hello phone', back);

const ticket = random(16);
const wrongTicket = await upgradeStatus('/v1/tunnel/phone', `SideA-Pair ${installId}.${b64url(random(16))}`);
step('pairing before the sheet opens is 403', wrongTicket === 403, wrongTicket);
mac.ws.send(JSON.stringify({ type: 'pairing', ticketHash: b64url(await sha256(ticket)), expiresAt: Math.floor(Date.now() / 1000) + 120 }));
mac.ws.send('ping');
await mac.next();
const pairing = open('/v1/tunnel/phone', `SideA-Pair ${installId}.${b64url(ticket)}`);
step('pairing socket opens with the sheet\'s ticket', await pairing.opened);
pairing.ws.close();
mac.ws.send(JSON.stringify({ type: 'pairing' }));

mac.ws.send(JSON.stringify({ type: 'devices', devices: [] }));
let revoked;
do revoked = await phone.next(); while (revoked.data !== undefined);
step('revoking the device closes its socket with 4401', revoked.closed === 4401, revoked);

const deleted = await signed('DELETE', '/v1/installs');
step('DELETE /v1/installs', deleted === 204, deleted);
let gone;
do gone = await mac.next(); while (gone.data !== undefined);
step('deleting the install closes the Mac socket with 4401', gone.closed === 4401, gone);
process.exit(failed ? 1 : 0);
