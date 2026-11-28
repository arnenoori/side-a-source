import SideAProtocol
import SwiftUI

/// A session that is starting, in the list: the row it will keep once the Mac lists it.
struct LaunchRow: View {
    let model: SessionStore
    let launch: Launch
    @State private var hovering = false

    var body: some View {
        Button { model.select(launch.id) } label: {
            HStack(spacing: 7) {
                Group {
                    switch launch.state {
                    case .failed: Image(systemName: "exclamationmark.circle.fill").font(.subheadline).foregroundStyle(.red)
                    case .attention: Beacon(tint: Ink.amber)
                    case .launching, .booting: WorkingMark()
                    }
                }
                .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(launch.title).font(.body).lineLimit(1)
                        if launch.request.agent == .codex { CodexMark() }
                    }
                    Text(line).font(.subheadline).foregroundStyle(tint).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, 4).padding(.trailing, 9).frame(height: 40)
            .modifier(RowPlate(selected: model.desk.selectedLaunch == launch.id, hovering: $hovering) {})
        }
        .buttonStyle(.plain)
        .contextMenu {
            if launch.settled {
                Button("Try Again") { model.retry(launch.id) }
                Button("Edit…") { model.edit(launch.id) }
            }
            if launch.hosted != nil { Button("Show in Terminal") { model.showLaunch(launch.id) } }
            if launch.settled { Button("Remove") { model.dismiss(launch.id) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(launch.title), \(line)")
        .accessibilityAddTraits(.isButton)
    }

    private var line: String {
        switch launch.state {
        case .launching, .booting: "Starting"
        case .attention(let kind, let text): kind == "trust" ? "Asks to trust the folder" : text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Waiting at a prompt"
        case .failed(let message): message
        }
    }

    private var tint: Color {
        switch launch.state {
        case .failed: .red
        case .attention: Ink.amber
        case .launching, .booting: .secondary
        }
    }
}

/// A session that is starting, in the window: what was asked for, and whatever stands between it and its first turn.
struct LaunchPane: View {
    let model: SessionStore
    let launch: Launch
    @State private var height = ComposerField.lineHeight

    private var folder: String { URL(fileURLWithPath: launch.request.cwd).lastPathComponent }
    private var slow: Bool { launch.bootedAt.map { Date.now.timeIntervalSince($0) >= LaunchPane.slowAfter } ?? false }
    /// After this long the terminal is offered first: something is probably waiting there.
    static let slowAfter: TimeInterval = 30

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(launch.title).font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(folder)  ·  \(launch.request.agent.title)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            Rectangle().fill(Ink.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let prompt = launch.request.prompt, !prompt.isEmpty {
                        Text(prompt).font(.body).textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    TimelineView(.periodic(from: .now, by: 5)) { _ in status }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if !launch.settled { held }
        }
        .animation(Ink.ease, value: launch.state)
    }

    @ViewBuilder private var status: some View {
        switch launch.state {
        case .launching, .booting:
            HStack(spacing: 10) {
                WorkingMark()
                Text("Starting").foregroundStyle(.secondary)
                if launch.hosted != nil {
                    Button("Show in Terminal") { model.showLaunch(launch.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(slow ? Color.accentColor : nil)
                }
            }
        case .attention(let kind, let text):
            VStack(alignment: .leading, spacing: 10) {
                Label(kind == "trust" ? "Trust this folder?" : "Waiting at a prompt", systemImage: kind == "trust" ? "lock.shield" : "rectangle.and.text.magnifyingglass")
                    .font(.headline)
                Text(text).font(kind == "trust" ? .body : .system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if kind == "trust", launch.request.agent == .claude {
                        Button("Trust and Start") { model.trust(launch.id) }.buttonStyle(.borderedProminent)
                    }
                    Button("Show in Terminal") { model.showLaunch(launch.id) }.buttonStyle(.bordered)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.amber.opacity(0.5)))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Try Again") { model.retry(launch.id) }.buttonStyle(.borderedProminent)
                    Button("Edit…") { model.edit(launch.id) }.buttonStyle(.bordered)
                    if launch.hosted != nil { Button("Show in Terminal") { model.showLaunch(launch.id) }.buttonStyle(.bordered) }
                    Button("Remove") { model.dismiss(launch.id) }.buttonStyle(.bordered)
                }
            }
        }
    }

    /// What is typed here while the session starts is its draft when it arrives.
    private var held: some View {
        let text = Binding(get: { model.desk.held[launch.id] ?? "" }, set: { model.desk.held[launch.id] = $0 })
        return ComposerField(text: text, height: $height, placeholder: "Next message…", onKey: { _ in false },
                             wantsFocus: model.desk.composerFocus != model.desk.composerTaken,
                             onFocus: { model.desk.composerTaken = model.desk.composerFocus })
            .frame(height: height)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Ink.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .help("Kept for this session: it is in the message field when the session has started.")
    }
}
