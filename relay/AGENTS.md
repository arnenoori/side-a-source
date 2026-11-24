# Relay (Cloudflare Worker)

Push and tunnel relay for Side A Remote. Specs: `docs/remote/relay-and-release.md`, `docs/remote/tunnel.md`; run notes in `relay/README.md`.

- Install with npm 11 and a cache under `$TMPDIR`: `npx -y npm@11 ci --cache "$TMPDIR/npm-cache"` (npm 10 fails on the peer dependencies, see `relay/DEPLOY.md`). `node_modules` is not shared between worktrees.
- Tests run in the Workers runtime through `@cloudflare/vitest-plugin` (`relay/vitest.config.ts`) with a fake APNs; they never call Apple. `npm test`, `npm run typecheck` and `npm run lint` are the gate (the lint count is a ratchet: do not raise `--max-warnings`).
- `npm run check` builds both environments with `wrangler deploy --dry-run` and uploads nothing.
- **Never deploy, publish a secret or run `wrangler deploy`, `wrangler secret` or a Cloudflare dashboard change without the owner's yes.** `relay/DEPLOY.md` is the runbook and is private.
- The relay must keep answering requests from every shipped Mac and phone build: `relay/test/compat.test.ts` is the proof. Add to it; do not weaken it.
- Wire constants (push categories and loc-keys in `relay/src/send.ts`, tunnel control words in `relay/src/tunnel.ts`) mirror `Packages/SideAProtocol`; change both sides together. `relay/test/vector.test.ts` reads the protocol package's push vector fixture.
- No secrets in the repository: the APNs key is a Worker secret; the tests generate a throwaway key.
