import Foundation
import os
import SideACore
import SwiftUI

/// A message set aside to send later: ⌘S in a composer takes what is typed there, and gives it back to any composer.
struct Stashed: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var at: Double
}

enum PromptStash {
    static let file = "runtime/prompt-stash.json"
    static let kept = 100
    static let log = Logger(subsystem: "com.sidea.app", category: "stash")

    /// Newest first. The same words stashed again move to the front, and the oldest go past `kept`.
    static func adding(_ text: String, to stash: [Stashed], now: Double = Date().timeIntervalSince1970, id: UUID = UUID()) -> [Stashed] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return stash }
        return Array(([Stashed(id: id, text: text, at: now)] + stash.filter { $0.text != text }).prefix(kept))
    }

    /// A stashed message goes after what is already typed, on its own line.
    static func restoring(_ text: String, into draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + (draft.hasSuffix("\n") ? "" : "\n") + text
    }
}

extension SessionStore {
    private var stashURL: URL { store.root.appendingPathComponent(PromptStash.file) }

    func loadStash() {
        guard !desk.stashRead else { return }
        desk.stashRead = true
        desk.stash = (try? PrivateFile.read([Stashed].self, from: stashURL)) ?? []
    }

    /// ⌘S: what is typed to `id` leaves its composer for the stash.
    func stash(_ id: String) {
        loadStash()
        let next = PromptStash.adding(drafts[id] ?? "", to: desk.stash)
        guard next != desk.stash else { return }
        desk.stash = next
        drafts[id] = nil
        saveStash()
    }

    func unstash(_ item: Stashed, into id: String) {
        drafts[id] = PromptStash.restoring(item.text, into: drafts[id] ?? "")
        dropStashed(item)
        desk.composerFocus += 1
    }

    func dropStashed(_ item: Stashed) {
        desk.stash.removeAll { $0.id == item.id }
        saveStash()
    }

    private func saveStash() {
        do {
            if desk.stash.isEmpty { try? FileManager.default.removeItem(at: stashURL) } else { try PrivateFile.write(desk.stash, to: stashURL) }
        } catch {
            PromptStash.log.error("stash not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The stash, from the tray beside a composer: a click puts a message back, into this composer.
struct StashList: View {
    let model: SessionStore
    let id: String
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.desk.stash) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            model.unstash(item, into: id)
                            close()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text).font(.callout).lineLimit(3).multilineTextAlignment(.leading)
                                Text(Date(timeIntervalSince1970: item.at).formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Puts it back in the message field")
                        Button { model.dropStashed(item) } label: { Image(systemName: "xmark").font(.caption) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Remove")
                            .accessibilityLabel("Remove from stash")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 340)
        .frame(maxHeight: 320)
        .onChange(of: model.desk.stash.isEmpty) { if model.desk.stash.isEmpty { close() } }
    }
}
