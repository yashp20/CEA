import SwiftUI
import UIKit

/// Programmatic keyboard dismissal (v1.1 §1 bug 1). SwiftUI's FocusState
/// covers fields we own directly; this resigns whatever is first responder —
/// needed on onboarding step transitions where the focused field lives inside
/// the embedded live chat preview.
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
    )
}
