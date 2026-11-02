import Foundation
import Observation
import SideAProtocol
import SideARemoteKit

/// One History list from the Mac (section 4.14), the past conversations or the archive, paged by the
/// Mac's cursors. Pins, titles and archives are the Mac's; each change replaces the row with its answer.
/// The demo lists its own sample and changes it here only.
@Observable
final class HistoryList {
    nonisolated deinit {}

    let archived: Bool
    private(set) var sessions: [PastSession] = []
    private(set) var next: Cursor?
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?

    @ObservationIgnored private let tools: MacTools
    @ObservationIgnored private var demo: [PastSession]?

    init(tools: MacTools, archived: Bool, demo: [PastSession]?) {
        self.tools = tools; self.archived = archived; self.demo = demo
    }

    func refresh() async {
        if let demo {
            sessions = demo.filter { ($0.archived ?? false) == archived }
            loaded = true
            return
        }
        loading = true
        defer { loading = false }
        do {
            let page = try await tools.history(archived: archived, cursor: nil)
            sessions = page.sessions
            next = page.next
            error = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            self.error = MacTools.message(error)
        }
    }

    /// The next page, when the last row shows.
    func loadMore() async {
        guard let next, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await tools.history(archived: archived, cursor: next)
            let known = Set(sessions.map(\.id))
            sessions += page.sessions.filter { !known.contains($0.id) }
            self.next = page.next
        } catch is CancellationError {
        } catch {
            self.error = MacTools.message(error)
        }
    }

    /// Sends a change and shows the Mac's answer; a row archived or restored leaves this list.
    @discardableResult func change(_ session: PastSession, _ change: HistoryChange) async throws -> PastSession {
        let updated: PastSession
        if demo != nil {
            updated = session.applying(change)
            demo = demo?.map { $0.id == session.id ? updated : $0 }
        } else {
            updated = try await tools.change(session.id, change)
        }
        apply(updated)
        return updated
    }

    func apply(_ session: PastSession) {
        if (session.archived ?? false) != archived {
            sessions.removeAll { $0.id == session.id }
        } else if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        }
    }
}

/// Typing in the Search tab: the Mac's index of asks, replies and commands (`GET /v1/search`), paged.
@Observable
final class HistorySearch {
    nonisolated deinit {}

    private(set) var query = ""
    private(set) var results: [PastSession] = []
    private(set) var next: Cursor?
    private(set) var searching = false
    private(set) var error: String?

    @ObservationIgnored private let tools: MacTools
    @ObservationIgnored private let demo: HistoryStore?

    init(tools: MacTools, demo: HistoryStore?) { self.tools = tools; self.demo = demo }

    /// From the field, after a pause in typing; a newer query cancels this one.
    func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != query else { return }
        guard !text.isEmpty else {
            query = ""; results = []; next = nil; error = nil
            return
        }
        if let demo {
            query = text
            results = demo.search(text)
            return
        }
        searching = true
        defer { searching = false }
        do {
            let page = try await tools.search(text, cursor: nil)
            query = text
            results = page.results
            next = page.next
            error = nil
        } catch is CancellationError {
        } catch {
            query = text
            results = []
            self.error = MacTools.message(error)
        }
    }

    func loadMore() async {
        guard let next, !searching else { return }
        searching = true
        defer { searching = false }
        do {
            let page = try await tools.search(query, cursor: next)
            let known = Set(results.map(\.id))
            results += page.results.filter { !known.contains($0.id) }
            self.next = page.next
        } catch is CancellationError {
        } catch {
            self.error = MacTools.message(error)
        }
    }

    func apply(_ session: PastSession) {
        if let index = results.firstIndex(where: { $0.id == session.id }) { results[index] = session }
    }
}

extension PastSession {
    /// A change as the demo makes it.
    func applying(_ change: HistoryChange) -> PastSession {
        let custom = change.title.map { $0.isEmpty ? nil : $0 } ?? customTitle
        return PastSession(id: id, agent: agent, title: custom ?? title, project: project, cwd: cwd, branch: branch,
                           firstAt: firstAt, lastAt: lastAt, snippet: snippet, snippetUUID: snippetUUID, parentID: parentID,
                           pinned: change.pinned ?? pinned, archived: change.archived ?? archived, customTitle: custom)
    }

    var isPinned: Bool { pinned ?? false }
    var isArchived: Bool { archived ?? false }
}
