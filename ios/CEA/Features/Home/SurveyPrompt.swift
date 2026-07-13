import Foundation
import SwiftData
import SwiftUI

/// v1.1 §3.1 — a queued post-visit survey. Created when a venue hand-off is
/// built; NEVER surfaced mid-task. It waits for a natural, low-pressure
/// moment (a fresh chat on home, a couple of hours after the hand-off) and
/// asks one short, skippable, profile-adapted question.
@Model
final class QueuedSurvey {
    var venueKey: String
    var venueName: String
    var latitude: Double
    var longitude: Double
    var handoffAt: Date
    var dismissed: Bool
    var completedAt: Date?

    init(venueKey: String, venueName: String, latitude: Double, longitude: Double, handoffAt: Date = .now) {
        self.venueKey = venueKey
        self.venueName = venueName
        self.latitude = latitude
        self.longitude = longitude
        self.handoffAt = handoffAt
        self.dismissed = false
        self.completedAt = nil
    }
}

enum SurveyLogic {
    /// Quiet period after the hand-off — long enough that the user isn't
    /// still en route or mid-errand.
    static let minimumDelay: TimeInterval = 2 * 60 * 60

    /// The one survey worth showing right now, or nil. Only ever called
    /// from the home empty state (the non-interrupting moment); prompts can
    /// be disabled entirely in Profile.
    static func eligibleSurvey(
        from surveys: [QueuedSurvey],
        profile: AccessibilityProfile,
        now: Date = .now
    ) -> QueuedSurvey? {
        guard profile.surveyPromptsEnabled else { return nil }
        return surveys
            .filter { !$0.dismissed && $0.completedAt == nil && now.timeIntervalSince($0.handoffAt) >= minimumDelay }
            .sorted { $0.handoffAt < $1.handoffAt }
            .first
    }

    /// The single question to ask, adapted to the profile's priorities.
    static func question(for profile: AccessibilityProfile) -> CrowdAttribute {
        CrowdsourceService.priorityAttributes(for: profile).first ?? .stepFreeEntry
    }
}

/// The one-question survey card shown on the home empty state. Fully
/// dismissible; one tap answers; "don't ask again" turns the feature off.
struct SurveyPromptCard: View {
    @Bindable var survey: QueuedSurvey

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var sending = false
    @State private var errorLine: String?
    @State private var thanked = false
    @State private var flash = false

    private var profile: AccessibilityProfile { profileStore.profile }
    private var reduceMotion: Bool {
        EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn
    }
    private var attribute: CrowdAttribute { SurveyLogic.question(for: profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if thanked {
                Label("Thanks — that helps other CEA users.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
            } else {
                Label("Quick one about \(survey.venueName)", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(attribute.question)
                    .font(.body)
                Text("One question, totally optional. Your answer is shared anonymously with other CEA users.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorLine {
                    Text(errorLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: Theme.spacing) {
                    answerButton("Yes", value: true)
                    answerButton("No", value: false)
                    Button("Skip") {
                        survey.dismissed = true
                        try? context.save()
                        Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
                    }
                    .frame(minHeight: Theme.minTapTarget)
                    .accessibilityHint("Dismisses this question. Nothing is sent.")
                }
                Button("Don't ask me about places again") {
                    profileStore.profile.surveyPromptsEnabled = false
                    profileStore.save()
                    survey.dismissed = true
                    try? context.save()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minHeight: Theme.minTapTarget - 12)
                .accessibilityHint("Turns these questions off. You can re-enable them in Profile.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ceaCard(highContrast: profile.highContrast)
        .visualFlash(trigger: $flash, reduceMotion: reduceMotion)
        .disabled(sending)
        .accessibilityElement(children: .contain)
    }

    private func answerButton(_ label: String, value: Bool) -> some View {
        Button {
            send(value: value)
        } label: {
            Text(sending ? "…" : label)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .frame(minHeight: Theme.minTapTarget)
        }
        .background(Theme.brandGradient(highContrast: profile.highContrast), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
        .foregroundStyle(.white)
        .accessibilityLabel("\(label), \(attribute.question)")
    }

    private func send(value: Bool) {
        sending = true
        errorLine = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                try await CrowdsourceService.submit(
                    venueKey: survey.venueKey,
                    venueName: survey.venueName,
                    latitude: survey.latitude,
                    longitude: survey.longitude,
                    attribute: attribute,
                    value: value
                )
                survey.completedAt = .now
                try? context.save()
                thanked = true
                Haptics.shared.play(.confirmed, enabled: profile.hapticsEnabled)
                flash = true
            } catch {
                errorLine = error.localizedDescription
                Haptics.shared.play(.headsUp, enabled: profile.hapticsEnabled)
            }
        }
    }
}
