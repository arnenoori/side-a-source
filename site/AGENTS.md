# Site

The getsidea.com pages (download, how it works, Side A Remote, pairing, privacy): Vite and TypeScript, three.js for the player.

- Commands from the repository root: `npm --prefix site ci`, then `npm --prefix site run lint`, `npm --prefix site test` and `npm --prefix site run build`. `npm --prefix site run dev` serves it on 127.0.0.1; use another port rather than stopping one you did not start.
- Tests are `node --test` files in `site/tests`; add a file to the `test` script in `site/package.json` or it will not run.
- `site/src/generated` and the player images are made by `site/scripts` (`prepare:model` runs before dev, build and lint); do not edit them.
- The download page reads the latest GitHub release (`site/src/release.mjs`); the version is not stored here, so do not hard-code one. `version` in `site/package.json` is not a release number.
- Copy is user-facing: plain sentences, no feature-explaining subtitles, no claim the app cannot back up.
- Publishing the site (`scripts/publish-site.py`, `scripts/ship.sh`) and deploys need the owner's yes; the repository's Vercel build only runs `npm --prefix site test` and the build (`vercel.json`).
