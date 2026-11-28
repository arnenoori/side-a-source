import AppKit
import Foundation
import os
import SideACore
import SideAProtocol
import SwiftUI

/// What is typed to a session and not yet sent, kept across a quit. One private file under Side A's own folder,
/// written a moment after typing stops and emptied of anything sent or cleared.
@MainActor
final class SessionDrafts {
    static let file = "runtime/session-drafts.json"
    /// A draft older than this belongs to a conversation long left; it is not brought back.
    static let kept: TimeInterval = 30 * 24 * 3600
    static let quiet: Duration = .milliseconds(800)

    struct Saved: Codable, Equatable {
        var text: String
        var at: Double
    }

    private let url: URL
    private var pending: Task<Void, Never>?
    private var last: [String: String] = [:]

    init(root: URL) { url = root.appendingPathComponent(Self.file) }

    /// The drafts worth bringing back, by conversation.
    func load(now: Double = Date().timeIntervalSince1970) -> [String: String] {
        guard let saved = try? PrivateFile.read([String: Saved].self, from: url) else { return [:] }
        last = saved.filter { now - $0.value.at < Self.kept }.mapValues(\.text)
        return last
    }

    /// Writes once typing has stopped. A draft that is only white space is no draft.
    func changed(_ drafts: [String: String]) {
        let kept = Self.worthKeeping(drafts)
        // A write already on its way is of older words: sending straight after typing must not bring the draft back.
        pending?.cancel()
        guard kept != last else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.quiet)
            guard !Task.isCancelled else { return }
            self?.write(kept)
        }
    }

    func write(_ drafts: [String: String], now: Double = Date().timeIntervalSince1970) {
        pending?.cancel()
        last = drafts
        guard !drafts.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try PrivateFile.write(drafts.mapValues { Saved(text: $0, at: now) }, to: url)
        } catch {
            SessionDrafts.log.error("drafts not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func worthKeeping(_ drafts: [String: String]) -> [String: String] {
        drafts.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static let log = Logger(subsystem: Perf.subsystem, category: "sessions")
}

extension SessionStore {
    /// Brings back what was being typed when Side A last quit. The demo keeps nothing.
    func restoreDrafts() {
        guard desk.saved == nil, !store.isDemo else { return }
        let saved = SessionDrafts(root: store.root)
        desk.saved = saved
        // Typing stops being written a moment after it stops, so what was typed last is written as the app goes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { saved.write(SessionDrafts.worthKeeping(self.drafts)) } }
        }
        for (id, text) in saved.load() where (drafts[id] ?? "").isEmpty { drafts[id] = text }
    }

    /// Continue a conversation that has ended by typing to it: it resumes in Side A's tmux with the message as its
    /// next prompt, and shows as starting until it is up.
    func continueSession(_ session: SessionInfo, with text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let cwd = session.cwd, canContinue(session) else { return }
        drafts[session.id] = ""
        launch(StartHosted(cwd: cwd, agent: session.isCodex ? .codex : .claude, prompt: prompt, resume: session.id), terminal: desk.prefs.start.terminal)
    }

    /// It has ended, its folder is known, and Side A can host it.
    func canContinue(_ session: SessionInfo) -> Bool {
        guard session.cwd != nil, liveByID[session.id] == nil, !live.contains(where: { $0.sessionID == session.id }) else { return false }
        return store.isDemo || (store.hostingWanted && store.hosted.available)
    }
}

/// The message field under a conversation that has ended: typing to it resumes it.
struct ContinueComposer: View {
    let model: SessionStore
    let session: SessionInfo
    @State private var height = ComposerField.lineHeight

    private var text: Binding<String> { Binding(get: { model.drafts[session.id] ?? "" }, set: { model.drafts[session.id] = $0 }) }
    private var empty: Bool { (model.drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerField(text: text, height: $height, placeholder: "Continue…", onKey: { key in
                guard key == .send, !empty else { return false }
                send()
                return true
            }, wantsFocus: model.desk.composerFocus != model.desk.composerTaken, onFocus: { model.desk.composerTaken = model.desk.composerFocus })
                .frame(height: height)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Ink.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(empty)
                .help("Resume this conversation with your message (↩)")
                .accessibilityLabel("Resume and send")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func send() { model.continueSession(session, with: model.drafts[session.id] ?? "") }
}
