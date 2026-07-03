import SwiftUI
import UIKit

/// Haptic confirmations for key moments. Every haptic has a visual twin
/// (PRD §9): callers pair `confirm()` with `VisualFlash` so deaf users get
/// the same signal. Haptics fire only when the profile enables them.
@MainActor
enum HapticsService {
    static func confirm(enabled: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func tap(enabled: Bool) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// The visual twin of a haptic confirmation: a brief accent-colored flash
/// overlay plus an icon, safe under Reduce Motion (opacity-only).
struct VisualFlash: ViewModifier {
    @Binding var trigger: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if trigger {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Color.accentColor)
                    )
                    .transition(.opacity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.3)) {
                            trigger = false
                        }
                    }
            }
        }
    }
}

extension View {
    func visualFlash(trigger: Binding<Bool>, reduceMotion: Bool) -> some View {
        modifier(VisualFlash(trigger: trigger, reduceMotion: reduceMotion))
    }
}
