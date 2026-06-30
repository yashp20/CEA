import SwiftUI

struct ProfileView: View {
    // Accessibility toggles — will drive AI + map behaviour later
    @AppStorage("colorBlindness")  private var colorBlindness  = false
    @AppStorage("wheelchair")      private var wheelchair      = false
    @AppStorage("textToSpeech")    private var textToSpeech    = false
    @AppStorage("blindness")       private var blindness       = false
    @AppStorage("adhd")            private var adhd            = false
    @AppStorage("hearingImpaired") private var hearingImpaired = false
    @AppStorage("largerText")      private var largerText      = false

    var body: some View {
        NavigationStack {
            List {
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

                Section("Accessibility") {
                    Toggle("Color Blindness", isOn: $colorBlindness)
                    Toggle("Wheelchair Accessibility", isOn: $wheelchair)
                    Toggle("Text to Speech", isOn: $textToSpeech)
                    Toggle("Blindness / Low Vision", isOn: $blindness)
                    Toggle("ADHD Mode", isOn: $adhd)
                    Toggle("Hearing Impaired", isOn: $hearingImpaired)
                    Toggle("Larger Text", isOn: $largerText)
                }

                Section("Daily Task Customization") {
                    NavigationLink("Manage Shortcuts") { Text("Coming soon") }
                    NavigationLink("App Integrations") { Text("Coming soon") }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    ProfileView()
}
