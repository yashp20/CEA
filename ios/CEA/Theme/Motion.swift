import SwiftUI

/// Every animation in the app goes through this helper so Reduce Motion is
/// honored in one place. When motion is reduced (system setting or the
/// in-app profile toggle — whichever is stricter) springs collapse to a
/// quick cross-fade rather than movement.
enum Motion {

    /// The standard "bouncy" spring for card/message appearance and buttons.
    static func spring(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.15)
            : .spring(response: 0.4, dampingFraction: 0.75)
    }

    /// A snappier spring for small controls (mic/send buttons).
    static func snappy(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.1)
            : .spring(response: 0.25, dampingFraction: 0.7)
    }

    /// Insertion transition for chat messages and cards.
    static func insertion(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                removal: .opacity
            )
    }
}

/// Resolves the effective reduce-motion flag: the system setting always wins
/// when stricter; the profile toggle can only add restriction.
struct EffectiveReduceMotion {
    let system: Bool
    let profile: Bool
    var isOn: Bool { system || profile }
}
