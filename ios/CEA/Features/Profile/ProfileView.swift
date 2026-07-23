import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Profile surface (PRD F5): every onboarding toggle lives here and applies
/// app-wide instantly (the profile model is observable). System settings
/// (Dynamic Type, Reduce Motion, Increase Contrast, VoiceOver) always win
/// when stricter. Also hosts the visible, deletable memory ledger (F3).
/// v1.1 §2: pushed from home's top-right entry point (no more tab bar), so
/// it renders inside the parent NavigationStack.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var profileStore
    /// The scheme actually in effect — so the toggle shows the true current
    /// state while the preference is still "follow the system".
    @Environment(\.colorScheme) private var effectiveScheme
    @State private var pickedPhoto: PhotosPickerItem?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var themeFade: Animation {
        Motion.themeFade(
            reduceMotion: EffectiveReduceMotion(
                system: systemReduceMotion,
                profile: profileStore.profile.reduceMotion
            ).isOn
        )
    }

    /// "Match system settings" — on means follow the device. Turning it off
    /// freezes whatever is on screen right now, so nothing jumps at the moment
    /// the user takes manual control.
    private var matchSystemBinding: Binding<Bool> {
        Binding(
            get: { profileStore.profile.appearance == .auto },
            set: { matchSystem in
                withAnimation(themeFade) {
                    profileStore.profile.appearanceRaw = matchSystem
                        ? AppAppearance.auto.rawValue
                        : (effectiveScheme == .dark ? AppAppearance.dark : AppAppearance.light).rawValue
                }
                profileStore.save()
            }
        )
    }

    /// Reads the effective appearance; writing it turns "auto" into an
    /// explicit choice, which is what a user expects from flipping a switch.
    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: {
                switch profileStore.profile.appearance {
                case .dark: return true
                case .light: return false
                case .auto: return effectiveScheme == .dark
                }
            },
            set: { isDark in
                withAnimation(themeFade) {
                    profileStore.profile.appearanceRaw =
                        (isDark ? AppAppearance.dark : AppAppearance.light).rawValue
                }
                profileStore.save()
            }
        )
    }

    var body: some View {
        @Bindable var profile = profileStore.profile

        Group {
            List {
                Section {
                    HStack(spacing: 14) {
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            avatar(for: profile)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(profile.avatarData == nil ? "Add a profile photo" : "Change profile photo")

                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Your name", text: $profile.displayName)
                                .font(.title3.weight(.semibold))
                                .textInputAutocapitalization(.words)
                                .accessibilityLabel("Your name")
                            Text("Tap the photo to change it")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 4)

                    TextField(
                        "A short bio — anything you'd like CEA to know about you",
                        text: $profile.bio,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .font(.subheadline)
                    .accessibilityLabel("Your bio")

                    if profile.avatarData != nil {
                        Button(role: .destructive) {
                            profile.avatarData = nil
                            profileStore.save()
                        } label: {
                            Label("Remove photo", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                } header: {
                    Text("You")
                } footer: {
                    Text("Stored only on this device. CEA uses your name sparingly — just where a person naturally would.")
                }

                Section {
                    Toggle(isOn: matchSystemBinding) {
                        Label("Match system settings", systemImage: "iphone")
                    }
                    .tint(Theme.accent(highContrast: profile.highContrast))
                    .frame(minHeight: Theme.minTapTarget - 12)

                    Toggle(isOn: darkModeBinding) {
                        Label("Dark Mode", systemImage: "moon.fill")
                    }
                    .tint(Theme.accent(highContrast: profile.highContrast))
                    .frame(minHeight: Theme.minTapTarget - 12)
                    // While matching the system, this shows the current state
                    // but the device owns it.
                    .disabled(profile.appearance == .auto)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(profile.appearance == .auto
                         ? "CEA follows your device's Light/Dark setting. Turn this off to choose for CEA only."
                         : "Set for CEA only, ignoring your device's Light/Dark setting.")
                }

                Section {
                    row("Larger Text", "textformat.size", $profile.largerText)
                    row("High Contrast", "circle.lefthalf.filled", $profile.highContrast)
                    row("Color Blindness", "eye.trianglebadge.exclamationmark", $profile.colorBlindness)
                    if profile.colorBlindness {
                        Picker(selection: $profile.colorBlindnessTypeRaw) {
                            Text("Not sure / skip").tag("")
                            ForEach(ColorBlindType.allCases) { type in
                                Text(type.displayName).tag(type.rawValue)
                            }
                        } label: {
                            Label("Kind of color blindness", systemImage: "paintpalette")
                        }
                        .frame(minHeight: Theme.minTapTarget - 12)
                    }
                    row("Low Vision", "eye", $profile.lowVision)
                    row("Blind / VoiceOver user", "eye.slash", $profile.blindness)
                } header: {
                    Text("Vision")
                } footer: {
                    Text("Affects type size, colors, and how CEA describes things. Your system Dynamic Type and contrast settings always apply too.")
                }

                Section("Hearing") {
                    row("Deaf / Hard of Hearing", "ear.badge.waveform", $profile.hearingImpaired)
                    row("Captions & Visual Alerts", "captions.bubble", $profile.captions)
                    row("Haptic + Flash Confirmations", "iphone.radiowaves.left.and.right", $profile.hapticConfirmations)
                }

                Section {
                    row("Wheelchair", "figure.roll", $profile.wheelchair)
                    row("Avoid Stairs", "figure.stairs", $profile.avoidStairs)
                } header: {
                    Text("Mobility")
                } footer: {
                    Text("Venue results are ranked by reported accessible entrances where that data exists; CEA says when it's unavailable.")
                }

                Section {
                    row("Simplified Mode", "list.number", $profile.simplifiedMode)
                    row("Voice-First (big mic)", "mic", $profile.voiceFirst)
                    row("Read Replies Aloud", "speaker.wave.2", $profile.spokenResponses)
                    row("Reduce Motion", "wind", $profile.reduceMotion)
                    Picker(selection: $profile.verbosityRaw) {
                        ForEach(VerbosityLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    } label: {
                        Label("Reply Detail", systemImage: "text.alignleft")
                    }
                    .frame(minHeight: Theme.minTapTarget - 12)
                } header: {
                    Text("Thinking & Speech")
                } footer: {
                    Text("Reply Detail sets how much CEA says: terse for the fewest words, simple for short literal sentences, rich for the full picture read aloud. Automatic follows the rest of your profile.")
                }

                Section {
                    row("Ask about places I've been", "person.2", $profile.surveyPromptsEnabled)
                } header: {
                    Text("Community")
                } footer: {
                    Text("After a hand-off, CEA may later ask one quick question about the place (step-free entry, noise, lighting). Answers are anonymous and help other CEA users. Never asked mid-errand.")
                }

                MemoryLedgerSection()

                Section {
                    Button {
                        profile.onboardingCompleted = false
                        profileStore.save()
                    } label: {
                        Label("Run setup again", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Conversation text and this profile summary go to the AI service per request to answer you; conversations are never stored server-side. Your accessibility profile stays on this device only. Saved preferences (like favorite cuisines) also sync to a memory service so they survive reinstalls — deleting memory removes them there too.")
                }
            }
            .navigationTitle("Profile")
            .onChange(of: profileSnapshot) { profileStore.save() }
            // Name/bio are free text, so persist them on edit too.
            .onChange(of: profileStore.profile.displayName) { profileStore.save() }
            .onChange(of: profileStore.profile.bio) { profileStore.save() }
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
    }

    /// The profile photo, or a branded placeholder when none is set.
    @ViewBuilder
    private func avatar(for profile: AccessibilityProfile) -> some View {
        if let data = profile.avatarData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 62, height: 62)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(.systemGray4), lineWidth: 1))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.brandGradient(highContrast: profile.highContrast))
                .frame(width: 62, height: 62)
        }
    }

    // (List body lives inside Group above so this view composes into the
    // parent NavigationStack pushed from home.)

    /// Trigger a save whenever any setting changes.
    private var profileSnapshot: [String] {
        let p = profileStore.profile
        let bools = [p.largerText, p.highContrast, p.colorBlindness, p.lowVision, p.blindness,
                     p.hearingImpaired, p.captions, p.hapticConfirmations,
                     p.wheelchair, p.avoidStairs,
                     p.simplifiedMode, p.voiceFirst, p.spokenResponses, p.reduceMotion,
                     p.surveyPromptsEnabled]
        return bools.map(String.init) + [p.colorBlindnessTypeRaw, p.verbosityRaw]
    }

    private func row(_ title: String, _ icon: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Label(title, systemImage: icon)
        }
        .tint(Theme.accent(highContrast: profileStore.profile.highContrast))
        .frame(minHeight: Theme.minTapTarget - 12)
    }
}

/// Compact Memory entry point: a single tappable row that pushes the full
/// list, so the ledger never fills up the Profile page. The count gives an
/// at-a-glance sense of how much CEA has learned.
struct MemoryLedgerSection: View {
    @Query private var memories: [PreferenceMemory]

    var body: some View {
        Section {
            NavigationLink {
                MemoryDetailView()
            } label: {
                HStack {
                    Label("Saved memories", systemImage: "brain.head.profile")
                    Spacer()
                    Text("\(memories.count)")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("Everything CEA has remembered about you. Tap to view or delete.")
        } header: {
            Text("Memory")
        } footer: {
            Text("Things CEA has picked up as you chat. Your accessibility profile is never in here — it stays on this device only.")
        }
    }
}

/// The full memory ledger (PRD F3), on its own screen: everything the agent
/// has remembered, each entry deletable, plus delete-all.
struct MemoryDetailView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Query(sort: \PreferenceMemory.createdAt, order: .reverse) private var memories: [PreferenceMemory]
    @State private var confirmingDeleteAll = false

    var body: some View {
        List {
            if memories.isEmpty {
                ContentUnavailableView(
                    "Nothing saved yet",
                    systemImage: "brain.head.profile",
                    description: Text("As you chat, CEA quietly remembers preferences and details here — and you can delete any of it, anytime.")
                )
            } else {
                Section {
                    ForEach(memories) { memory in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memory.key.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.body.weight(.medium))
                            Text(memory.value)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            profileStore.deleteMemory(memories[index])
                        }
                    }
                } footer: {
                    Text("Swipe an item to delete it; deleting removes it from the memory service too.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingDeleteAll = true
                    } label: {
                        Label("Delete all memory", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Saved memories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !memories.isEmpty {
                EditButton()
            }
        }
        .confirmationDialog(
            "Delete everything CEA has remembered?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all memory", role: .destructive) {
                profileStore.deleteAllMemory()
            }
        }
    }
}
