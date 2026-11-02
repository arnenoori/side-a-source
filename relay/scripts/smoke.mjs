// Proves a deployed relay end to end short of APNs: registers a throwaway install, reads it back
// with GET /v1/installs/self, and deletes it. Leaves nothing behind. Node 22+, no dependencies.
//   node scripts/smoke.mjs https://<staging relay host>
const base = (process.argv[2] ?? '').replace(/\/$/, '');
if (!/^https?:\/\//.test(base)) {
  console.error('usage: node scripts/smoke.mjs <relay url>');
  process.exit(2);
}

const b64url = bytes => Buffer.from(bytes).toString('base64url');
const hex = bytes => Buffer.from(bytes).toString('hex');
const sha256 = async data => new Uint8Array(await crypto.subtle.digest('SHA-256', data));

const pair = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
const publicKey = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
const installId = b64url((await sha256(publicKey)).slice(0, 16));

async function signed(method, path, body) {
  const text = body === undefined ? '' : JSON.stringify(body);
  const ts = Math.floor(Date.now() / 1000);
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const message = `SideA-Sig-v1\n${method}\n${path}\n${ts}\n${nonce}\n${hex(await sha256(new TextEncoder().encode(text)))}`;
  const sig = b64url(new Uint8Array(await crypto.subtle.sign('Ed25519', pair.privateKey, new TextEncoder().encode(message))));
  const response = await fetch(base + path, {
    method, body: text || undefined,
    headers: { authorization: `SideA-Sig v=1, install=${installId}, ts=${ts}, nonce=${nonce}, sig=${sig}`, 'content-type': 'application/json' },
  });
  const answer = await response.text();
  return { status: response.status, body: answer ? JSON.parse(answer) : undefined };
}

let failed = false;
function step(name, ok, detail) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail === undefined ? '' : `  ${JSON.stringify(detail)}`}`);
  if (!ok) failed = true;
}

const health = await fetch(`${base}/v1/health`);
step('GET /v1/health', health.status === 200, health.status);
const registered = await signed('POST', '/v1/installs', { publicKey: b64url(publicKey) });
step('POST /v1/installs', registered.status === 201, registered.status === 201 ? undefined : registered.body ?? registered.status);
const self = await signed('GET', '/v1/installs/self');
step('GET /v1/installs/self', self.status === 200 && self.body?.registered === true, self.body);
if (self.body?.paused) console.log('note RELAY_PAUSED is set: sends answer 503 paused');
const deleted = await signed('DELETE', '/v1/installs');
step('DELETE /v1/installs', deleted.status === 204, deleted.status);
const gone = await signed('GET', '/v1/installs/self');
step('GET /v1/installs/self after delete', gone.status === 404, gone.status);
process.exit(failed ? 1 : 0);
