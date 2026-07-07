import SwiftData
import SwiftUI

/// v1.1 §3.4 — Focus mode: one tap collapses the UI into a single card with
/// the one next action in huge type and one confirm button. For overwhelm
/// moments. Derivation is honest: it surfaces what the conversation actually
/// asks for next (a hand-off to open, a question to answer, or "ask for one
/// thing") — it never invents an action.
struct FocusModeView: View {
    let session: ChatSession
    var onExit: () -> Void

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.openURL) private var openURL

    private var profile: AccessibilityProfile { profileStore.profile }

    private struct NextStep {
        var heading: String
        var title: String
        var detail: String?
        var actionLabel: String
        var url: URL?      // nil → the confirm button exits back to chat
    }

    var body: some View {
        VStack(spacing: Theme.spacing * 2) {
            HStack {
                Spacer()
                Button(action: onExit) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Exit focus mode")
            }

            Spacer()

            let step = nextStep
            Text(step.heading)
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            // Huge type; scales further with Dynamic Type and reflows.
            Text(step.title)
                .font(.system(.largeTitle, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = step.detail {
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // The one confirm button.
            Button {
                Haptics.shared.play(.confirmed, enabled: profile.hapticsEnabled)
                if let url = step.url {
                    openURL(url)
                } else {
                    onExit()
                }
            } label: {
                Text(step.actionLabel)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .frame(minHeight: 64)
            }
            .background(Theme.brandGradient(highContrast: profile.highContrast), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .foregroundStyle(.white)
            .accessibilityHint(step.url != nil ? "Opens another app. CEA doesn't complete the action for you." : "Returns to the chat.")
        }
        .padding(24)
        .background(Theme.screenBackground)
        .dynamicTypeSize(profile.largerText
                         ? DynamicTypeSize.accessibility1...DynamicTypeSize.accessibility5
                         : DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5)
    }

    /// The one next action, derived from the conversation:
    /// 1. A card rendered since the user's last message (this turn's ask) —
    ///    hand-off cards yield a real open-the-app button; confirm/choice
    ///    cards point back to the chat.
    /// 2. Otherwise the most recent assistant message (the thing to answer).
    /// 3. Otherwise: ask CEA for one thing.
    private var nextStep: NextStep {
        let messages = session.sortedMessages
        let lastUserIndex = messages.lastIndex(where: { $0.role == .user })

        let currentTurn = lastUserIndex.map { Array(messages[($0 + 1)...]) } ?? messages
        for message in currentTurn.reversed() {
            guard let card = message.card else { continue }
            switch card {
            case .handoff(let handoff):
                if let action = handoff.actions.first, let url = action.url {
                    return NextStep(
                        heading: "Next step",
                        title: action.label,
                        detail: action.detail ?? "You confirm in the app that opens — CEA never does.",
                        actionLabel: "Open now",
                        url: url
                    )
                }
            case .rideConfirm(let ride):
                return NextStep(
                    heading: "Next step",
                    title: ride.summary,
                    detail: "CEA needs your yes before preparing the links.",
                    actionLabel: "Answer in chat",
                    url: nil
                )
            case .topThree(let top):
                return NextStep(
                    heading: "Next step",
                    title: top.title ?? "Pick one of the options",
                    detail: "Say or tap your choice in the chat.",
                    actionLabel: "Choose in chat",
                    url: nil
                )
            case .ownAccountConfirm(let confirm):
                if confirm.completed == true { continue } // already done
                return NextStep(
                    heading: "Waiting on you",
                    title: confirm.summary,
                    detail: "Confirm or cancel it on the card in the chat. Nothing runs until you confirm.",
                    actionLabel: "Review in chat",
                    url: nil
                )
            }
        }

        if let lastAssistant = messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
            return NextStep(
                heading: "CEA said",
                title: lastAssistant.text,
                detail: nil,
                actionLabel: "Back to chat",
                url: nil
            )
        }

        return NextStep(
            heading: "Nothing in progress",
            title: "Ask CEA for one thing.",
            detail: "One request at a time — a ride, or food nearby.",
            actionLabel: "Back to chat",
            url: nil
        )
    }
}
