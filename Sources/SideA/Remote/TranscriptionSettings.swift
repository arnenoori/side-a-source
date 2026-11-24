import SwiftUI

/// Settings > iPhone > Dictation: the OpenAI key the phone's dictation goes through, shown masked once saved, the
/// model, and a Test that sends a short phrase only when pressed.
struct TranscriptionSection: View {
    var transcription: RemoteTranscription
    @State private var entered = ""
    @State private var model = ""

    var body: some View {
        Section {
            if transcription.hasKey {
                LabeledContent("OpenAI key") {
                    HStack {
                        Text(transcription.masked ?? "").monospaced().foregroundStyle(.secondary).accessibilityLabel("Saved")
                        Button("Remove") { transcription.remove() }
                    }
                }
            } else {
                HStack {
                    SecureField("OpenAI key", text: $entered, prompt: Text("sk-…"))
                        .onSubmit(save)
                    Button("Save", action: save).disabled(entered.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack {
                TextField("Model", text: $model)
                    .onSubmit { transcription.setModel(model) }
                Menu {
                    ForEach(RemoteTranscription.presets, id: \.self) { preset in
                        Button(preset) { model = preset; transcription.setModel(preset) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Models")
            }
            LabeledContent {
                Button("Test") { Task { await transcription.runTest() } }
                    .disabled(!transcription.hasKey || transcription.test == .running)
            } label: {
                testLine
            }
        } header: {
            Text("Dictation")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = transcription.error { Text(error).foregroundStyle(.red) }
                Text("The iPhone's recordings come to this Mac, which sends them to OpenAI and passes the words back. Neither is kept. Without a key, or away from this Mac, the iPhone transcribes on its own.")
            }
        }
        .onAppear {
            transcription.load()
            model = transcription.model
        }
        .onChange(of: model) { _, new in if RemoteTranscription.presets.contains(new) { transcription.setModel(new) } }
        .onDisappear { transcription.setModel(model) }
    }

    private func save() {
        transcription.save(entered)
        entered = ""
    }

    @ViewBuilder private var testLine: some View {
        switch transcription.test {
        case .idle:
            Text("Test the key")
            Text("Sends one spoken phrase to OpenAI.")
        case .running:
            Text("Testing…")
        case .heard(let text):
            Label { Text(text.isEmpty ? "The key works" : "Heard “\(text)”").lineLimit(2) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        case .failed(let message):
            Label { Text(message).lineLimit(3) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
        }
    }
}
