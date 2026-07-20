import CoreLocation
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

/// Onboarding (PRD F1): ≤5 screens, one plain question each, seeded from
/// system accessibility settings, skippable, and every choice editable later
/// in Profile. The chat preview is the real chat UI rendering, re-rendered
/// live as toggles change.
struct OnboardingView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var page = 0
    @State private var pickedPhoto: PhotosPickerItem?
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
                        case 0: welcomePage(profile: $profile)
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
            .scrollDismissesKeyboard(.interactively)
            // Tap outside any field dismisses the keyboard (§1 bug 1);
            // interactive children (toggles, buttons, fields) win the tap.
            .onTapGesture { dismissKeyboard() }

            controls
        }
        .background(Theme.screenBackground)
        // Keyboard never survives a step change.
        .onChange(of: page) {
            dismissKeyboard()
            profileStore.save()   // persist any name/bio typed on this step
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    profileStore.profile.avatarData = data
                    profileStore.save()
                }
            }
        }
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
        dismissKeyboard()
        profileStore.profile.onboardingCompleted = true
        profileStore.save()
    }

    // MARK: Pages (one plain question each)

    /// Welcome + introductions. Identity lives here rather than on its own
    /// screen so setup stays within the ≤5-screen / ≤90-second budget (PRD F1,
    /// §8) — and "Hi, I'm CEA … and you are?" reads like a real introduction.
    /// Every field is optional; Next and Skip both work with all of it blank.
    private func welcomePage(profile: Bindable<AccessibilityProfile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text("Hi, I'm CEA.")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("One conversation for everyday errands — rides and food — handed off to the real app. You always confirm the final step yourself.")
                .font(.title3)

            // Same visual language as the toggle steps: a bold question, then
            // card rows sitting on the screen background.
            Text("What should I call you?")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 14) {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    onboardingAvatar(for: profileStore.profile)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(profileStore.profile.avatarData == nil
                                    ? "Add a profile photo, optional"
                                    : "Change profile photo")

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Your name", text: profile.displayName)
                        .textInputAutocapitalization(.words)
                        .font(.body)
                        .accessibilityLabel("Your name, optional")
                    Text(profileStore.profile.avatarData == nil
                         ? "Optional — tap the circle to add a photo"
                         : "Tap the photo to change it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(minHeight: Theme.minTapTarget)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))

            VStack(alignment: .leading, spacing: 6) {
                Label("About you", systemImage: "text.quote")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(
                    "Anything you'd like me to know (optional)",
                    text: profile.bio,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .font(.body)
                .accessibilityLabel("A short bio, optional")
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: Theme.minTapTarget, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))

            Text("All optional, and editable anytime in Profile. Your answers stay on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if UIAccessibility.isVoiceOverRunning || profileStore.profile.largerText
                || profileStore.profile.highContrast || profileStore.profile.reduceMotion {
                Label("We pre-filled some answers from your system accessibility settings — just confirm them.", systemImage: "wand.and.stars")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Photo well for onboarding: the chosen picture, or a tappable placeholder
    /// that reads as "add a photo" rather than a decorative icon.
    @ViewBuilder
    private func onboardingAvatar(for profile: AccessibilityProfile) -> some View {
        if let data = profile.avatarData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 66, height: 66)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(.systemGray4), lineWidth: 1))
        } else {
            ZStack {
                Circle()
                    .fill(Color(.systemGray6))
                    .frame(width: 66, height: 66)
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.brandGradient(highContrast: profile.highContrast))
            }
            .overlay(
                Circle().strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .frame(width: 66, height: 66)
            )
        }
    }

    private func readingPage(profile: Bindable<AccessibilityProfile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            questionPage(
                question: "How is reading on a phone for you?",
                toggles: [
                    ("Bigger text helps", "textformat.size", profile.largerText),
                    ("Strong contrast helps", "circle.lefthalf.filled", profile.highContrast),
                    ("I'm colorblind", "eye.trianglebadge.exclamationmark", profile.colorBlindness),
                    ("I use VoiceOver / can't see the screen", "eye.slash", profile.blindness),
                ]
            )
            // Subtype selector appears when the toggle is on (§1 bug 2) so the
            // palette can adapt to the specific kind of color blindness.
            if profileStore.profile.colorBlindness {
                ColorBlindTypePicker(selectionRaw: profile.colorBlindnessTypeRaw)
                    .transition(Motion.insertion(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.spring(reduceMotion: reduceMotion), value: profileStore.profile.colorBlindness)
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
                    // §1 bug 3: the flash is a border + corner badge now, so
                    // this text stays fully legible, and the real Core Haptics
                    // pattern fires with it — visual + haptic twins together.
                    Label("Confirmations vibrate and flash like this — tap to feel it", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .visualFlash(trigger: $flash, reduceMotion: reduceMotion)
                        .onAppear {
                            Haptics.shared.play(.confirmed, enabled: true)
                            flash = true
                        }
                        .onTapGesture {
                            Haptics.shared.play(.confirmed, enabled: true)
                            flash = true
                        }
                        .accessibilityLabel("Example confirmation. Confirmations vibrate and flash. Double-tap to feel the vibration.")
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

/// Subtype selector for the color-blindness toggle (§1 bug 2). Shared by
/// onboarding and Profile. Optional: leaving it unset keeps the generic
/// color-safe behavior (labels + icons, never color alone).
struct ColorBlindTypePicker: View {
    @Binding var selectionRaw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which kind, if you know?")
                .font(.subheadline.weight(.medium))
            Picker("Kind of color blindness", selection: $selectionRaw) {
                Text("Not sure / skip").tag("")
                ForEach(ColorBlindType.allCases) { type in
                    Text(type.displayName).tag(type.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: Theme.minTapTarget)
            Text("CEA adjusts its status colors to stay distinguishable for you. Labels always carry the meaning too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
        .accessibilityElement(children: .contain)
    }
}
