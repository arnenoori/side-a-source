import SideAProtocol
import SideARemoteShared
import SwiftUI

/// Checkpoints this host keeps of another computer's sessions, under its own. Nothing runs from them until one is continued
/// here as a copy.
struct StandbySection: View {
    let query: String
    @Environment(AppModel.self) private var model

    static func matches(_ copy: StandbyCopy, _ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            [copy.title, copy.project, copy.computerName].compactMap { $0 }.contains { $0.localizedStandardContains(word) }
        }
    }

    var body: some View {
        let rows = model.standbyRows.filter { Self.matches($0, query) }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { StandbyRow(copy: $0) }
            } header: {
                Text("Checkpoints").foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

struct StandbyRow: View {
    let copy: StandbyCopy
    @Environment(AppModel.self) private var model
    @Environment(AppRoot.self) private var root
    @Environment(SessionActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirming = false

    private var busy: Bool { actions.isBusy(SessionActions.copyKey(copy)) }
    private var taken: Date { Date(timeIntervalSince1970: copy.at) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: root.model(for: copy.computer)?.mac.symbol ?? "desktopcomputer")
                .foregroundStyle(.tertiary)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(StandbyText.title(copy))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    ElapsedText(since: taken, live: false)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: Space.xxs) {
                    Image(systemName: copy.agent.symbol).imageScale(.small)
                    Text(StandbyText.from(copy)).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                action.padding(.top, Space.xxs)
            }
        }
        .animation(Motion.smooth(reduceMotion), value: busy)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(StandbyText.title(copy)), \(StandbyText.from(copy)), \(Formatting.elapsed(since: taken))")
        .accessibilityValue(busy ? "Continuing" : "")
        .accessibilityActions { continueButton }
        .contextMenu { continueButton }
        .confirmationDialog("Continue as a Copy?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Continue as a Copy") { actions.on(model).continueCopy(copy) }
        } message: {
            Text(StandbyText.warning(copy))
        }
    }

    @ViewBuilder private var action: some View {
        if busy {
            ProgressView()
                .controlSize(.small)
                .frame(minHeight: 28)
        } else {
            Button("Continue as a Copy…") { confirming = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .needsMac()
        }
    }

    @ViewBuilder private var continueButton: some View {
        if !busy {
            Button("Continue as a Copy…", systemImage: "arrow.triangle.branch") { confirming = true }.needsMac()
        }
    }
}

extension SessionActions {
    static func copyKey(_ copy: StandbyCopy) -> String { "copy-\(copy.conversationID)" }

    /// Face ID, then the copy, which opens the way a started session does: as soon as this host lists it.
    func continueCopy(_ copy: StandbyCopy) {
        let standby = model
        run(Self.copyKey(copy), working: "Continuing", failed: "Couldn't Continue") { tools in
            self.started = try await tools.continueCopy(copy)
            await standby?.refreshSessions()
        }
    }
}
