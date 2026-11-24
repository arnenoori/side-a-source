import SideAProtocol
import SwiftUI

struct ProjectPicker: View {
    @Binding var selection: RemoteProject?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matching: [RemoteProject] {
        let all = model.tools.projects
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var recent: [RemoteProject] {
        query.isEmpty ? Array(matching.filter { $0.lastUsedAt != nil }.sorted { $0.lastUsedAt! > $1.lastUsedAt! }.prefix(5)) : []
    }

    var body: some View {
        List {
            if !recent.isEmpty {
                Section("Recent") { ForEach(recent) { row($0) } }
            }
            Section(recent.isEmpty ? "" : "All Folders") {
                ForEach(matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { row($0) }
            }
        }
        .overlay {
            if matching.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Folders")
        .navigationTitle("Folder")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ project: RemoteProject) -> some View {
        Button {
            selection = project
            dismiss()
        } label: {
            HStack {
                ProjectRow(project: project)
                if selection?.id == project.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
        }
        .tint(.primary)
    }
}

struct ProjectRow: View {
    let project: RemoteProject

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: project.gitRoot == nil ? "folder" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(project.name).font(.body)
                    if let branch = project.branch {
                        Text(branch)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: .capsule)
                    }
                }
                Text(project.path.abbreviatingHome)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension String {
    var abbreviatingHome: String {
        let parts = split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 2, parts[1] == "Users" else { return self }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }
}
