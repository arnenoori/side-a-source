// The push known-answer vector from SideAProtocol (Fixtures/v1/PushVector.request-v2.json and
// Envelope.request-v2.bin: envelope version 2, length-prefixed AAD), computed independently of the
// Swift and relay code. The relay can't open envelopes and mustn't; it has to accept a real one,
// relay it byte for byte, and agree on installId and macID.
import { afterEach, describe, expect, it, vi } from 'vitest';
import fixture from '../../Packages/SideAProtocol/Sources/SideAProtocolFixtures/Fixtures/v1/PushVector.request-v2.json';
import { b64url, fromB64url } from '../src/bytes';
import { installIdFor } from '../src/auth';
import { macIDFor } from '../src/send';
import { FakeApns, call, phoneCall, putDevice, register, signed, type Mac } from './helpers';

afterEach(() => vi.restoreAllMocks());

const vector = fixture;

const body = () => ({
  devices: [vector.deviceID], kind: 'alert', category: vector.category, collapseId: vector.collapseID,
  priority: 10, expiresIn: 3600, sound: true, level: 'time-sensitive', sealed: { [vector.deviceID]: vector.envelope },
});

describe('push vector', () => {
  it('agrees on installId and macID', async () => {
    expect(await installIdFor(fromB64url(vector.installPublicKey)!)).toBe(vector.installID);
    expect(await macIDFor(vector.installID)).toBe(vector.macID);
  });

  it('goes through the relay to APNs byte for byte, as the vector’s own install', async () => {
    const apns = new FakeApns();
    const publicKey = fromB64url(vector.installPublicKey)!;
    const privateKey = await crypto.subtle.importKey('jwk', { kty: 'OKP', crv: 'Ed25519', d: vector.installPrivateKey, x: vector.installPublicKey },
      { name: 'Ed25519' }, false, ['sign']);
    const mac: Mac = { installId: vector.installID, publicKey, privateKey };
    expect((await register(mac)).status).toBe(201);
    const secret = crypto.getRandomValues(new Uint8Array(32));
    const phone = {
      deviceId: vector.deviceID, secret, apnsToken: 'ab'.repeat(32), pushToStartToken: 'cd'.repeat(32),
      bearer: `Bearer d1.${mac.installId}.${vector.deviceID}.${b64url(secret)}`,
    };
    await putDevice(mac, phone);
    await phoneCall(phone, 'POST', '/v1/device/verify', { challenge: apns.last(phone.apnsToken)!.body.verify.challenge });

    const response = await call(await signed(mac, 'POST', '/v1/send', body()));
    expect((await response.json() as any).results[0].result).toBe('ok');
    const push = apns.last(phone.apnsToken)!;
    expect(push.body.e).toBe(vector.envelope);
    expect(push.body.aps.category).toBe(vector.category);
    expect(push.headers['apns-collapse-id']).toBe(vector.collapseID);
  });
});
