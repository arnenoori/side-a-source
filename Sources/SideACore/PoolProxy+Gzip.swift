#if canImport(Network)
import Foundation
import SideAProtocol

struct PoolAnswer {
    let response: HTTPURLResponse
    var held = Data()
    var bytes: URLSession.AsyncBytes?

    func cancel() { bytes?.task.cancel() }
}

extension PoolProxy {
    /// Claude only: Anthropic's API takes a gzip body (and refuses zstd and brotli); nothing says ChatGPT's does.
    static func squeezed(_ body: Data, as provider: AgentProvider, headers: HTTPHeaders) -> Data? {
        guard provider == .claude, body.count >= Gzip.threshold, headers["Content-Encoding"] == nil,
              let packed = Gzip.compress(body), packed.count < body.count else { return nil }
        return packed
    }

    static func refusedEncoding(_ status: Int, _ body: Data) -> Bool {
        guard [400, 415].contains(status) else { return false }
        let text = String(decoding: body, as: UTF8.self)
        return text.contains("request_body_encoding") || text.contains("Content-Encoding")
    }

    static func drained(_ answer: PoolAnswer) async throws -> PoolAnswer {
        guard let bytes = answer.bytes else { return answer }
        var held = answer.held
        for try await byte in bytes { held.append(byte) }
        return PoolAnswer(response: answer.response, held: held, bytes: nil)
    }
}
#endif
