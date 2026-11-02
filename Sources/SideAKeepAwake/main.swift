import Foundation
import SideAKeepAwakeCore

final class Helper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: KeepAwakeHelper.label)
    private let listener = NSXPCListener(machServiceName: KeepAwakeHelper.label)
    private var state: LidSleepState
    private var nextClient = 0
    private var sources: [DispatchSourceProtocol] = []

    override init() {
        state = LidSleepState(owned: FileManager.default.fileExists(atPath: KeepAwakeHelper.stateFile), now: Self.now)
        super.init()
    }

    static var now: Double { Date().timeIntervalSince1970 }

    func run() -> Never {
        queue.sync { tick() }
        if let requirement = KeepAwakeHelper.clientRequirement(team: KeepAwakeHelper.teamID()) {
            listener.setConnectionCodeSigningRequirement(requirement)
            listener.delegate = self
            listener.resume()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [self] in
            tick()
            if state.shouldExit(now: Self.now) { exit(0) }
        }
        // launchd sends SIGTERM when the helper is unregistered or the Mac shuts down.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        terminate.setEventHandler { [self] in
            if state.owned { perform(.restore) }
            exit(0)
        }
        sources = [timer, terminate]
        sources.forEach { $0.resume() }
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = queue.sync {
            nextClient += 1
            state.connect(nextClient)
            return nextClient
        }
        connection.exportedInterface = NSXPCInterface(with: KeepAwakeHelping.self)
        connection.exportedObject = Client(helper: self, id: id)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            queue.async { self.state.disconnect(id, now: Self.now) }
        }
        connection.resume()
        return true
    }

    func request(_ client: Int, disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            if let action = state.request(client, disabled: disabled, systemDisabled: sleepDisabled()) { perform(action) }
            reply(sleepDisabled())
        }
    }

    private func tick() {
        if let action = state.tick(now: Self.now) { perform(action) }
    }

    /// Ownership is recorded before sleep goes off, so a crash in between still leaves it to restore.
    private func perform(_ action: LidSleepState.Action) {
        let disabled = action == .disable
        if disabled { FileManager.default.createFile(atPath: KeepAwakeHelper.stateFile, contents: nil) }
        let success = run(KeepAwakeHelper.command(disabled)) != nil
        if success != disabled { try? FileManager.default.removeItem(atPath: KeepAwakeHelper.stateFile) }
        state.applied(action, success: success)
    }

    private func sleepDisabled() -> Bool {
        run(["-g"]).map(KeepAwakeHelper.sleepDisabled) ?? false
    }

    private func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: KeepAwakeHelper.pmset)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

final class Client: NSObject, KeepAwakeHelping {
    private weak var helper: Helper?
    private let id: Int

    init(helper: Helper, id: Int) {
        self.helper = helper
        self.id = id
    }

    func setLidSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        guard let helper else { return reply(false) }
        helper.request(id, disabled: disabled, reply: reply)
    }
}

Helper().run()
