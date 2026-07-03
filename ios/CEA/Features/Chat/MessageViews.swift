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

/// Typing indicator while the agent works. Motion routes through the helper;
/// under Reduce Motion it is a static label.
struct ThinkingIndicator: View {
    var reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if reduceMotion {
                Text("Thinking…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
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
        .accessibilityLabel("CEA is thinking")
    }
}
