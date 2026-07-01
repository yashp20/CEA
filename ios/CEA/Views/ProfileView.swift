import SwiftUI

struct ProfileView: View {
    // MARK: - Stored accessibility profile (app-only for now)

    // Vision
    @AppStorage("colorBlindness")  private var colorBlindness  = false
    @AppStorage("colorBlindType")  private var colorBlindType  = ColorBlindType.deuteranopia.rawValue
    @AppStorage("lowVision")       private var lowVision       = false
    @AppStorage("largerText")      private var largerText      = false
    @AppStorage("highContrast")    private var highContrast    = false
    @AppStorage("blindness")       private var blindness       = false

    // Hearing
    @AppStorage("hearingImpaired") private var hearingImpaired = false
    @AppStorage("captions")        private var captions        = false

    // Mobility
    @AppStorage("wheelchair")      private var wheelchair      = false
    @AppStorage("avoidStairs")     private var avoidStairs     = false

    // Cognitive
    @AppStorage("adhd")            private var adhd            = false
    @AppStorage("reduceMotion")    private var reduceMotion    = false

    // Speech / output
    @AppStorage("textToSpeech")    private var textToSpeech    = false

    // Dietary
    @AppStorage("allergyDairy")    private var allergyDairy    = false
    @AppStorage("allergyNuts")     private var allergyNuts     = false
    @AppStorage("allergyGluten")   private var allergyGluten   = false
    @AppStorage("allergyShellfish") private var allergyShellfish = false

    var body: some View {
        NavigationStack {
            List {
                profileHeader

                Section {
                    Toggle(isOn: $colorBlindness) {
                        label("Color Blindness", "eye.trianglebadge.exclamationmark", .orange)
                    }
                    if colorBlindness {
                        Picker("Type", selection: $colorBlindType) {
                            ForEach(ColorBlindType.allCases) { type in
                                Text(type.label).tag(type.rawValue)
                            }
                        }
                    }
                    Toggle(isOn: $lowVision) { label("Low Vision", "eye.fill", .blue) }
                    Toggle(isOn: $largerText) { label("Larger Text", "textformat.size", .blue) }
                    Toggle(isOn: $highContrast) { label("High Contrast", "circle.lefthalf.filled", .gray) }
                    Toggle(isOn: $blindness) { label("Blindness", "eye.slash.fill", .indigo) }
                } header: {
                    Text("Vision")
                } footer: {
                    Text("Affects map colors, text size, and how CEA describes things.")
                }

                Section("Hearing") {
                    Toggle(isOn: $hearingImpaired) { label("Hearing Impaired", "ear.fill", .purple) }
                    Toggle(isOn: $captions) { label("Captions & Visual Alerts", "captions.bubble.fill", .purple) }
                }

                Section {
                    Toggle(isOn: $wheelchair) { label("Wheelchair Accessibility", "figure.roll", .green) }
                    Toggle(isOn: $avoidStairs) { label("Avoid Stairs", "figure.stairs", .green) }
                } header: {
                    Text("Mobility")
                } footer: {
                    Text("Maps will prefer ramps, elevators, and step-free routes.")
                }

                Section("Cognitive") {
                    Toggle(isOn: $adhd) { label("ADHD / Simplified Mode", "brain.head.profile", .pink) }
                    Toggle(isOn: $reduceMotion) { label("Reduce Motion", "wind", .pink) }
                }

                Section("Speech") {
                    Toggle(isOn: $textToSpeech) { label("Text to Speech", "speaker.wave.2.fill", .teal) }
                }

                Section {
                    Toggle(isOn: $allergyDairy) { label("Dairy", "drop.fill", .red) }
                    Toggle(isOn: $allergyNuts) { label("Nuts", "leaf.fill", .red) }
                    Toggle(isOn: $allergyGluten) { label("Gluten", "fork.knife", .red) }
                } header: {
                    Text("Dietary & Allergies")
                } footer: {
                    Text("CEA avoids these when ordering or suggesting food.")
                }

                Section("Daily Task Customization") {
                    NavigationLink("Manage Shortcuts") { Text("Coming soon") }
                    NavigationLink("App Integrations") { Text("Coming soon") }
                }
            }
            .navigationTitle("Profile")
        }
    }

    // MARK: - Subviews

    private var profileHeader: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("User Name")
                        .font(.title3.bold())
                    Text("Tap to edit profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func label(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 7))
            Text(title)
        }
    }
}

// MARK: - Supporting types

enum ColorBlindType: String, CaseIterable, Identifiable {
    case protanopia, deuteranopia, tritanopia, achromatopsia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .protanopia:    return "Protanopia (red-weak)"
        case .deuteranopia:  return "Deuteranopia (green-weak)"
        case .tritanopia:    return "Tritanopia (blue-weak)"
        case .achromatopsia: return "Achromatopsia (no color)"
        }
    }
}

#Preview {
    ProfileView()
}
