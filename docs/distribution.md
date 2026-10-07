# Public distribution

The release pipeline produces a Developer ID signed, Apple-notarized universal
app for macOS 14 or later, inside a custom drag-to-Applications DMG. Source stays
in the private `arnenoori/side-a` repository; only the compiled download page,
installation instructions, release notes, checksums, and approved app bundles
belong in the public `arnenoori/side-a-releases` repository.

## Setup

The signing team is Arne Noori, `NV46KL65S9`. A **Developer ID Application**
certificate and its private key are required. Apple Distribution and Apple
Development certificates cannot substitute for Developer ID.

Configure these Actions secrets in the **private source repository**:

| Secret | Value |
| --- | --- |
| `SIGNING_CERTIFICATE_BASE64` | Base64-encoded, password-protected P12 containing only the Developer ID Application certificate and private key |
| `SIGNING_CERTIFICATE_PASSWORD` | P12 export password |
| `NOTARY_PRIVATE_KEY` | App Store Connect API private key, PEM contents |
| `NOTARY_KEY_ID` | Matching Apple API key ID |
| `NOTARY_ISSUER_ID` | Matching issuer UUID for a team API key; omit for an individual API key |
| `PUBLIC_RELEASE_TOKEN` | Fine-grained GitHub token for **only** `arnenoori/side-a-releases`, Contents: read/write, with an explicit expiry |

Use a dedicated Apple key where available. Confirm that it belongs to the personal
team before use. Never put a P12, P8, password, token, or an exported signing key in
the repository. Do not store a general-purpose GitHub login token in Actions.
Rotate expiring credentials and revoke them when no longer needed.

The Personal vault in 1Password contains `Side A Developer ID signing` (encrypted
P12 and export password), `Side A Apple notarization`, and `Side A GitHub releases`.
The Developer ID certificate expires September 8, 2031. The public-release token
expires December 6, 2026; renew it with the same single-repository scope and update
`PUBLIC_RELEASE_TOKEN` before that date.

## CI

Every branch and pull request runs Python fixture/PTY tests and Swift tests on
native Apple Silicon and Intel runners, then builds and verifies each bundle.
Actions are pinned to commit hashes, checkout credentials are not persisted, and
ordinary CI has read-only repository permissions and no signing secrets.

`Required checks` succeeds only when both architectures pass. Make that check
required on `main` when the repository's GitHub plan supports private-repository
branch protection. At setup time GitHub returned 403 requiring GitHub Pro or a
public repository, so branch protection is **not enforced**. Keep the source private.

## Release

1. Update both version/build values in `scripts/Info.plist`, add
   `releases/vMAJOR.MINOR.PATCH.md`, and merge a reviewed, green PR to `main`.
2. Tag that commit `vMAJOR.MINOR.PATCH` and push the tag. Alternatively rerun
   `Signed public release` using an existing matching tag.
3. The workflow rejects branch dispatches, tags outside `main`, mismatched versions,
   missing notes, and missing credentials before building. It reruns both native
   test/build jobs against the release commit.
4. The signing job downloads those exact artifacts, validates resources, combines
   their executable slices, signs with hardened runtime and a secure timestamp,
   and submits the app to Apple. It requires `Accepted`, staples the ticket,
   checks Gatekeeper, then builds, signs, notarizes, and staples the custom DMG too.
   The ZIP is a fallback download. A SHA-256 manifest must cover both files exactly.
5. A separate publishing job with only the public-repository token creates a draft,
   uploads the verified binaries, and publishes it. Already published versions are
   never overwritten; a failed draft may be retried. Ship a new patch version to
   fix or roll back a public build.

Signing keys live in a temporary keychain on an ephemeral GitHub runner. Credentials
are removed even when signing fails. Rejected or timed-out notarization prevents
publication; use Apple's notarytool history/log commands locally to investigate,
and do not bypass the gate. Signed artifacts are retained for 30 days, CI previews
for 14 days. Preview artifacts are ad hoc signed and are not public releases.

## Local packaging

```sh
./scripts/build-app.sh release arm64
./scripts/build-app.sh release x86_64
./scripts/assemble-universal.sh
python3 -m venv .build/dmg-tools
.build/dmg-tools/bin/pip install -r scripts/requirements-dmg.txt
./scripts/build-dmg.sh
```

Run `scripts/notarize-app.sh` with the documented signing/notary environment
variables (see the release workflow). It signs the existing tested bundle; it does
not rebuild. App installation replaces only the `.app` bundle; account data stays
in Application Support. Version 0.4 adds [signed Sparkle updates](updates.md); earlier versions need one manual download.

## Shipping an update

Merge a PR that bumps `scripts/Info.plist` (version and build) and adds `releases/vX.Y.Z.md`, then from an up-to-date `main`:

```sh
./scripts/ship.sh
```

It dispatches the signed release on the `side-a-release` runner, waits for it, and mirrors the site. Running copies find the update through Sparkle, download it in the background and show "Update to X.Y.Z" in the menu.

## Download website

`site/` is the minimal Three.js page. Its meshes are derived from the same Blender
export as the app, deduplicated and compressed during the build. The download CTA
requires a published release with the matching DMG and checksum; before that it
shows Coming soon. A failed GitHub lookup links to the releases list.

```sh
npm --prefix site ci
npm --prefix site test
npm --prefix site run build
python3 scripts/publish-site.py
```

Production is **https://getsidea.com**, hosted by the `side-a` project in Vercel's
personal `arne-projects` team. Vercel is connected to the private source repository:
`main` updates deploy production, and branches get previews. The root `vercel.json`
runs website tests before building and serves only `site/dist`. Node 24 is configured
in the project. No Vercel credential needs to be copied into GitHub Actions.

Cloudflare hosts DNS for the user-purchased domain. The apex uses Vercel's recommended
A records; `www` uses the project's recommended CNAME and redirects to the apex with
HTTP 308. DNS records are unproxied so Vercel handles HTTPS. The Cloudflare credential
is stored in 1Password's Personal vault as `Side A Cloudflare`; it is not needed by
the website or routine deployments. Check Vercel's live domain configuration before
changing those records in future.

### Agent discovery DNS

The domain publishes a ServiceMode SVCB record at `_index._agents.getsidea.com`:

```dns
_index._agents.getsidea.com. 300 IN SVCB 1 getsidea.com. alpn="h2" port=443 key65400="https://getsidea.com/.well-known/ard.json"
```

The target is the existing HTTPS site, whose Link headers advertise public discovery
resources. The private-use `key65400` carries this domain's resource-catalog URL;
it is a local convention, not an IANA-assigned DNS-AID parameter. Clients that do
not understand it can use the standard well-known catalog path. This record does
not advertise an OAuth, A2A, or MCP server.

DNSSEC was enabled through Cloudflare Registrar on September 7, 2026. The public
DS record is present at the registrar, and Cloudflare's validating resolver returns
the authenticated-data (`ad`) flag for the SVCB response. Recheck both after DNS
changes; publishing a signed record alone does not establish a valid trust chain.

The original GitHub Pages preview remains at
`https://arnenoori.github.io/side-a-releases/`. `publish-site.py` can manually update
that compiled mirror, preserving a future CNAME file and rejecting concurrent branch
changes. It is not the production deployment path. The public repository still hosts
the signed binary releases.

## Release acceptance

Before describing Auto flip as proven for a CLI version, complete the real
two-account acceptance checks in `docs/validation.md`. Fixture tests do not establish
live OAuth or real limit behavior. Release notes must disclose experimental
integrations and prerequisites. Python and the agent CLIs remain separately
installed dependencies; notarization does not install them or validate agent behavior.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[GitHub signing](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
