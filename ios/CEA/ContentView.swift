import SwiftUI

/// App shell: onboarding gate, then the CEA / Profile tab bar (per the CEA
/// Figma frames). Profile-adaptive settings apply here so they take effect
/// app-wide instantly; system settings win when stricter (they compose on
/// top of these).
struct ContentView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var profile: AccessibilityProfile { profileStore.profile }

    var body: some View {
        Group {
            if profile.onboardingCompleted {
                TabView {
                    ChatsListView()
                        .tabItem { Label("CEA", systemImage: "circle.hexagongrid.fill") }
                    ProfileView()
                        .tabItem { Label("Profile", systemImage: "person.fill") }
                }
            } else {
                OnboardingView()
            }
        }
        .tint(Theme.accent(highContrast: profile.highContrast))
        // Larger Text raises the Dynamic Type floor; the system setting can
        // always push it higher.
        .dynamicTypeSize(profile.largerText
                         ? DynamicTypeSize.accessibility1...DynamicTypeSize.accessibility5
                         : DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5)
        .animation(
            Motion.spring(reduceMotion: EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn),
            value: profile.onboardingCompleted
        )
    }
}
