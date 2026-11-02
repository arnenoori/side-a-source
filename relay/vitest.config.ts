import { generateKeyPairSync } from 'node:crypto';
import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

// A throwaway APNs key: the tests check the relay's JWTs against its public half.
const apns = generateKeyPairSync('ec', { namedCurve: 'P-256' });

export default defineConfig({
  // Several tests make a hundred requests; on a busy Mac those outlast the default 5 seconds.
  test: { testTimeout: 60_000 },
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.jsonc' },
      miniflare: {
        bindings: {
          APNS_KEY_P8: apns.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string,
          APNS_KEY_ID: 'TESTKEY123',
          APNS_TEAM_ID: 'NV46KL65S9',
          RATE_KEY: 'test-rate-key',
          TEST_APNS_PUBLIC_JWK: JSON.stringify(apns.publicKey.export({ format: 'jwk' })),
        },
      },
    }),
  ],
});
