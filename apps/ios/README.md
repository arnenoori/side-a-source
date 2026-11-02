# Side A Remote (iOS)

The SwiftUI app, its notification extensions and its widgets. `project.yml` is the source of the Xcode project; run `xcodegen` here after pulling.

Debug builds use ids ending in `.dev` (`com.arnenoori.sidea.remote.dev`, `group.com.arnenoori.sidea.remote.dev`), so they install beside an App Store build and keep their own pairing.

## Run on your iPhone

1. Set your team once. Either export `TEAM_ID` (or `APPLE_TEAM_ID`), or copy `Local.xcconfig.template` to `Local.xcconfig` and fill in `DEVELOPMENT_TEAM`. `Local.xcconfig` is gitignored. Xcode needs your Apple ID under Settings › Accounts so automatic signing can make the profiles.
2. Once per team, let Xcode register the App Group, which command-line signing can't create: `cd apps/ios && xcodegen && open SideARemote.xcodeproj`, pick **Any iOS Device (arm64)** as the destination, and build (⌘B). If a target's Signing & Capabilities shows `group.com.arnenoori.sidea.remote.dev` in red, click it to register. After that the script signs on its own.
3. Plug in the iPhone with a cable, unlock it, and tap **Trust** on the "Trust This Computer?" prompt.
4. On the iPhone, turn on Settings › Privacy & Security › **Developer Mode**. It restarts once; confirm after it does.
5. From the repo root, run:

   ```sh
   scripts/ios-run-device.sh
   ```

   It generates the project, builds Debug for any iPhone, then installs and launches on the connected one. With several phones connected, choose one with `DEVICE="Arne's iPhone"` (its name, UDID or devicectl identifier).
6. Put the iPhone and the Mac on the same tailnet: Tailscale on both, signed in to the same account. It also works through the relay tunnel, or on the same Wi-Fi after turning that on in Settings > Remote.
7. On the Mac, run a debug build of Side A, open Settings › Remote, turn Remote on and click **Pair iPhone…**. Scan the QR code with the app's scanner, then check that the comparison code matches on both screens.

The team must be a paid Apple Developer Program membership: a free personal team can't sign the push notification entitlement the app keeps on.

## Simulator

```sh
xcodegen
xcodebuild -project SideARemote.xcodeproj -scheme SideARemote -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd build
xcrun simctl install booted build/dd/Build/Products/Debug-iphonesimulator/SideARemote.app
xcrun simctl launch booted com.arnenoori.sidea.remote.dev --demo
```

`--demo` uses the built-in sample data, with no Mac needed.

## Transport

Every connection to the Mac goes through `NWTransport` (SideARemoteKit): HTTP/1.1 and WebSocket on Network.framework, with the SPKI pin in `sec_protocol_options_set_verify_block`. ATS doesn't govern it, so no target needs an ATS exception, even though the Mac's certificate is self-signed and reached by IP. `Paths` picks a LAN, tailnet or relay path on the fly (docs/remote/tunnel.md). The relay itself is ordinary HTTPS on `URLSession`, under ATS.

## Classes declare `nonisolated deinit {}`

The app builds with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, and Xcode 27 then gives a class without an explicit deinit an isolated one. On the iOS 26.3 runtime, an isolated deinit that runs on the main thread, outside a task, with a task-local bound by `withValue`, aborts in `swift_task_deinitOnExecutor` (`malloc: pointer being freed was not allocated`). XCTest binds one, so the tests crash without this, and any framework that binds one on the main thread would crash the app. A new class needs the line too, unless its deinit really must run on the main actor.

`scripts/check.sh` picks its simulator from `SIDEA_IOS_SIMULATOR` when set. iOS 26.x simulators are the ones that show this crash.
