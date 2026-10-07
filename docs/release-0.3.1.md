# Side A 0.3.1 release record

Published September 7, 2026: https://github.com/arnenoori/side-a-releases/releases/tag/v0.3.1

The release uses tag `v0.3.1`, source commit `d6e9a705dbf6d1f1a84ef1e952dbf750e8268493`,
and build 5. GitHub run `34139294209` passed release safeguards and both native
architecture test/build jobs. GitHub then refused to start the universal installer
and notarization jobs because paid Actions usage was capped at $0; the budget editor
also required a valid payment method.

The two exact CI artifacts were downloaded and assembled locally using the scripts
from the release tag. No app code was rebuilt or changed. The same notarization,
installer validation, checksum, and publication scripts completed locally. GitHub's
full release workflow did not complete and must not be described as green. For future
versions, resolve billing before pushing a new tag; do not republish this immutable
version to retry CI.

Signing identity: `Developer ID Application: Arne Noori (NV46KL65S9)`.
Apple returned `Accepted` for both submissions:

- App: `1a1d65e8-f61c-4be8-9ece-0e040c510cf9`.
- DMG: `2dd5c145-c227-49df-94f5-0299390773fb`.

Both artifacts were downloaded again from the public release. Their SHA-256 digests
matched the published manifest. Stapler and Gatekeeper accepted the downloaded DMG
and its enclosed universal app. The website download button was clicked in Arc;
that browser download matched the same digest. Finder displayed the custom installer
background, app icon, arrow, and Applications shortcut.

```text
63ef3de1f1467e8b991ee8994db35acfa0561132f1e5f7d8c28a0e54acb56f49  SideA-0.3.1-macOS-universal.zip
c59cc7dd97e3ccf4ebd646881374044020a0151fbbafe31b3e29358bf4406d61  SideA-0.3.1-macOS-universal.dmg
```

The accompanying website/documentation update passed all 12 website tests, TypeScript,
production build, all 8 release-safety tests, actionlint, and shellcheck locally.
Its GitHub-hosted checks could not start because of the same account billing block.
Native app and bridge sources are unchanged from the CI-tested release tag.

Codex and Auto flip remain experimental. Signing and notarization do not establish
live multi-account OAuth or real-limit handoff acceptance; see `validation.md`.
