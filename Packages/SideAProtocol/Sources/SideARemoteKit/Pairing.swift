import CryptoKit
import Foundation
import SideAProtocol

/// The phone's half of pairing: post the code, show the comparison code, wait for Pair on the Mac,
/// then keep the token, the device secret and the push key.
public struct PairingClient: Sendable {
    /// What a pairing QR code (format v2) carries. Pairing is QR-only: there is no invitation without `fp` and `m`.
    public struct Invitation: Sendable, Equatable {
        /// The port a release Mac listens on, for an address given without one.
        public static let defaultPort = 47800

        /// "100.101.12.4:47800", or the best LAN one on a Mac without Tailscale.
        public let address: String
        /// Every LAN host:port, best first.
        public let lans: [String]
        public var lan: String? { lans.first }
        /// The pinned SPKI hash.
        public let fp: String
        public let macName: String?
        public let macID: String?
        public let tailnet: String?
        public let code: String
        /// The Mac's relay tunnel with this sheet's ticket (`i`, `r`, `p`), so a phone elsewhere can pair through it.
        public let relay: RelayRoute?

        /// Addresses may be `host`, `host:port`, `[v6]:port` or a bare IPv6 address; each becomes `host:port`.
        /// `address` is empty for a Mac with only the relay.
        public init(address: String, lan: String? = nil, lans: [String] = [], fp: String, macName: String? = nil, macID: String? = nil,
                    tailnet: String? = nil, code: String, relay: RelayRoute? = nil) {
            self.address = address.isEmpty ? "" : Self.hostPort(address)
            self.lans = (lans.isEmpty ? [lan].compactMap { $0 } : lans).map(Self.hostPort)
            self.fp = fp; self.macName = macName; self.macID = macID; self.tailnet = tailnet; self.code = code; self.relay = relay
        }

        /// Every address to try, `address` first.
        public var addresses: [String] {
            var seen: Set<String> = [""]
            return ([address] + lans).filter { seen.insert($0).inserted }
        }

        /// `host:port`, with `defaultPort` when none was given and brackets around an IPv6 host
        /// (a zone, `%en0`, escaped as `%25en0` so it survives in a URL).
        static func hostPort(_ given: String) -> String {
            let text = given.trimmingCharacters(in: .whitespacesAndNewlines)
            var host = text, port = String(defaultPort)
            if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                host = String(text[text.index(after: text.startIndex)..<close])
                let rest = text[text.index(after: close)...]
                if rest.hasPrefix(":"), !rest.dropFirst().isEmpty { port = String(rest.dropFirst()) }
            } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
                host = String(text[..<colon])
                if !text[text.index(after: colon)...].isEmpty { port = String(text[text.index(after: colon)...]) }
            }
            guard host.contains(":") else { return "\(host):\(port)" }
            if host.contains("%"), !host.contains("%25") { host = host.replacingOccurrences(of: "%", with: "%25") }
            return "[\(host)]:\(port)"
        }

        /// `https://getsidea.com/pair#v=2&a=…&fp=…&n=…&m=…&t=…&c=…`, or the same fragment under `sidea-remote://pair#…`.
        public init?(url: URL) {
            guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
                  let items = URLComponents(string: "?" + fragment)?.queryItems else { return nil }
            let fields = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { $1 })
            // The Mac's id has been in every code the Mac has shown; a link without it could claim to be any Mac.
            guard fields["v"] == "2", let fp = fields["fp"], !fp.isEmpty, let code = fields["c"], fields["m"]?.isEmpty == false else { return nil }
            var relay: RelayRoute?
            if let install = fields["i"], let origin = fields["r"].flatMap(URL.init(string:)), let ticket = fields["p"], RelayRoute.allowed(origin) {
                relay = RelayRoute(url: origin, installID: install, ticket: ticket)
            }
            guard fields["a"] != nil || relay != nil else { return nil }
            let lans = (fields["l"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
            self.init(address: fields["a"] ?? "", lans: lans, fp: fp, macName: fields["n"], macID: fields["m"], tailnet: fields["t"],
                      code: code, relay: relay)
        }
    }

    /// What the phone learns before it spends the code: whether the Mac answers, its TLS key, and whether
    /// either side must update first (`hello.needsUpdate(clientBuild:)`).
    public struct Probe: Sendable {
        public let hello: Hello
        public let serverKeyHash: String
        /// The address that answered, which the rest of pairing uses: the tailnet one or a LAN one. A LAN
        /// address that never answers may mean Local Network access is off for the app.
        public var address: URL { client.address }
        let client: RemoteClient
    }

    /// How long the probe waits on one address before trying the next.
    public static let probeTimeout: TimeInterval = 4

    /// One attempt, after the Mac answered `PairPending`.
    public struct Attempt: Sendable {
        public let hello: Hello
        public let pending: PairPending
        /// Six digits; show it as `PairingTranscript.display(_:)` and ask the user to check the Mac shows the same.
        public let comparisonCode: String
        public let serverKeyHash: String
        let request: PairRequest
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let deviceSecret: Data
        /// Pinned to `serverKeyHash`, whether the key came from the QR code or the probe.
        let client: RemoteClient
        let pin: PinnedTrust.Mode
    }

    /// Everything to keep once the Mac clicked Pair.
    public struct Paired: Sendable {
        public let endpoint: Endpoint
        public let response: PairResponse
        /// Keep in the shared keychain group; the relay credential is `d1.<installID>.<deviceID>.<base64url(deviceSecret)>`.
        public let deviceSecret: Data
        /// Nil until the Mac has a relay install.
        public let pushKey: PushKey?
    }

    /// The Mac that answered pairing isn't the one the code named, and would have replaced that Mac's token, keys and pin.
    public struct WrongMac: Error, Equatable {}

    let invitation: Invitation
    let device: DeviceInfo
    let replaces: String?
    let transport: (any Transport)?
    let trust: PinnedTrust
    /// The last probe's addresses and what each did.
    public let probeLog = ProbeLog()
    /// The phone's Secure Enclave keys, base64url X9.63: `PairRequest.confirmKey` (Face ID) and `unlockKey`.
    let confirmKey: String?
    let unlockKey: String?

    /// `transport` is for tests; by default the session pins `fp`.
    public init(invitation: Invitation, device: DeviceInfo, replaces: String? = nil, confirmKey: String? = nil, unlockKey: String? = nil,
                transport: (any Transport)? = nil) {
        self.invitation = invitation; self.device = device; self.replaces = replaces; self.transport = transport
        self.confirmKey = confirmKey; self.unlockKey = unlockKey
        trust = PinnedTrust(.pinned(invitation.fp))
    }

    private struct NoToken: CredentialStore {
        func token(for macID: String) async throws -> String? { nil }
        func setToken(_ token: String?, for macID: String) async throws {}
    }

    /// Says hello, which also settles the TLS key, without spending the code. Tries `address`, then each LAN
    /// address, under the same pin, moving on only when one can't be reached; any answer, or a different key, ends it.
    public func probe(info: ClientInfo = .current) async throws -> Probe {
        let urls = invitation.addresses.compactMap { URL(string: "https://\($0)") }
        probeLog.reset()
        KitLog.log(.pairing, "probe \(invitation.addresses.joined(separator: ", ")) fp \(KitLog.prefix(invitation.fp)) mac \(KitLog.prefix(invitation.macID))"
                   + (invitation.tailnet.map { " tailnet \($0)" } ?? "") + (invitation.relay == nil ? "" : " relay"))
        if let relay = invitation.relay { return try await probe(urls, relay: relay, fp: invitation.fp, info: info) }
        guard let base = urls.first else { throw URLError(.badURL) }
        let endpoint = Endpoint(macID: invitation.macID ?? "", baseURL: base, alternates: Array(urls.dropFirst()), serverKeyHash: invitation.fp,
                                name: invitation.macName ?? "")
        let first = RemoteClient(endpoint: endpoint, credentials: NoToken(), transport: transport ?? NWTransport(trust: trust), info: info)
        var failure: Error = URLError(.cannotConnectToHost)
        for url in urls {
            let client = first.at(url)
            let address = "\(url.host() ?? "?")\(url.port.map { ":\($0)" } ?? "")"
            let start = ContinuousClock.now
            func record(_ outcome: String) {
                let line = "\(address) · \(outcome) after \(String(format: "%.1f", Double(KitLog.ms(since: start)) / 1000)) s"
                probeLog.add(line)
                KitLog.log(.pairing, "probe \(line)")
            }
            do {
                var request = try await client.request("GET", "/v1/hello")
                request.timeoutInterval = Self.probeTimeout
                let hello = try JSONDecoder().decode(Hello.self, from: try await client.send(request).0)
                record("answered, key \(KitLog.prefix(invitation.fp))")
                return Probe(hello: hello, serverKeyHash: invitation.fp, client: client)
            } catch let error as URLError where Self.unreachable.contains(error.code) {
                record("unreachable (\(KitLog.describe(error)))")
                failure = error
            } catch {
                record("failed (\(KitLog.describe(error)))")
                throw error
            }
        }
        throw failure
    }

    /// A code that names the relay: its addresses and the relay raced as the app races them, the relay last to win. What
    /// answers carries the rest of pairing, wait and cancel included.
    private func probe(_ urls: [URL], relay: RelayRoute, fp: String, info: ClientInfo) async throws -> Probe {
        let endpoint = Endpoint(macID: invitation.macID ?? "", baseURL: urls.first ?? Paths.relayBase, alternates: Array(urls.dropFirst()),
                                serverKeyHash: fp, name: invitation.macName ?? "", relay: relay)
        let paths = Paths(endpoint: endpoint, monitorNetwork: false) { "SideA-Pair \(relay.installID).\(relay.ticket ?? "")" }
        let client = RemoteClient(endpoint: endpoint, credentials: NoToken(), transport: transport ?? RoutedTransport(paths: paths), info: info)
        var request = try await client.request("GET", "/v1/hello")
        request.timeoutInterval = Self.probeTimeout * 2
        let start = ContinuousClock.now
        let seconds = { String(format: "%.1f", Double(KitLog.ms(since: start)) / 1000) }
        do {
            let hello = try JSONDecoder().decode(Hello.self, from: try await client.send(request).0)
            let line = "\(await paths.path().map { "\($0)" } ?? "?") · answered after \(seconds()) s"
            probeLog.add(line)
            KitLog.log(.pairing, "probe \(line)")
            return Probe(hello: hello, serverKeyHash: fp, client: client)
        } catch {
            let line = "direct and relay · failed after \(seconds()) s (\(KitLog.describe(error)))"
            probeLog.add(line)
            KitLog.log(.pairing, "probe \(line)")
            throw error
        }
    }

    /// Failures that say nothing about the Mac, only that this address didn't get through.
    static let unreachable: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet]

    /// Probes, then posts the code.
    public func start(info: ClientInfo = .current) async throws -> Attempt {
        try await start(try await probe(info: info))
    }

    /// Posts the code to the Mac `probe` reached.
    public func start(_ probe: Probe) async throws -> Attempt {
        let serverKeyHash = probe.serverKeyHash
        let client = probe.client
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let deviceSecret = Self.random(32)
        let request = PairRequest(code: invitation.code, device: device, deviceID: Self.random(16).base64URL,
                                  devicePublicKey: privateKey.publicKey.rawRepresentation.base64URL,
                                  deviceSecretHash: Data(SHA256.hash(data: deviceSecret)).base64URL, serverKeyHash: serverKeyHash, replaces: replaces,
                                  confirmKey: confirmKey, unlockKey: unlockKey)
        let (data, _) = try await client.send(try await client.request("POST", "/v1/pair", body: try RemoteClient.encoder.encode(request)))
        let pending = try JSONDecoder().decode(PairPending.self, from: data)
        let code = try PairingTranscript.comparisonCode(code: invitation.code, nonce: pending.nonce, macPublicKey: pending.macPublicKey,
                                                        devicePublicKey: request.devicePublicKey, serverKeyHash: serverKeyHash,
                                                        confirmKey: confirmKey, unlockKey: unlockKey)
        return Attempt(hello: probe.hello, pending: pending, comparisonCode: code, serverKeyHash: serverKeyHash, request: request, privateKey: privateKey,
                       deviceSecret: deviceSecret, client: client, pin: .pinned(serverKeyHash))
    }

    /// Long-polls until the user clicks Pair (or Cancel, or Codes Don't Match: `RemoteFailure` 403 `declined` /
    /// `sas_mismatch`; 408 `confirm_timeout` when nobody clicked).
    public func wait(_ attempt: Attempt) async throws -> Paired {
        var request = try await attempt.client.request("POST", "/v1/pair/\(attempt.pending.attemptID)/wait")
        request.timeoutInterval = 75
        let response = try JSONDecoder().decode(PairResponse.self, from: try await attempt.client.send(request).0)
        guard response.mac.id == invitation.macID else { throw WrongMac() }
        let pushKey = try response.relay.map { relay -> PushKey in
            guard let macKey = Data(base64URL: attempt.pending.macPublicKey) else { throw URLError(.cannotParseResponse) }
            return try PushKey.derive(attempt.privateKey, peer: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey),
                                      macPublicKey: macKey, devicePublicKey: attempt.privateKey.publicKey.rawRepresentation,
                                      installID: relay.installID, deviceID: response.deviceID)
        }
        // Paired through the relay, the hello's addresses are the ones to try first; the relay stays the fallback.
        let reported = URL(string: "https://\(response.hello.endpoints.tailnet)")
        let base = attempt.client.address.host == Paths.relayHost ? reported ?? attempt.client.address : attempt.client.address
        let relayInfo = response.relay.flatMap { relay in
            URL(string: relay.url).flatMap { RelayRoute.allowed($0) ? RelayRoute(url: $0, installID: relay.installID, deviceID: response.deviceID) : nil }
        }
            ?? invitation.relay.map { RelayRoute(url: $0.url, installID: $0.installID, deviceID: response.deviceID) }
        let endpoint = Endpoint(macID: response.mac.id, baseURL: base, serverKeyHash: attempt.serverKeyHash, name: response.mac.name, relay: relayInfo)
            .updated(with: response.hello.endpoints)
        return Paired(endpoint: endpoint, response: response, deviceSecret: attempt.deviceSecret, pushKey: pushKey)
    }

    /// Cancel on the phone: `DELETE /v1/pair/{attempt}` voids the attempt, so the code can't be confirmed on the Mac.
    /// Best effort; the Mac answers 204 whatever the attempt's state, and an attempt left behind expires anyway.
    public func cancel(attempt: Attempt) async {
        guard let request = try? await attempt.client.request("DELETE", "/v1/pair/\(attempt.pending.attemptID)") else { return }
        _ = try? await attempt.client.send(request)
    }

    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
