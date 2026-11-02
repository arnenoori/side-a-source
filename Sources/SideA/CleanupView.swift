import SwiftUI

struct DiskReport: Decodable, Sendable {
    struct Project: Decodable, Sendable { let folder: String; let path: String?; let bytes: Int64; let conversations: Int }
    struct Old: Decodable, Sendable { let days: Double; let count: Int; let bytes: Int64 }
    struct Archived: Decodable, Sendable { let count: Int; let bytes: Int64 }
    let total: Int64
    let claude: Int64
    let codex: Int64
    let projects: [Project]
    /// Every conversation, not only the 30 largest projects'.
    var conversations: Int? = nil
    let old: Old
    let archived: Archived
}

struct Worktree: Decodable, Sendable, Identifiable {
    let repo: String
    let path: String
    let branch: String?
    let locked: Bool
    let missing: Bool
    let dirty: Bool?
    let merged: Bool?
    let age: Double?
    var inUse: Bool? = nil
    /// Set where git would remove it but work would be lost, such as a detached commit or an ignored .env.
    var refused: String? = nil
    var regenerable: [String]? = nil
    var id: String { path }
    var stale: Bool { inUse != true && (merged == true || (age ?? 0) >= 7 * 86400) }
    /// Why Remove is off; Side A never passes --force.
    var blocked: (label: String, reason: String)? {
        if missing { return ("folder is gone", "The folder is gone.") }
        if locked { return ("locked", "Locked with git worktree lock.") }
        if inUse == true { return ("in use", "A session is working here.") }
        if let refused { return ("kept", refused) }
        if dirty != false { return dirty == nil ? ("status unknown", "git status failed here.") : ("has changes", "Has changes or untracked files.") }
        return nil
    }
}

@MainActor @Observable
final class CleanupModel {
    let sessions: SessionStore
    var store: AccountStore { sessions.store }
    var disk: DiskReport?
    var worktrees: [Worktree]?
    var busy = false
    var message: String?
    let days = 90.0

    init(sessions: SessionStore) { self.sessions = sessions }

    func load() async {
        if store.isDemo {
            disk = Self.demoDisk; worktrees = Self.demoWorktrees
            return
        }
        async let diskData = try? store.bridgeOutput(["cleanup", "disk", "--days", String(days)] + keep, timeout: 180, priority: .userInitiated)
        async let treeData = try? store.bridgeOutput(["cleanup", "worktrees"], timeout: 300, priority: .userInitiated)
        disk = (await diskData).flatMap { try? JSONDecoder().decode(DiskReport.self, from: $0) }
        worktrees = (await treeData).flatMap { try? JSONDecoder().decode([String: [Worktree]].self, from: $0)["worktrees"] } ?? []
    }

    private var keep: [String] { sessions.pins.flatMap { ["--keep", $0] } }

    func archive() async {
        struct Moved: Decodable { let path: String }
        struct Result: Decodable { let bytes: Int64; let moved: [Moved]; let errors: [String]? }
        guard !store.isDemo else { message = "Preview: nothing was moved."; return }
        busy = true; defer { busy = false }
        do {
            let result = try JSONDecoder().decode(Result.self, from: try await store.bridgeOutput(["cleanup", "archive", "--days", String(days)] + keep, timeout: 600))
            message = "Moved \(result.moved.count) conversations, \(result.bytes.formatted(.byteCount(style: .file))), to Side A's archive."
            if let errors = result.errors, let first = errors.first {
                message! += " \(errors.count) could not be moved (\(first)\(errors.count > 1 ? ", …" : ""))."
            }
        } catch { message = (error as? BridgeFailure)?.message ?? error.localizedDescription }
        await load()
    }

    func restore() async {
        struct Result: Decodable { let restored: [String]; let skipped: [String] }
        guard !store.isDemo else { message = "Preview: nothing was moved."; return }
        busy = true; defer { busy = false }
        do {
            let result = try JSONDecoder().decode(Result.self, from: try await store.bridgeOutput(["cleanup", "restore"], timeout: 600))
            message = "Restored \(result.restored.count) conversations" + (result.skipped.isEmpty ? "." : "; \(result.skipped.count) stayed archived because a file with that name is back.")
        } catch { message = (error as? BridgeFailure)?.message ?? error.localizedDescription }
        await load()
    }

    func remove(_ tree: Worktree) async {
        struct Result: Decodable { let removed: Bool; let error: String? }
        guard !store.isDemo else { worktrees?.removeAll { $0.id == tree.id }; return }
        busy = true; defer { busy = false }
        do {
            let result = try JSONDecoder().decode(Result.self, from: try await store.bridgeOutput(["cleanup", "remove-worktree", tree.path], timeout: 60))
            if result.removed { worktrees?.removeAll { $0.id == tree.id } } else { message = result.error ?? "git refused to remove it." }
        } catch { message = (error as? BridgeFailure)?.message ?? error.localizedDescription }
    }

    static let demoDisk = DiskReport(total: 2_840_000_000, claude: 2_310_000_000, codex: 530_000_000,
        projects: [.init(folder: "-demo-app", path: "~/Code/demo-app", bytes: 1_200_000_000, conversations: 412),
                   .init(folder: "-demo-site", path: "~/Code/demo-site", bytes: 640_000_000, conversations: 188),
                   .init(folder: "-demo-cli", path: "~/Code/demo-cli", bytes: 470_000_000, conversations: 96)],
        old: .init(days: 90, count: 318, bytes: 1_050_000_000), archived: .init(count: 0, bytes: 0))
    static let demoWorktrees = [
        Worktree(repo: "~/Code/demo-app", path: "~/Code/demo-app/.claude/worktrees/search", branch: "search", locked: false, missing: false, dirty: false, merged: true, age: 12 * 86400, inUse: false, regenerable: ["node_modules"]),
        Worktree(repo: "~/Code/demo-app", path: "~/Code/demo-app/.claude/worktrees/island", branch: "island", locked: false, missing: false, dirty: true, merged: false, age: 9 * 86400),
        Worktree(repo: "~/Code/demo-site", path: "~/Code/demo-site-pricing", branch: "pricing", locked: false, missing: false, dirty: false, merged: false, age: 3600, inUse: true)]
}


struct CleanupView: View {
    @State private var model: CleanupModel
    @State private var archiving = false
    @State private var removing: Worktree?
    @Environment(\.dismiss) private var dismiss

    init(sessions: SessionStore) { _model = State(initialValue: CleanupModel(sessions: sessions)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    diskSection
                    Divider()
                    worktreeSection
                }
                .padding(20)
            }
            Divider()
            HStack {
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 500, height: 520)
        .task { await model.load() }
        .confirmationDialog("Archive old conversations?", isPresented: $archiving) {
            Button("Archive Conversations") { Task { await model.archive() } }
        } message: {
            Text("Conversations untouched for \(Int(model.days)) days move to Side A's archive folder. Pinned and running sessions stay. Nothing is deleted, and Restore puts them back.")
        }
        .confirmationDialog("Remove this worktree?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { tree in
            Button("Remove Worktree", role: .destructive) { Task { await model.remove(tree) } }
        } message: { tree in
            let kept = tree.branch.map { "The branch \($0) stays in the repository." } ?? "Its commit stays on the branches and tags that hold it."
            let also = (tree.regenerable ?? []).isEmpty ? "" : "\nAlso deletes \((tree.regenerable ?? []).joined(separator: ", ")), which a build or install brings back."
            Text("git worktree remove \(tree.path)\n\(kept)\(also)")
        }
    }

    @ViewBuilder private var diskSection: some View {
        Text("Conversations on disk").font(.headline)
        if let disk = model.disk {
            Text("\(disk.total.formatted(.byteCount(style: .file))) · Claude \(disk.claude.formatted(.byteCount(style: .file))) · Codex \(disk.codex.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
            let top = disk.projects.prefix(8)
            let largest = max(top.first?.bytes ?? 1, 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(top, id: \.folder) { project in
                    HStack(spacing: 10) {
                        Text(URL(fileURLWithPath: project.path ?? project.folder).lastPathComponent)
                            .lineLimit(1).frame(width: 150, alignment: .leading).help(project.path ?? project.folder)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.6))
                                .frame(width: max(2, geometry.size.width * CGFloat(project.bytes) / CGFloat(largest)))
                        }
                        .frame(height: 8)
                        Text(project.bytes.formatted(.byteCount(style: .file))).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack {
                Button("Archive Older Than \(Int(model.days)) Days…") { archiving = true }
                    .disabled(disk.old.count == 0 || model.busy)
                Text("\(disk.old.count) conversations, \(disk.old.bytes.formatted(.byteCount(style: .file)))").foregroundStyle(.secondary)
            }
            if disk.archived.count > 0 {
                HStack {
                    Button("Restore Archived") { Task { await model.restore() } }.disabled(model.busy)
                    Text("\(disk.archived.count) archived, \(disk.archived.bytes.formatted(.byteCount(style: .file)))").foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var worktreeSection: some View {
        Text("Git worktrees").font(.headline)
        if let trees = model.worktrees {
            if trees.isEmpty {
                Text("No extra worktrees in the repositories your sessions ran in.").foregroundStyle(.secondary)
            }
            let groups = [("Merged or untouched for a week", trees.filter(\.stale)), ("Active", trees.filter { !$0.stale })]
            ForEach(groups, id: \.0) { title, items in
                if !items.isEmpty {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(items) { tree in row(tree) }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func row(_ tree: Worktree) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tree.branch ?? URL(fileURLWithPath: tree.path).lastPathComponent).lineLimit(1)
                Text(tree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(details(tree)).font(.caption).foregroundStyle(.secondary)
            Button("Remove…") { removing = tree }
                .disabled(tree.blocked != nil || model.busy)
                .help(tree.blocked?.reason ?? "Remove with git worktree remove")
                .accessibilityHint(tree.blocked?.reason ?? "")
        }
    }

    private func details(_ tree: Worktree) -> String {
        var parts: [String] = []
        if tree.merged == true { parts.append("merged") }
        if let blocked = tree.blocked { parts.append(blocked.label) }
        if let age = tree.age { parts.append(Date(timeIntervalSinceNow: -age).formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}
