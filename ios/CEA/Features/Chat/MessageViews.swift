import SwiftUI

/// One transcript row: user bubble, assistant bubble, notice line, or card.
/// Bubbles reflow with Dynamic Type (no fixed heights) and are single
/// VoiceOver elements — one swipe per message (PRD §9).
struct MessageRow: View {
    let message: ChatMessage
    let profile: AccessibilityProfile
    var reduceMotion: Bool
    var onOpenURL: (URL) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent(highContrast: profile.highContrast),
                                in: RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")

        case .assistant:
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if !message.text.isEmpty {
                    HStack {
                        Text(message.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.assistantBubble,
                                        in: RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                        Spacer(minLength: 40)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("CEA: \(message.text)")
                }
                if let card = message.card {
                    CardView(card: card, profile: profile, reduceMotion: reduceMotion, onOpenURL: onOpenURL)
                }
            }

        case .notice:
            // Visible confirmation line (memory writes, errors). Icon + text,
            // not color alone.
            Label(message.text, systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
        }
    }
}

/// The instant acknowledgment + working indicator (§3.5): appears the moment
/// input is received — the visual twin of the "heard you" haptic — and stays
/// until the first streamed token replaces it. Motion routes through the
/// helper; under Reduce Motion it is a static label.
struct ThinkingIndicator: View {
    var reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.bubble")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Heard you — on it")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !reduceMotion {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(pulse ? 1.0 : 0.55)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                            value: pulse
                        )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.assistantBubble, in: RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
        .onAppear { pulse = true }
        .accessibilityLabel("Heard you. CEA is working on it.")
    }
}
