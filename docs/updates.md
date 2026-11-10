# Signed updates

Side A 0.4.0 introduces Sparkle 2.9.6 (exact SPM version, artifact checksum pinned upstream and in Package.resolved). Version 0.3.1 needs one manual download; it does not contain an updater.

The app checks `https://getsidea.com/appcast.xml`, requires an Ed25519-signed feed and validates the update archive before extraction. Installer downloads are also signed with Developer ID and Apple notarized. Sparkle's optional system-profile submission is disabled.

## Automatic updates

Side A always checks for updates in the background (`SUEnableAutomaticChecks`; a Mac that had turned checks off gets them back on). Settings › General › Updates has one switch, **Update Automatically**, on by default. It is Sparkle's `automaticallyDownloadsUpdates`, so a Mac that had turned "Install updates automatically" off keeps it off.

**On.** Sparkle downloads the update and offers its install-now block (`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`). `Updates` keeps it and returns true, then once a minute asks `QuietInstall.hold`, a pure function, whether now is safe. It is safe only when all of these hold:

- nobody is at the Mac: no keyboard or pointer input for 10 minutes, or the screen is locked (`UserPresence`);
- nothing waits in the island: no permission request, question or plan (`Island.pending`);
- the pool is answering no request, streams included (`PoolProxy.inFlight`);
- nothing a relaunch would cut off is under way (`AccountStore.relaunchActivity`): a sign-in or adoption (`signingIn`, `adopting`), a login renewal (`waking`), a bridge command that changes logins, the Keychain or files (`bridgeChanges`: login, logout, adopt, renew, activate, swap, forget, prime, codex-pool-home, cleanup archive/remove-worktree/restore), Test Pool, an open reply field in the island, an unsent message or photo in a Sessions composer (drafts live only in memory), a phone pairing sheet, or Keep Awake's helper being removed.

Before calling the block, Side A reads the feed. Holding the block stalls Sparkle's later cycles, so a waiting build can't be swapped for a newer one: if the feed has superseded it, the waiting build installs anyway and the relaunched app checks again at once, and the newer build follows at the next quiet moment. The block installs and relaunches without any Sparkle window. "Update to X.Y.Z" in the menu uses the same block straight away, even though Sparkle's stalled session keeps `canCheckForUpdates` false. While a block is held, Check for Updates… asks whether to restart into the waiting version instead of opening Sparkle's window (Sparkle couldn't check anyway), and the phone's update check answers that the update is already found. The block is called at most once, on the main thread.

Turning the switch off after a block was taken stops the quiet-install timer but keeps the block: Sparkle has no way to take it back, and its session stays stalled until the block runs or the app quits. Nothing installs by itself; "Update to X.Y.Z" and Check for Updates… still install it, and on quit Sparkle installs it as it does any prepared download (`SPUUpdaterDelegate`: "Sparkle will always attempt to install the update when the app terminates"). The relaunched app checks the feed as usual. Turning the switch back on resumes the timer.

Critical updates and user-initiated checks with nothing held behave as Sparkle does on its own: a critical download is not taken over, and Check for Updates… shows Sparkle's window.

**Off.** Nothing changes from before: Side A returns false from the delegate, Sparkle ends the session so later checks still reach the feed, the menu shows "Update to X.Y.Z" when a check finds one, and the update installs when clicked or on quit. A waiting build the feed has superseded is dropped (`StagedUpdate.superseded`) and the newest one fetched.

**After the relaunch.** For 24 hours the menu shows "Updated to X.Y.Z", which opens that version's GitHub release (made from `releases/vX.Y.Z.md`). `UpdateHistory` records each launched version in user defaults; only a newer version than the last one launched counts. What survives the relaunch:

- hosted sessions run in Side A's own tmux server (`tmux -L sidea`), which nothing stops on quit; tmux holds their metadata and the relaunched app adopts them (`HostedSessions`, docs/remote/hosting.md);
- the pool helper (`SideAPool`) takes the pool port once Side A's claim file goes on `willTerminate`, serves with the last plan, and hands the port back when the new app starts; an updated helper restarts itself once it isn't serving (`PoolHelper.tick`);
- Remote says goodbye before the relaunch (`willRelaunch` → `RemoteController.handOff`), so phones reconnect quietly; Keep Awake hands sleep to its helper the same way.

## Local release

`./scripts/local-ci.sh` runs every gate on the Mac and builds both architectures. Swift runtime tests run natively on the host; cross-compiling Intel is not a substitute for an Intel runtime test.

Hosted checks remain available only through manual dispatch; pushes and PRs do not consume hosted minutes. Releases go through `scripts/ship.sh`.

The manual **Local signed release** workflow runs only from `main` on a runner labeled `side-a-release`. Register it with `--ephemeral --no-default-labels --labels side-a-release` so it accepts one release job, then unregisters. `scripts/ship.sh` does this itself when no runner is online, from the runner at `SIDEA_RUNNER_DIR` (default `~/.local/share/side-a/release-runner`, outside `~/scratch`, which gets cleared). When none is installed there, it downloads GitHub's runner and checks it against the SHA-256 in the runner's release notes. Do not install a background runner service or use it for pull requests. The job runs the local gates, receives the existing GitHub signing secrets, and removes its temporary signing keychain and private-key files on exit. Dispatch with `gh workflow run local-release.yml --ref main -f tag=vVERSION`. It publishes downloads before the signed feed. Website deployment remains a separate final step.

1. Increment both `CFBundleVersion` and `CFBundleShortVersionString` in `scripts/Info.plist`. Add `releases/vVERSION.md` and rename `## Unreleased` in `CHANGELOG.md` to the version and date. Run workflow lint, ShellCheck, packaging tests, bridge tests, Swift tests, website tests/build, and both app architecture builds.
2. Build with `scripts/build-app.sh release arm64` and `scripts/build-app.sh release x86_64`. `scripts/assemble-universal.sh` validates and combines them. Sparkle remains universal inside each package. Its framework symlinks, resource hashes, helper architectures, and nested signatures are validated.
3. Sign and notarize the tested universal app with `scripts/notarize-app.sh`. It signs Sparkle inside out with `scripts/sign-framework.sh` before signing the host. Supply the existing Developer ID and notary credentials through the private local signing environment. Do not rebuild after signing.
4. Run `scripts/build-appcast.sh`. It defaults to the Sparkle Keychain account `com.arnenoori.sidea`; `SPARKLE_PRIVATE_KEY_FILE` supports a protected exported key for CI. `SPARKLE_TOOLS` can point to the pinned package artifact's `bin` directory. The generated feed is `dist/appcast.xml`. The Sparkle verifier and `verify-appcast.py` verify its signature, exact download URL, build, version, architecture baseline, and installer size.
5. Publish the immutable binary release with `scripts/publish-release.sh vVERSION`. Only after its public downloads are verified, run `python3 scripts/publish-appcast.py`. It verifies the published installer checksum, rejects feed downgrades, and atomically updates the public repository feed. Vercel proxies `/appcast.xml` to that signed file, so later updates do not require a website redeploy. Update website version metadata/default download URL and deploy for a new landing-page release. Mirror its compiled output with `scripts/publish-site.py`. Never format or edit the generated XML: doing so invalidates its signature.
6. Verify the live feed byte-for-byte and through Sparkle, then test Check for Updates from a packaged app. An isolated test copy with a lower build number can exercise an update without replacing the user's installed application. The old installed app requires a manual upgrade to this first updater-enabled release.

Keys stay outside the repository. Sparkle's private key is in macOS Keychain, account `com.arnenoori.sidea`, with a backup intended for the Personal 1Password vault. Public verification keys and the PostHog write-only ingestion token are intentionally embedded in the app. Neither is a management credential.

Official reference: https://sparkle-project.org/documentation/
