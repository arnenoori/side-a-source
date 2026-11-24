# SideAProtocol

The wire between the Mac (and the Linux daemon), the phone and the relay. `docs/remote/protocol.md` is the spec: change it in the same commit as the code.

- Targets: `SideAProtocol` (types, pairing, push, confirm, tunnel frames), `SideAProtocolFixtures` (frozen JSON), `SideARemoteKit` (phone client on Network.framework; Apple only, absent from Linux builds by the manifest).
- **Must build and pass on Linux**: `SideAProtocol` and `SideAProtocolFixtures`. Keep Network.framework out of them (it belongs in `TunnelMux.swift` and `SideARemoteKit`), import CryptoKit through `#if canImport(CryptoKit)` with `@preconcurrency import Crypto` as the fallback, and run `scripts/linux-check.sh` after touching either.
- Changes are additive and optional: a new field is optional and omitted when empty (never `null`), a new behaviour is gated by a capability the Mac advertises, and an old phone and an old Mac must keep working. Never rename or remove a field. A new optional `Bool` needs `// swiftlint:disable:next discouraged_optional_boolean -- reason`.
- **Fixtures are frozen.** `Sources/SideAProtocolFixtures/Fixtures/v1/MANIFEST` holds each file's SHA-256 and `fixturesAreFrozen` fails on any change. Never edit a fixture; add a new file, append it to `MANIFEST`, and cover the new case in `Fixtures/v1/future` where forward compatibility matters.
- Strings the relay also uses (push categories, loc-keys, tunnel control words in `Push.swift` and `Tunnel.swift`) are mirrored in `relay/src`: change both sides and their tests together.
- Tests: `swift test --package-path Packages/SideAProtocol`. `apps/ios` builds against this package, so `scripts/check.sh` also runs the iOS tests for any change here. Network tests bind port 0.
