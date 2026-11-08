import SwiftUI

/// The Mac chip's sheet: status, power, memory, Keep Awake, Quit Idle, Clean Up.
struct MacSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keepAwakeError: String?
    @State private var keepAwakeTaps = 0

    var body: some View {
        let mac = model.mac
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            ConnectionDot(state: mac.state)
                            Text(mac.status)
                        }
                    }
                    LabeledContent("Last seen") {
                        if mac.state == .live {
                            Text("Now")
                        } else {
                            Text(mac.lastSeen, format: .relative(presentation: .named))
                        }
                    }
                    LabeledContent("Power", value: mac.onPower ? "On power" : "On battery · \(mac.battery ?? 0)%")
                    LabeledContent("Memory") {
                        Text(String(format: "%.1f of %.0f GB", mac.memoryUsed, mac.memoryTotal)).monospacedDigit()
                    }
                }
                if model.tools.can(.mac) {
                    Section {
                        Toggle("Keep Awake While Agents Work", systemImage: "cup.and.saucer", isOn: keepAwake)
                            .tint(.green)
                    } footer: {
                        if let keepAwakeError { Text(keepAwakeError).foregroundStyle(.red) }
                    }
                }
                Section {
                    QuitIdleButton()
                    if model.tools.can(.cleanup) {
                        NavigationLink { CleanupView() } label: { Label("Clean Up", systemImage: "trash.slash") }
                    }
                }
            }
            .sessionActions()
            .sensoryFeedback(.selection, trigger: keepAwakeTaps)
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The Mac's own setting: shown flipped at once, and set back if the Mac says no.
    private var keepAwake: Binding<Bool> {
        Binding { model.mac.keepAwake } set: { on in
            let mac = model.mac, tools = model.tools
            mac.keepAwake = on
            keepAwakeError = nil
            keepAwakeTaps += 1
            guard !model.isDemo else { return }
            Task {
                do {
                    mac.keepAwake = try await tools.setKeepAwake(on).keepAwake
                } catch {
                    mac.keepAwake = !on
                    keepAwakeError = MacTools.message(error)
                }
            }
        }
    }
}
