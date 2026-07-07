import SwiftData
import SwiftUI

/// Profile surface (PRD F5): every onboarding toggle lives here and applies
/// app-wide instantly (the profile model is observable). System settings
/// (Dynamic Type, Reduce Motion, Increase Contrast, VoiceOver) always win
/// when stricter. Also hosts the visible, deletable memory ledger (F3).
struct ProfileView: View {
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        @Bindable var profile = profileStore.profile

        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(Theme.brandGradient(highContrast: profile.highContrast))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your profile")
                                .font(.title3.bold())
                            Text("Stored only on this device. CEA uses it to adapt every reply.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
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

                Section("Thinking & Speech") {
                    row("Simplified Mode", "list.number", $profile.simplifiedMode)
                    row("Voice-First (big mic)", "mic", $profile.voiceFirst)
                    row("Read Replies Aloud", "speaker.wave.2", $profile.spokenResponses)
                    row("Reduce Motion", "wind", $profile.reduceMotion)
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
                    Text("Conversation text and this profile summary go to the AI service per request to answer you; nothing is stored server-side.")
                }
            }
            .navigationTitle("Profile")
            .onChange(of: profileSnapshot) { profileStore.save() }
        }
    }

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

/// The visible memory ledger (PRD F3): everything the agent has remembered,
/// each entry deletable, plus delete-all.
struct MemoryLedgerSection: View {
    @Environment(ProfileStore.self) private var profileStore
    @Query(sort: \PreferenceMemory.createdAt, order: .reverse) private var memories: [PreferenceMemory]
    @State private var confirmingDeleteAll = false

    var body: some View {
        Section {
            if memories.isEmpty {
                Text("Nothing saved yet. When CEA remembers a preference, it shows up here — and it always tells you in chat first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
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

                Button(role: .destructive) {
                    confirmingDeleteAll = true
                } label: {
                    Label("Delete all memory", systemImage: "trash")
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
        } header: {
            Text("Memory")
        } footer: {
            Text("Swipe an item to delete it. Memory never includes health details or anything sensitive.")
        }
    }
}
