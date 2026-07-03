import SwiftUI

/// Text + dictation input. Mic prominence is profile-driven (PRD F2): for
/// voice-first profiles the mic is the primary, larger control.
struct InputBar: View {
    @Binding var text: String
    var voiceFirst: Bool
    var highContrast: Bool
    var reduceMotion: Bool
    var isSending: Bool
    var onSend: () -> Void

    @State private var dictation = DictationService()

    var body: some View {
        VStack(spacing: 4) {
            if let error = dictation.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                if voiceFirst { micButton }

                TextField("Message CEA", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .onSubmit(submit)
                    .disabled(isSending)
                    .accessibilityLabel("Message CEA")

                if !voiceFirst { micButton }
                sendButton
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: dictation.transcript) { _, newValue in
            if !newValue.isEmpty { text = newValue }
        }
    }

    private var micSize: CGFloat { voiceFirst ? 64 : Theme.minTapTarget }

    private var micButton: some View {
        Button {
            HapticsService.tap(enabled: true)
            dictation.toggle()
        } label: {
            Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                .font(voiceFirst ? .title : .title3)
                .frame(width: micSize, height: micSize)
                .background(
                    dictation.isRecording
                        ? AnyShapeStyle(Color.red)
                        : AnyShapeStyle(Theme.brandGradient(highContrast: highContrast)),
                    in: Circle()
                )
                .foregroundStyle(.white)
                .scaleEffect(dictation.isRecording && !reduceMotion ? 1.08 : 1.0)
                .animation(Motion.snappy(reduceMotion: reduceMotion), value: dictation.isRecording)
        }
        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate a message")
        .accessibilityHint(dictation.isRecording ? "Stops listening and keeps the text" : "Speak instead of typing")
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                .background(
                    canSend
                        ? AnyShapeStyle(Theme.accent(highContrast: highContrast))
                        : AnyShapeStyle(Color(.systemGray4)),
                    in: Circle()
                )
                .foregroundStyle(.white)
                .scaleEffect(canSend && !reduceMotion ? 1.0 : 0.94)
                .animation(Motion.snappy(reduceMotion: reduceMotion), value: canSend)
        }
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func submit() {
        guard canSend else { return }
        if dictation.isRecording { dictation.stop() }
        onSend()
    }
}
