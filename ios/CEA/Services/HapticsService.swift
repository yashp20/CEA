import CoreHaptics
import SwiftUI
import UIKit

/// The app-wide haptic vocabulary (v1.1 §3.3): a small set of named,
/// distinguishable patterns used consistently everywhere, so haptics can act
/// as a primary channel for deaf/hard-of-hearing profiles. Every pattern is
/// always paired with a visual twin already on screen (PRD §9) — callers use
/// `VisualFlash` or an equivalent visible state change.
enum HapticPattern: String {
    /// Success/confirmation: two rising taps ("da-DUM").
    case confirmed
    /// The assistant needs something from you: one soft, longer buzz.
    case needsInput
    /// Attention/barrier warning: three sharp taps.
    case headsUp
    /// Light UI acknowledgment (button presses, "I heard you").
    case tap
}

/// One `Haptics` service (v1.1 §3.3). Core Haptics when available, with a
/// `UIFeedbackGenerator` fallback (older devices, simulator, engine failure).
@MainActor
final class Haptics {
    static let shared = Haptics()

    private var engine: CHHapticEngine?
    private var engineUnavailable = false

    private init() {}

    /// Plays a named pattern. `enabled` is the caller's profile gate
    /// (haptic confirmations on, or deaf/HoH profile).
    func play(_ pattern: HapticPattern, enabled: Bool) {
        guard enabled else { return }
        if let engine = preparedEngine(),
           let corePattern = try? corePattern(for: pattern),
           let player = try? engine.makePlayer(with: corePattern) {
            do {
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                // fall through to the generator fallback below
            }
        }
        fallback(pattern)
    }

    // MARK: Engine

    private func preparedEngine() -> CHHapticEngine? {
        guard !engineUnavailable,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        if let engine { return engine }
        do {
            let fresh = try CHHapticEngine()
            fresh.resetHandler = { [weak self] in
                Task { @MainActor in self?.engine = nil }
            }
            try fresh.start()
            engine = fresh
            return fresh
        } catch {
            engineUnavailable = true
            return nil
        }
    }

    /// Short and distinguishable by rhythm + sharpness, not just strength —
    /// rhythm survives across devices better than amplitude.
    private func corePattern(for pattern: HapticPattern) throws -> CHHapticPattern {
        func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: time
            )
        }
        let events: [CHHapticEvent]
        switch pattern {
        case .confirmed:
            events = [
                transient(at: 0, intensity: 0.6, sharpness: 0.4),
                transient(at: 0.12, intensity: 1.0, sharpness: 0.6),
            ]
        case .needsInput:
            events = [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                    ],
                    relativeTime: 0,
                    duration: 0.35
                ),
            ]
        case .headsUp:
            events = [
                transient(at: 0, intensity: 1.0, sharpness: 0.9),
                transient(at: 0.12, intensity: 1.0, sharpness: 0.9),
                transient(at: 0.24, intensity: 1.0, sharpness: 0.9),
            ]
        case .tap:
            events = [transient(at: 0, intensity: 0.5, sharpness: 0.5)]
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    private func fallback(_ pattern: HapticPattern) {
        switch pattern {
        case .confirmed:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .needsInput:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .headsUp:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .tap:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// The visual twin of a haptic confirmation. Redesigned in v1.1 (§1 bug 3):
/// the old version drew a large centered checkmark over the content, covering
/// the text it was confirming. Now it draws a border glow plus a small badge
/// at the top-trailing corner — content stays fully legible — and never
/// intercepts touches. Safe under Reduce Motion (opacity-only there).
struct VisualFlash: ViewModifier {
    @Binding var trigger: Bool
    var reduceMotion: Bool
    /// Vary the badge for the pattern it twins: checkmark for `confirmed`,
    /// exclamation for `headsUp`.
    var icon: String = "checkmark.circle.fill"

    func body(content: Content) -> some View {
        content
            .overlay {
                if trigger {
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                        )
                        .transition(.opacity)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if trigger {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                        .background(.thickMaterial, in: Circle())
                        .offset(x: 6, y: -6)
                        .transition(reduceMotion ? .opacity : AnyTransition.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .task(id: trigger) {
                guard trigger else { return }
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.3)) {
                    trigger = false
                }
            }
    }
}

extension View {
    func visualFlash(trigger: Binding<Bool>, reduceMotion: Bool, icon: String = "checkmark.circle.fill") -> some View {
        modifier(VisualFlash(trigger: trigger, reduceMotion: reduceMotion, icon: icon))
    }
}
