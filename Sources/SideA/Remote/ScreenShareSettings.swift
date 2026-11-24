import AppKit
import SideAProtocol
import SwiftUI

struct ScreenShareSection: View {
    let share: ScreenShare

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { share.on }, set: { share.setOn($0) })) {
                Text("Show this Mac's screen on iPhone")
                Text("Face ID on the iPhone each time it opens. macOS shows that the screen is being recorded.")
            }
            if share.on {
                if !share.recording {
                    LabeledContent {
                        Button("Open Settings") { NSWorkspace.shared.open(ScreenShare.recordingSettings) }
                    } label: {
                        warning("Allow Side A in Screen Recording")
                        Text("Then quit and reopen Side A.")
                    }
                }
                Toggle(isOn: Binding(get: { share.control }, set: { share.setControl($0) })) {
                    Text("Allow clicks and typing from iPhone")
                    Text("Off, the iPhone can only watch.")
                }
                if share.control, !share.accessibility {
                    LabeledContent {
                        Button("Open Settings") { NSWorkspace.shared.open(ScreenShare.accessibilitySettings) }
                    } label: {
                        warning("Allow Side A in Accessibility")
                        Text("Until then the iPhone can only watch.")
                    }
                }
                if let watcher = share.watcher {
                    LabeledContent {
                        Button("End") { share.end() }
                    } label: {
                        Label {
                            Text("\(watcher.name) is \(watcher.mode == .control && share.control ? "controlling" : "watching")")
                            Text("Since \(watcher.since.formatted(date: .omitted, time: .shortened))" + (watcher.route == .relay ? " · through the relay" : ""))
                        } icon: {
                            Image(systemName: "display").foregroundStyle(.purple)
                        }
                    }
                }
            }
        } header: {
            Text("Screen")
        }
        .task {
            // Permissions are granted in System Settings, which tells no one; asked again while this is open.
            while !Task.isCancelled {
                share.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
    }
}

struct ScreenShareLine: View {
    let share: ScreenShare

    var body: some View {
        if let watcher = share.watcher {
            HStack(spacing: 6) {
                Image(systemName: "display").foregroundStyle(.purple)
                Text("\(watcher.name) is \(watcher.mode == .control && share.control ? "controlling" : "viewing") this screen").lineLimit(1)
                Spacer()
                Button("End") { share.end() }.controlSize(.small)
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityElement(children: .combine)
        }
    }
}
