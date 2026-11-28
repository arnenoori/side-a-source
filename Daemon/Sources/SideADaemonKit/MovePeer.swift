import Crypto
import Foundation
import NIOCore
import SideACore
import SideAProtocol

/// Another computer, as a move talks to it (the Mac's `MovePeer`). A `MoveFailure.refused` is the other computer's
/// answer; any other error means the request may or may not have arrived.
protocol MovePeer: Sendable {
    var id: String { get }
    var name: String { get }
    func offer(_ offer: MoveOffer) async throws -> MoveAnswer
    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws
    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState
    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState
    func abort(_ move: String) async throws -> MoveState
    func state(_ move: String) async throws -> MoveState
}

enum MoveFailure: Error, Equatable, CustomStringConvertible {
    /// Nothing moved, and the session is running here as it was (or was never stopped).
    case refused(String)
    /// The other computer was asked to start the session and did not answer. It may be running there.
    case unknown(peer: String)

    var description: String {
        switch self {
        case .refused(let message): message
        case .unknown(let peer): "\(peer) was asked to start the session and didn't answer. It may be running there."
        }
    }
}

/// A linked computer reached over its Remote server: pinned TLS on its tailnet or LAN addresses, else through its relay
/// tunnel (`PeerTunnel`) when the link carries one.
struct LinkedPeer: MovePeer {
    let id: String
    let name: String
    private let computer: LinkedComputer
    /// `X-SideA-Client`: a computer speaks the protocol its own server serves, so its build is never below the floor.
    private let client: String

    init(_ computer: LinkedComputer, version: String = SideADaemon.version) {
        id = computer.id; name = computer.name; self.computer = computer
        client = "SideARemote/\(version) (\(RemotePolicy.minClientBuild); Linux)"
    }

    private struct Nothing: Encodable {}

    /// One call, answered or refused. 429 and 503, which the server answers before the route runs, and `in_progress`
    /// are tried again with the same key after the wait the server asks for.
    func call(_ method: String, _ path: String, body: Data = Data(), contentType: String = "application/json", key: String? = nil,
              timeout: TimeAmount = .seconds(30)) async throws -> PeerResponse {
        var headers: [(String, String)] = [("Authorization", "Bearer \(computer.token)"), ("X-SideA-Protocol", String(ProtocolVersion.current)),
                                           ("X-SideA-Client", client), ("Accept", "application/json")]
        if !body.isEmpty || method == "POST" { headers.append(("Content-Type", contentType)) }
        if let key { headers.append(("Idempotency-Key", key)) }
        for attempt in 1...Self.attempts {
            let answer = try await PeerHTTP.send(to: computer.addresses, relay: computer.route, pin: computer.pin, method: method, path: path, headers: headers,
                                                 body: body, timeout: timeout)
            if (200..<300).contains(answer.status) { return answer }
            let refusal = Self.refusal(answer)
            guard refusal.retryable, attempt < Self.attempts else { throw refusal }
            try await Task.sleep(for: .seconds(min(max(refusal.retryAfter ?? 1, 0.5), 10)))
        }
        throw PeerFailure.noAnswer
    }

    static let attempts = 6

    static func refusal(_ answer: PeerResponse) -> PeerRefusal {
        let error = (try? JSONDecoder().decode(ErrorBody.self, from: answer.body))?.error
        return PeerRefusal(status: answer.status, code: error?.code ?? ErrorCode(rawValue: "http_\(answer.status)"),
                           message: error?.message ?? "The other computer answered \(answer.status).",
                           retryAfter: answer.headers["retry-after"].flatMap(Double.init))
    }

    /// An answer that says no is a refusal; anything else (no answer, a busy server, a reply this build can't read)
    /// leaves the outcome open and is thrown as it came.
    func answered<T: Decodable>(_ type: T.Type, _ work: () async throws -> PeerResponse) async throws -> T {
        let answer: PeerResponse
        do {
            answer = try await work()
        } catch let refusal as PeerRefusal where refusal.code == .moveRefused || [400, 401, 403, 404, 405, 413, 426].contains(refusal.status) {
            throw MoveFailure.refused(refusal.message)
        }
        return try JSONDecoder().decode(T.self, from: answer.body)
    }

    private func path(_ move: String, _ rest: String = "") -> String { "/v1/moves/\(Self.segment(move))\(rest)" }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    /// The other computer's own "no", for a call whose answer has no body to read.
    static func refusing(_ work: () async throws -> PeerResponse) async throws {
        do { _ = try await work() } catch let refusal as PeerRefusal where refusal.code == .moveRefused || [400, 401, 403, 404, 405, 413, 426].contains(refusal.status) {
            throw MoveFailure.refused(refusal.message)
        }
    }

    func json(_ value: some Encodable) throws -> Data { try Wire.encoder.encode(value) }

    // Each request carries a key made from the move, so one sent twice is answered once.
    func offer(_ offer: MoveOffer) async throws -> MoveAnswer {
        try await answered(MoveAnswer.self) { try await call("POST", "/v1/moves", body: try json(offer), key: "\(offer.id)-offer", timeout: .seconds(120)) }
    }

    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws {
        try await Self.refusing {
            try await call("POST", path(move, "/parts/\(Self.segment(name))/\(index)"), body: data, contentType: "application/octet-stream",
                           key: "\(move)-\(name)-\(index)", timeout: .seconds(120))
        }
    }

    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState {
        try await answered(MoveState.self) { try await call("POST", path(move, "/stage"), body: try json(stage), key: "\(move)-stage", timeout: .seconds(600)) }
    }

    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState {
        try await answered(MoveState.self) { try await call("POST", path(move, "/commit"), body: try json(commit), key: "\(move)-commit", timeout: .seconds(180)) }
    }

    func abort(_ move: String) async throws -> MoveState {
        try await answered(MoveState.self) { try await call("POST", path(move, "/abort"), body: try json(Nothing()), key: "\(move)-abort", timeout: .seconds(120)) }
    }

    func state(_ move: String) async throws -> MoveState {
        try await answered(MoveState.self) { try await call("GET", path(move)) }
    }

    /// The second half of a link: how the other computer reaches this one.
    func link(_ link: ComputerLink) async throws -> ComputerLinked {
        try await answered(ComputerLinked.self) { try await call("POST", "/v1/computers", body: try json(link), key: "link-\(link.deviceID)") }
    }

    /// Tells the other computer that this one (host id `me`) unlinked.
    func unlink(_ me: String) async throws {
        _ = try await call("DELETE", "/v1/computers/\(Self.segment(me))", key: UUID().uuidString.lowercased())
    }

    /// A signature for a call the other computer wants one on, made with this computer's keys for it.
    func signature(_ purpose: ConfirmPurpose, subject: String, faceID: Bool) throws -> String {
        guard let raw = faceID ? computer.confirm : computer.unlock else { throw MoveFailure.refused("Link \(name) again to do that.") }
        let at = Int(Date().timeIntervalSince1970)
        let text = try ConfirmMessage.text(macID: id, deviceID: computer.deviceID, purpose: purpose, subject: subject, at: at)
        let signature = try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: Data(text.utf8))
        return ConfirmSignature(at: at, signer: faceID ? .confirm : .unlock, signature: signature.derRepresentation).headerValue
    }
}
