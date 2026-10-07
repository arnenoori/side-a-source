# Signed updates

Side A 0.4.0 introduces Sparkle 2.9.6 (exact SPM version, artifact checksum pinned upstream and in Package.resolved). Version 0.3.1 needs one manual download; it does not contain an updater.

The app checks `https://getsidea.com/appcast.xml`, requires an Ed25519-signed feed and validates the update archive before extraction. Installer downloads are also signed with Developer ID and Apple notarized. Sparkle's optional system-profile submission is disabled. Background checks/downloads are enabled by default and can be disabled in Settings. When an update is downloaded, the menu shows "Update to X.Y.Z"; clicking it relaunches into the new version, otherwise it installs on quit.

## Local release

`./scripts/local-ci.sh` runs every gate on the Mac and builds both architectures. Swift runtime tests run natively on the host; cross-compiling Intel is not a substitute for an Intel runtime test.

Hosted checks and releases remain available only through manual dispatch; pushes and PRs do not consume hosted minutes.

The manual **Local signed release** workflow runs only from `main` on a runner labeled `side-a-release`. Register it with `--ephemeral --no-default-labels --labels side-a-release` so it accepts one release job, then unregisters. Do not install a background runner service or use it for pull requests. The job runs the local gates, receives the existing GitHub signing secrets, and removes its temporary signing keychain and private-key files on exit. Dispatch with `gh workflow run local-release.yml --ref main -f tag=vVERSION`. It publishes downloads before the signed feed. Website deployment remains a separate final step.

1. Increment both `CFBundleVersion` and `CFBundleShortVersionString` in `scripts/Info.plist`. Add `releases/vVERSION.md`. Run workflow lint, ShellCheck, packaging tests, bridge tests, Swift tests, website tests/build, and both app architecture builds.
2. Build with `scripts/build-app.sh release arm64` and `scripts/build-app.sh release x86_64`. `scripts/assemble-universal.sh` validates and combines them. Sparkle remains universal inside each package. Its framework symlinks, resource hashes, helper architectures, and nested signatures are validated.
3. Sign and notarize the tested universal app with `scripts/notarize-app.sh`. It signs Sparkle inside out with `scripts/sign-framework.sh` before signing the host. Supply the existing Developer ID and notary credentials through the private local signing environment. Do not rebuild after signing.
4. Run `scripts/build-appcast.sh`. It defaults to the Sparkle Keychain account `com.arnenoori.sidea`; `SPARKLE_PRIVATE_KEY_FILE` supports a protected exported key for CI. `SPARKLE_TOOLS` can point to the pinned package artifact's `bin` directory. The generated feed is `dist/appcast.xml`. The Sparkle verifier and `verify-appcast.py` verify its signature, exact download URL, build, version, architecture baseline, and installer size.
5. Publish the immutable binary release with `scripts/publish-release.sh vVERSION`. Only after its public downloads are verified, run `python3 scripts/publish-appcast.py`. It verifies the published installer checksum, rejects feed downgrades, and atomically updates the public repository feed. Vercel proxies `/appcast.xml` to that signed file, so later updates do not require a website redeploy. Update website version metadata/default download URL and deploy for a new landing-page release. Mirror its compiled output with `scripts/publish-site.py`. Never format or edit the generated XML: doing so invalidates its signature.
6. Verify the live feed byte-for-byte and through Sparkle, then test Check for Updates from a packaged app. An isolated test copy with a lower build number can exercise an update without replacing the user's installed application. The old installed app requires a manual upgrade to this first updater-enabled release.

Keys stay outside the repository. Sparkle's private key is in macOS Keychain, account `com.arnenoori.sidea`, with a backup intended for the Personal 1Password vault. Public verification keys and the PostHog write-only ingestion token are intentionally embedded in the app. Neither is a management credential.

Official reference: https://sparkle-project.org/documentation/
