import CoreLocation
import SwiftUI
import UserNotifications

/// Onboarding (PRD F1): ≤5 screens, one plain question each, seeded from
/// system accessibility settings, skippable, and every choice editable later
/// in Profile. The chat preview is the real chat UI rendering, re-rendered
/// live as toggles change.
struct OnboardingView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var page = 0
    private let pageCount = 5

    private var profile: AccessibilityProfile { profileStore.profile }
    private var reduceMotion: Bool {
        EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn
    }

    var body: some View {
        @Bindable var profile = profileStore.profile

        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing * 1.5) {
                    Group {
                        switch page {
                        case 0: welcomePage
                        case 1: readingPage(profile: $profile)
                        case 2: hearingPage(profile: $profile)
                        case 3: mobilityPage(profile: $profile)
                        default: wrapUpPage(profile: $profile)
                        }
                    }
                    .transition(Motion.insertion(reduceMotion: reduceMotion))

                    if page > 0 {
                        ChatPreview(profile: profile, reduceMotion: reduceMotion)
                    }
                }
                .padding()
                .animation(Motion.spring(reduceMotion: reduceMotion), value: page)
            }

            controls
        }
        .background(Theme.screenBackground)
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            // Progress: dots plus text, not color alone.
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page
                              ? AnyShapeStyle(Theme.brandGradient(highContrast: profile.highContrast))
                              : AnyShapeStyle(Color(.systemGray4)))
                        .frame(width: index == page ? 10 : 7, height: index == page ? 10 : 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(page + 1) of \(pageCount)")

            Spacer()

            Button("Skip — use standard settings") {
                finish()
            }
            .font(.subheadline)
            .accessibilityHint("Finishes setup with your current settings. Everything stays editable in Profile.")
        }
        .padding()
    }

    private var controls: some View {
        HStack(spacing: Theme.spacing) {
            if page > 0 {
                Button("Back") {
                    withAnimation(Motion.spring(reduceMotion: reduceMotion)) { page -= 1 }
                }
                .frame(minHeight: Theme.minTapTarget)
            }
            Spacer()
            Button(page == pageCount - 1 ? "Done" : "Next") {
                if page == pageCount - 1 {
                    finish()
                } else {
                    withAnimation(Motion.spring(reduceMotion: reduceMotion)) { page += 1 }
                }
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .frame(minHeight: Theme.minTapTarget)
            .background(Theme.brandGradient(highContrast: profile.highContrast), in: Capsule())
            .foregroundStyle(.white)
        }
        .padding()
    }

    private func finish() {
        profileStore.profile.onboardingCompleted = true
        profileStore.save()
    }

    // MARK: Pages (one plain question each)

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text("Hi, I'm CEA.")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("One conversation for everyday errands — rides and food — handed off to the real app. You always confirm the final step yourself.")
                .font(.title3)
            Text("A few quick questions make CEA fit how you read, hear, and get around. Your answers stay on this device and are editable anytime.")
                .font(.body)
                .foregroundStyle(.secondary)
            if UIAccessibility.isVoiceOverRunning || profile.largerText || profile.highContrast || profile.reduceMotion {
                Label("We pre-filled some answers from your system accessibility settings — just confirm them.", systemImage: "wand.and.stars")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readingPage(profile: Bindable<AccessibilityProfile>) -> some View {
        questionPage(
            question: "How is reading on a phone for you?",
            toggles: [
                ("Bigger text helps", "textformat.size", profile.largerText),
                ("Strong contrast helps", "circle.lefthalf.filled", profile.highContrast),
                ("I'm colorblind", "eye.trianglebadge.exclamationmark", profile.colorBlindness),
                ("I use VoiceOver / can't see the screen", "eye.slash", profile.blindness),
            ]
        )
    }

    private func hearingPage(profile: Bindable<AccessibilityProfile>) -> some View {
        questionPage(
            question: "How do you notice alerts best?",
            toggles: [
                ("I'm deaf or hard of hearing", "ear.badge.waveform", profile.hearingImpaired),
                ("Show captions and visual alerts", "captions.bubble", profile.captions),
                ("Vibrate and flash to confirm things", "iphone.radiowaves.left.and.right", profile.hapticConfirmations),
            ]
        )
    }

    private func mobilityPage(profile: Bindable<AccessibilityProfile>) -> some View {
        questionPage(
            question: "How do you get around?",
            toggles: [
                ("I use a wheelchair", "figure.roll", profile.wheelchair),
                ("I avoid stairs", "figure.stairs", profile.avoidStairs),
                ("I'd rather talk than type", "mic", profile.voiceFirst),
            ]
        )
    }

    private func wrapUpPage(profile: Bindable<AccessibilityProfile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            questionPage(
                question: "Anything that makes reading replies easier?",
                toggles: [
                    ("Keep it extra simple, one thing at a time", "list.number", profile.simplifiedMode),
                    ("Read replies out loud", "speaker.wave.2", profile.spokenResponses),
                    ("Less motion on screen", "wind", profile.reduceMotion),
                ]
            )

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Two permissions, both optional")
                    .font(.headline)
                Button {
                    LocationService.shared.requestPermission()
                } label: {
                    Label("Allow location — so \"food nearby\" knows where nearby is.", systemImage: "location")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .frame(minHeight: Theme.minTapTarget)
                }
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))

                Button {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                } label: {
                    Label("Allow notifications — reminders like \"check your ride app\" with vibration and flash.", systemImage: "bell.badge")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .frame(minHeight: Theme.minTapTarget)
                }
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
            }
            .foregroundStyle(.primary)
        }
    }

    private func questionPage(question: String, toggles: [(String, String, Binding<Bool>)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text(question)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            ForEach(toggles, id: \.0) { title, icon, binding in
                Toggle(isOn: binding) {
                    Label(title, systemImage: icon)
                }
                .padding(12)
                .frame(minHeight: Theme.minTapTarget)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
                .tint(Theme.accent(highContrast: profileStore.profile.highContrast))
            }
        }
    }
}

// MARK: Live preview

/// A real render of the chat UI (same components as ChatView uses) that
/// re-renders immediately as onboarding toggles change: voice-first grows the
/// mic into the primary control, Larger Text raises type size, High Contrast
/// switches the palette, and the hearing profile shows the haptic/flash
/// confirmation pattern.
struct ChatPreview: View {
    let profile: AccessibilityProfile
    var reduceMotion: Bool

    @State private var previewText = ""
    @State private var flash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live preview — this is how CEA will look")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: Theme.spacing) {
                MessageRow(
                    message: ChatMessage(role: .user, text: "Get me a ride to Union Station."),
                    profile: profile,
                    reduceMotion: reduceMotion,
                    onOpenURL: { _ in }
                )
                MessageRow(
                    message: ChatMessage(role: .assistant, text: assistantSample),
                    profile: profile,
                    reduceMotion: reduceMotion,
                    onOpenURL: { _ in }
                )
                if profile.hearingImpaired || profile.hapticConfirmations {
                    Label("Confirmations vibrate and flash like this", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .visualFlash(trigger: $flash, reduceMotion: reduceMotion)
                        .onAppear { flash = true }
                        .onTapGesture {
                            HapticsService.confirm(enabled: true)
                            flash = true
                        }
                        .accessibilityLabel("Example confirmation. Confirmations vibrate and flash.")
                }
                InputBar(
                    text: $previewText,
                    voiceFirst: profile.voiceFirst,
                    highContrast: profile.highContrast,
                    reduceMotion: reduceMotion,
                    isSending: false,
                    onSend: { previewText = "" }
                )
            }
            .padding(.vertical, 8)
            .background(Theme.screenBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )
            .dynamicTypeSize(profile.largerText ? DynamicTypeSize.accessibility1...DynamicTypeSize.accessibility5 : DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5)
            .animation(Motion.spring(reduceMotion: reduceMotion), value: profile.voiceFirst)
            .animation(Motion.spring(reduceMotion: reduceMotion), value: profile.largerText)
            .animation(Motion.spring(reduceMotion: reduceMotion), value: profile.highContrast)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live preview of the chat screen with your current choices")
    }

    private var assistantSample: String {
        if profile.simplifiedMode {
            return "Okay. 1. Confirm pickup at your location. 2. I prepare the ride. Say 'yes' to continue."
        }
        return "Pickup at your location, drop-off Union Station — shall I prepare Uber and Lyft with that trip?"
    }
}
