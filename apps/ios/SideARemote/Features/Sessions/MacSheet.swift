import SwiftUI

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
                            ConnectionDot(state: mac.shown)
                            Text(mac.status)
                        }
                    }
                    LabeledContent("Last seen") {
                        if mac.shown == .live {
                            Text("Now")
                        } else {
                            Text(mac.lastSeen, format: .relative(presentation: .named))
                        }
                    }
                    if let onPower = mac.onPower {
                        LabeledContent("Power", value: onPower ? "On power" : "On battery · \(mac.battery ?? 0)%")
                    }
                    if let used = mac.memoryUsed, let total = mac.memoryTotal {
                        LabeledContent("Memory") {
                            Text(String(format: "%.1f of %.0f GB", used, total)).monospacedDigit()
                        }
                    }
                }
                if model.tools.can(.mac), mac.keepAwake != nil {
                    Section {
                        Toggle("Keep Awake While Agents Work", systemImage: "cup.and.saucer", isOn: keepAwake)
                            .tint(.green)
                    } footer: {
                        if let keepAwakeError { Text(keepAwakeError).foregroundStyle(.red) }
                    }
                }
                Section {
                    QuitIdleButton()
                    ScreenButton(title: "Screen")
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
                    Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var keepAwake: Binding<Bool> {
        Binding { model.mac.keepAwake ?? false } set: { on in
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
