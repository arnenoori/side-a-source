import Foundation
import Testing
@testable import SideADaemonKit

/// What the hook script is to the daemon: a blocking client of the hook socket.
final class HookClient: @unchecked Sendable {
    private let descriptor: Int32
    private var buffer = Data()

    init(path: String) throws {
        #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        descriptor = socket(AF_UNIX, stream, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { let reason = errno; Foundation.close(descriptor); throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .ECONNREFUSED) }
    }

    func send(_ object: [String: Any]) {
        let line = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        sendRaw(line + Data("\n".utf8))
    }

    func sendRaw(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// The next line the daemon wrote, blocking, or nil when it closed the connection.
    func line() -> [String: Any]? {
        // swiftlint:disable:next unbounded_poll_in_tests -- not a poll: `read` blocks and returns 0 when the daemon closes.
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &chunk, chunk.count)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func close() { Foundation.close(descriptor) }
}

/// A line out of the socket, found without blocking the test's thread.
func answer(of client: HookClient) async -> [String: Any]? {
    await Task.detached { client.line().map { UncheckedBox($0) } }.value?.value
}

struct UncheckedBox<Value>: @unchecked Sendable { let value: Value; init(_ value: Value) { self.value = value } }

private actor Heard {
    var lines: [(UInt64, String)] = []
    var closed: [UInt64] = []
    func line(_ id: UInt64, _ text: String) { lines.append((id, text)) }
    func close(_ id: UInt64) { closed.append(id) }
}

@Test func theHookSocketHandsOverEachLineAnswersItAndTellsWhenAHookQuitsFirst() async throws {
    let directory = try temporaryDirectory("hs")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("h/island.sock").path
    let heard = Heard()
    let socket = try await HookSocket.start(path: path, received: { id, line in Task { await heard.line(id, String(decoding: line, as: UTF8.self)) } },
                                            closed: { id in Task { await heard.close(id) } })
    // Only its owner can open the socket or the folder around it.
    var info = stat()
    #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    #expect(stat(directory.appendingPathComponent("h").path, &info) == 0 && info.st_mode & 0o777 == 0o700)

    let asker = try HookClient(path: path)
    asker.send(["hello": "one"])
    #expect(await eventually { await heard.lines.count == 1 })
    let id = try #require(await heard.lines.first?.0)
    #expect(await heard.lines.first?.1 == #"{"hello":"one"}"#)
    #expect(socket.reply(id, Data("{\"behavior\":\"allow\"}\n".utf8)))
    #expect(await answer(of: asker)?["behavior"] as? String == "allow")
    // The connection is closed after the answer, and an answered hook closing is not a hook that went away.
    #expect(await answer(of: asker) == nil)
    #expect(!socket.reply(id, Data("{}\n".utf8)))
    #expect(await heard.closed.isEmpty)

    let quitter = try HookClient(path: path)
    quitter.send(["hello": "two"])
    #expect(await eventually { await heard.lines.count == 2 })
    quitter.close()
    #expect(await eventually { await heard.closed.count == 1 })
    #expect(await heard.closed.first == heard.lines.last?.0)

    // A hook that connects and says nothing before it goes is nothing to report.
    let silent = try HookClient(path: path)
    silent.close()
    let third = try HookClient(path: path)
    third.send(["hello": "three"])
    #expect(await eventually { await heard.lines.count == 3 })
    #expect(await heard.closed.count == 1)
    third.close()
    await socket.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func theHookSocketRefusesAPathThatDoesNotFitASocketAddress() async throws {
    let path = "/tmp/" + String(repeating: "a", count: 120) + "/island.sock"
    await #expect(throws: HookSocket.PathTooLong.self) {
        _ = try await HookSocket.start(path: path, received: { _, _ in }, closed: { _ in })
    }
}

@Test func aLineThatNeverEndsIsDroppedAtTheLimit() async throws {
    let directory = try temporaryDirectory("hs")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("island.sock").path
    let heard = Heard()
    let socket = try await HookSocket.start(path: path, received: { id, line in Task { await heard.line(id, String(decoding: line, as: UTF8.self)) } },
                                            closed: { id in Task { await heard.close(id) } })
    // The daemon hangs up mid-write, which would otherwise end this process with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    let client = try HookClient(path: path)
    client.sendRaw(Data(repeating: 0x61, count: HookSocket.lineLimit + 1))
    // The daemon closes it: the read ends, and nothing was handed over.
    #expect(await Task.detached { client.line() == nil }.value)
    #expect(await heard.lines.isEmpty)
    client.close()
    await socket.stop()
}
