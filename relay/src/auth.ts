import { b64url, fromB64url, hex, sha256, utf8 } from './bytes';

export const CLOCK_SKEW = 120;
export const NONCE_WINDOW = 300;

export const ID = /^[A-Za-z0-9_-]{22}$/;   // 16 bytes, base64url

export interface Signature {
  install: string;
  ts: number;
  nonce: string;
  sig: Uint8Array;
}

// Authorization: SideA-Sig v=1, install=<installId>, ts=<unix seconds>, nonce=<b64url>, sig=<b64url>
export function parseSignature(header: string | null): Signature | null {
  const match = header?.match(/^SideA-Sig (.+)$/);
  if (!match) return null;
  const fields = new Map<string, string>();
  for (const part of match[1].split(',')) {
    const [key, value, extra] = part.trim().split('=');
    if (!key || value === undefined || extra !== undefined || fields.has(key)) return null;
    fields.set(key, value);
  }
  const install = fields.get('install') ?? '';
  const ts = Number(fields.get('ts'));
  const nonce = fields.get('nonce') ?? '';
  const sig = fromB64url(fields.get('sig') ?? '');
  if (fields.get('v') !== '1' || !ID.test(install) || !/^\d{1,12}$/.test(fields.get('ts') ?? '')) return null;
  if (!ID.test(nonce) || sig?.length !== 64) return null;
  return { install, ts, nonce, sig };
}

export async function signedString(method: string, path: string, ts: number, nonce: string, body: Uint8Array) {
  return utf8(`SideA-Sig-v1\n${method}\n${path}\n${ts}\n${nonce}\n${hex(await sha256(body))}`);
}

export const installIdFor = async (publicKey: Uint8Array) => b64url((await sha256(publicKey)).slice(0, 16));

export async function verifyEd25519(publicKey: Uint8Array, sig: Uint8Array, message: Uint8Array): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey('raw', publicKey, { name: 'Ed25519' }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'Ed25519' }, key, sig, message);
  } catch {
    return false;
  }
}

export interface DeviceCredential {
  install: string;
  device: string;
  secretHash: Uint8Array;
}

// Authorization: Bearer d1.<installId>.<deviceId>.<deviceSecret>, the secret 32 raw bytes in base64url.
export async function parseDeviceBearer(header: string | null): Promise<DeviceCredential | null> {
  const match = header?.match(/^Bearer d1\.([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/);
  const secret = match && fromB64url(match[3]);
  if (!match || secret?.length !== 32) return null;
  return { install: match[1], device: match[2], secretHash: await sha256(secret) };
}
