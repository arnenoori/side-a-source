# Side A Remote (iOS)

- `project.yml` is the source of the Xcode project; `SideARemote.xcodeproj` is generated and ignored. Run `xcodegen` here after pulling or adding a file; targets list folders, so a new file in one needs no manifest edit.
- Signing team: `TEAM_ID` or `APPLE_TEAM_ID`, or copy `Local.xcconfig.template` to `Local.xcconfig` (ignored). Never commit a team id or profile.
- Debug ids end in `.dev` and install beside an App Store build. `scripts/ios-run-device.sh` builds and launches on a connected iPhone.
- Simulator without a Mac: install the simulator build and launch with `--demo` (sample data from `SideARemote/Demo`). Steps are in `apps/ios/README.md`. Tests need an iPhone simulator; `scripts/check.sh` picks one, or set `SIDEA_IOS_SIMULATOR`.
- `scripts/ios-archive.sh` archives and exports an .ipa and takes the next build number (`BUILD=<n>` picks one) and rewrites `CURRENT_PROJECT_VERSION` in `project.yml` once the export passes; commit that through its own PR. It uploads nothing; an upload or TestFlight/App Store submission needs the owner's yes. Never edit `CURRENT_PROJECT_VERSION` by hand. Edit `MARKETING_VERSION` in `project.yml` only to start a new version, which is required once the previous one is approved (App Store Connect closes that version's train).
- Every class declares `nonisolated deinit {}` unless its deinit must run on the main actor (the app is main-actor by default; see `apps/ios/README.md`).
- `Shared` is the `SideARemoteShared` framework the app, widgets and extensions all link; `Linked` is compiled into each binary that answers. Code both need goes there, not copied into a target.
- The phone talks only through `Packages/SideAProtocol` (`SideARemoteKit` for transport and sync). Do not decode wire JSON in the app. Words that name the host come from `HostOS` (`Packages/SideAProtocol/Sources/SideAProtocol/HostNoun.swift`), not a hard-coded "Mac".
- Memory sizes come from `MemorySize` in `SideAProtocol`, so a process reads the same on the Mac and the phone. Other times, amounts and sizes go through `Shared/Formatting/Formatting.swift`; do not add a second formatter.
