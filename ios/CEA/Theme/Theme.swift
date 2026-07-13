import SwiftUI

/// Central design tokens. Colors adapt to the high-contrast profile toggle;
/// system Increase Contrast is honored automatically by using semantic colors
/// where possible and WCAG-AA-checked brand colors elsewhere.
enum Theme {

    // MARK: Brand

    /// Brand gradient anchors (blue → purple, per the CEA Figma theme).
    static let brandBlue = Color(red: 0.20, green: 0.40, blue: 0.95)
    static let brandPurple = Color(red: 0.48, green: 0.25, blue: 0.90)

    /// High-contrast variants: darker, so white text stays ≥ 4.5:1.
    static let brandBlueHC = Color(red: 0.08, green: 0.22, blue: 0.62)
    static let brandPurpleHC = Color(red: 0.28, green: 0.10, blue: 0.55)

    static func brandGradient(highContrast: Bool) -> LinearGradient {
        LinearGradient(
            colors: highContrast ? [brandBlueHC, brandPurpleHC] : [brandBlue, brandPurple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Solid accent used for buttons, links, and the user bubble.
    static func accent(highContrast: Bool) -> Color {
        highContrast ? brandBlueHC : brandBlue
    }

    // MARK: Semantic status colors (color-blind-aware, v1.1 §1 bug 2)

    /// Positive status (e.g. "accessible entrance confirmed"). Color is never
    /// the only signal — icons/labels always carry the meaning — but the
    /// redundant color channel should stay useful for each subtype.
    /// TODO(cea): per-subtype palette tuning — these are conservative safe
    /// pairs (blue/gold for red-green subtypes, avoid blue-yellow contrast
    /// for tritanopia, lightness-only for achromatopsia), not clinically
    /// tuned palettes.
    static func positive(for type: ColorBlindType?, highContrast: Bool) -> Color {
        if highContrast { return .primary }
        switch type {
        case nil: return .green
        case .protanopia, .deuteranopia: return Color(red: 0.0, green: 0.45, blue: 0.85)   // blue
        case .tritanopia: return Color(red: 0.0, green: 0.55, blue: 0.30)                  // green
        case .achromatopsia: return .primary
        }
    }

    /// Caution status (e.g. "no accessible entrance reported").
    static func caution(for type: ColorBlindType?, highContrast: Bool) -> Color {
        if highContrast { return .primary }
        switch type {
        case nil: return .orange
        case .protanopia, .deuteranopia: return Color(red: 0.72, green: 0.53, blue: 0.0)   // gold
        case .tritanopia: return Color(red: 0.80, green: 0.25, blue: 0.20)                 // red
        case .achromatopsia: return .secondary
        }
    }

    // MARK: Surfaces

    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let screenBackground = Color(.systemGroupedBackground)
    static let assistantBubble = Color(.systemGray5)

    // MARK: Metrics

    static let cornerRadius: CGFloat = 20
    static let cardCornerRadius: CGFloat = 16
    static let bubbleCornerRadius: CGFloat = 18
    static let spacing: CGFloat = 12
    /// Minimum hit target per accessibility criteria.
    static let minTapTarget: CGFloat = 44

    static func cardShadow(highContrast: Bool) -> Color {
        // No decorative shadows in high contrast; borders carry the structure.
        highContrast ? .clear : .black.opacity(0.08)
    }
}

/// Card container matching the Figma look: rounded, soft shadow, generous padding.
struct CEACardStyle: ViewModifier {
    let highContrast: Bool

    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing + 4)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(highContrast ? Color.primary.opacity(0.5) : .clear, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow(highContrast: highContrast), radius: 8, y: 3)
    }
}

extension View {
    func ceaCard(highContrast: Bool) -> some View {
        modifier(CEACardStyle(highContrast: highContrast))
    }
}
