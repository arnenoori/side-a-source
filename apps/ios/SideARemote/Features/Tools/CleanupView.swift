import SideAProtocol
import SwiftUI

/// The Mac's Clean Up, pushed inside the Mac sheet: what conversations take on disk,
/// Archive Older Than, Restore Archived, and the worktrees no session uses. Removal never forces; a
/// worktree the Mac keeps says why instead of offering Remove.
struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var report: CleanupReport?
    @State private var error: String?
    @State private var days = 30
    @State private var confirmingArchive = false
    @State private var confirmingRestore = false
    @State private var removing: CleanupReport.LeftWorktree?
    @State private var busy = false
    @State private var done: String?
    @State private var successes = 0
    @State private var failures = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let report {
                form(report)
            } else if let error {
                ContentUnavailableView("Can't Clean Up", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Clean Up")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: successes)
        .sensoryFeedback(.error, trigger: failures)
        // The Mac's fresh report after a change: its counts roll and the footer crossfades.
        .animation(Motion.smooth(reduceMotion), value: report)
        .animation(Motion.smooth(reduceMotion), value: done)
        .task { await load() }
        .refreshable { await load() }
    }

    private func form(_ report: CleanupReport) -> some View {
        let archivable = report.archivable.first { $0.olderThanDays == days }
        return Form {
            Section {
                LabeledContent("Conversations") {
                    Text("\(report.conversations) · \(Self.bytes(report.conversationBytes))")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                if report.archived > 0 {
                    LabeledContent("Archived") { Text("\(report.archived)").monospacedDigit().contentTransition(.numericText()) }
                }
            } footer: {
                if let done { Text(done).contentTransition(.opacity) }
            }
            Section {
                Picker("Archive Older Than", selection: $days) {
                    ForEach(report.archivable.map(\.olderThanDays), id: \.self) { Text("\($0) days").tag($0) }
                }
                if let archivable, archivable.count > 0 {
                    Button("Archive ^[\(archivable.count) conversation](inflect: true)…", systemImage: "archivebox") {
                        confirmingArchive = true
                    }
                    .disabled(busy)
                } else {
                    Text("Nothing older than \(days) days.").foregroundStyle(.secondary)
                }
                if report.archived > 0 {
                    Button("Restore Archived", systemImage: "tray.and.arrow.up") { confirmingRestore = true }
                        .disabled(busy)
                }
            } footer: {
                if let archivable, archivable.count > 0 {
                    Text("Frees \(Self.bytes(archivable.bytes))")
                }
            }
            .confirmationDialog("Archive ^[\(archivable?.count ?? 0) conversation](inflect: true) older than \(days) days?",
                                isPresented: $confirmingArchive, titleVisibility: .visible) {
                Button("Archive") { run { "Archived \(try await model.tools.archive(olderThanDays: days))." } }
            } message: {
                Text("Restore Archived brings them back.")
            }
            .confirmationDialog("Restore ^[\(report.archived) archived conversation](inflect: true)?",
                                isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button("Restore") { run { "Restored \(try await model.tools.restoreArchived())." } }
            }
            Section("Left-Behind Worktrees") {
                if report.worktrees.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(report.worktrees) { worktree in
                    WorktreeRow(worktree: worktree)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if worktree.keep == nil {
                                Button("Remove…", systemImage: "trash", role: .destructive) { removing = worktree }
                            }
                        }
                        .contextMenu {
                            if worktree.keep == nil {
                                Button("Remove…", systemImage: "trash", role: .destructive) { removing = worktree }
                            }
                            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = worktree.path }
                        }
                }
            }
        }
        .confirmationDialog("Remove this worktree?", isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
                            titleVisibility: .visible, presenting: removing) { worktree in
            Button("Remove Worktree", role: .destructive) {
                run {
                    try await model.tools.removeWorktree(worktree.id)
                    return "Removed \(worktree.path.abbreviatingHome)."
                }
            }
        } message: { worktree in
            Text("\(worktree.path.abbreviatingHome) goes; its branch stays.")
        }
    }

    private func load() async {
        guard !model.isDemo else {
            report = CleanupReport(conversationBytes: 1_480_000_000, conversations: 412,
                                   archivable: [.init(olderThanDays: 30, count: 96, bytes: 610_000_000),
                                                .init(olderThanDays: 60, count: 51, bytes: 340_000_000),
                                                .init(olderThanDays: 90, count: 22, bytes: 120_000_000)],
                                   archived: 0,
                                   worktrees: [.init(id: "w1", path: "~/Coding/side-a/.claude/worktrees/island", branch: "sidea/island", bytes: 84_000_000),
                                               .init(id: "w2", path: "~/Coding/storefront/.worktrees/rank", branch: "rank", bytes: 12_000_000,
                                                     keep: .ignoredFiles, keepReason: "Holds .env")])
            return
        }
        do {
            report = try await model.tools.cleanup()
            error = nil
            if let first = report?.archivable.first?.olderThanDays, report?.archivable.contains(where: { $0.olderThanDays == days }) == false {
                days = first
            }
        } catch {
            self.error = MacTools.message(error)
        }
    }

    /// One change, then the Mac's fresh report.
    private func run(_ work: @escaping () async throws -> String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                done = try await work()
                successes += 1
            } catch {
                done = MacTools.message(error)
                failures += 1
            }
            await load()
        }
    }

    static func bytes(_ count: Int) -> String { count.formatted(.byteCount(style: .file)) }
}

private struct WorktreeRow: View {
    let worktree: CleanupReport.LeftWorktree

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(worktree.path.abbreviatingHome)
                .font(.callout.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: Space.xs) {
                if let branch = worktree.branch { Text(branch).font(.footnote.monospaced()) }
                if let bytes = worktree.bytes { Text(CleanupView.bytes(bytes)).font(.footnote.monospacedDigit()) }
            }
            .foregroundStyle(.secondary)
            if worktree.keep != nil {
                Label(worktree.keepReason ?? "Kept on the Mac", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
