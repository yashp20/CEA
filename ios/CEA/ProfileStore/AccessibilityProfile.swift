import Foundation
import SwiftData

/// Color-blindness subtype (v1.1 §1 bug 2). Stored on the profile so the
/// palette can adapt to the specific subtype rather than a generic flag.
enum ColorBlindType: String, CaseIterable, Codable, Identifiable {
    case protanopia
    case deuteranopia
    case tritanopia
    case achromatopsia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .protanopia: return "Protanopia (red-weak)"
        case .deuteranopia: return "Deuteranopia (green-weak)"
        case .tritanopia: return "Tritanopia (blue-weak)"
        case .achromatopsia: return "Achromatopsia (no color)"
        }
    }
}

/// How detailed CEA's replies should be (v1.1 §3.6). `auto` derives from the
/// rest of the profile; the others are explicit user overrides.
enum VerbosityLevel: String, CaseIterable, Codable, Identifiable {
    case auto
    case terse      // power user: dense, minimal words
    case simple     // cognitive profile: short, literal, one idea at a time
    case standard   // the default calm 3-sentence style
    case rich       // blind users who want the detail a sighted user gets visually

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatic (from profile)"
        case .terse: return "Terse — fewest words"
        case .simple: return "Simple — short and literal"
        case .standard: return "Standard"
        case .rich: return "Rich — full detail"
        }
    }
}

/// The structured accessibility profile (PRD F1/F3/F5). Single instance,
/// on-device only, injected into every LLM system prompt as a short summary.
/// PRIVACY: this model is disability/health-adjacent and never leaves the
/// device except as the prompt summary inside LLM requests — it is never
/// synced to the vendor memory backend (v1.1 §5).
@Model
final class AccessibilityProfile {
    // Vision
    var colorBlindness: Bool
    /// Subtype raw value; empty when none selected. See `colorBlindType`.
    var colorBlindnessTypeRaw: String = ""
    var lowVision: Bool
    var largerText: Bool
    var highContrast: Bool
    var blindness: Bool

    // Hearing
    var hearingImpaired: Bool
    var captions: Bool

    // Mobility
    var wheelchair: Bool
    var avoidStairs: Bool

    // Cognitive
    var simplifiedMode: Bool          // plain language, numbered choices
    var reduceMotion: Bool            // in-app toggle; system setting also honored

    // Interaction preferences (derived/direct)
    var voiceFirst: Bool              // prominent mic, spoken flow
    var spokenResponses: Bool         // TTS when VoiceOver is off
    var hapticConfirmations: Bool     // haptic + visual flash on key confirmations

    // v1.1 additions (defaults required for lightweight SwiftData migration)
    /// Response verbosity dial (§3.6); raw VerbosityLevel.
    var verbosityRaw: String = VerbosityLevel.auto.rawValue
    /// Whether the queued accessibility surveys (§3.1) may be shown at all.
    var surveyPromptsEnabled: Bool = true

    // Identity — user-set, on-device (like the rest of this model, it is never
    // synced to the memory vendor). The name lets CEA address the user, but
    // sparingly: see SystemPrompt for the "only when it helps" rule.
    var displayName: String = ""
    var bio: String = ""
    /// Profile photo, stored outside the main store file to keep it light.
    @Attribute(.externalStorage) var avatarData: Data?

    // Bookkeeping
    var onboardingCompleted: Bool
    var createdAt: Date

    init(
        colorBlindness: Bool = false,
        colorBlindnessTypeRaw: String = "",
        lowVision: Bool = false,
        largerText: Bool = false,
        highContrast: Bool = false,
        blindness: Bool = false,
        hearingImpaired: Bool = false,
        captions: Bool = false,
        wheelchair: Bool = false,
        avoidStairs: Bool = false,
        simplifiedMode: Bool = false,
        reduceMotion: Bool = false,
        voiceFirst: Bool = false,
        spokenResponses: Bool = false,
        hapticConfirmations: Bool = false,
        verbosityRaw: String = VerbosityLevel.auto.rawValue,
        surveyPromptsEnabled: Bool = true,
        onboardingCompleted: Bool = false
    ) {
        self.colorBlindness = colorBlindness
        self.colorBlindnessTypeRaw = colorBlindnessTypeRaw
        self.lowVision = lowVision
        self.largerText = largerText
        self.highContrast = highContrast
        self.blindness = blindness
        self.hearingImpaired = hearingImpaired
        self.captions = captions
        self.wheelchair = wheelchair
        self.avoidStairs = avoidStairs
        self.simplifiedMode = simplifiedMode
        self.reduceMotion = reduceMotion
        self.voiceFirst = voiceFirst
        self.spokenResponses = spokenResponses
        self.hapticConfirmations = hapticConfirmations
        self.verbosityRaw = verbosityRaw
        self.surveyPromptsEnabled = surveyPromptsEnabled
        self.onboardingCompleted = onboardingCompleted
        self.createdAt = .now
    }
}

extension AccessibilityProfile {
    /// The selected color-blindness subtype, when the toggle is on.
    var colorBlindType: ColorBlindType? {
        guard colorBlindness else { return nil }
        return ColorBlindType(rawValue: colorBlindnessTypeRaw)
    }

    var verbosity: VerbosityLevel {
        VerbosityLevel(rawValue: verbosityRaw) ?? .auto
    }

    /// Haptics are the primary channel for deaf/HoH profiles (v1.1 §3.3), so
    /// the hearing profile implies them even without the explicit toggle.
    var hapticsEnabled: Bool {
        hapticConfirmations || hearingImpaired
    }

    /// Who the user is, for the system prompt. Empty fields are simply omitted
    /// so CEA never refers to a name or bio the user hasn't set.
    var identitySummary: String {
        var parts: [String] = []
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append("The user's name is \(name).") }
        if !about.isEmpty { parts.append("In their own words: \(about)") }
        return parts.isEmpty ? "The user hasn't set a name or bio." : parts.joined(separator: " ")
    }

    /// Plain-language summary injected into the system prompt (PRD F3).
    /// Kept short: only active needs are mentioned.
    var promptSummary: String {
        var needs: [String] = []
        if blindness { needs.append("blind or low-vision VoiceOver user: every reply must be fully self-describing spoken text, never reference visual layout like 'see below'") }
        else if lowVision { needs.append("low vision: prefers concise spoken-friendly descriptions") }
        if colorBlindness {
            let subtype = colorBlindType.map { " (\($0.rawValue))" } ?? ""
            needs.append("color blindness\(subtype): never describe anything by color alone")
        }
        if hearingImpaired { needs.append("deaf or hard of hearing: never reference sounds; confirmations are visual and haptic") }
        if wheelchair { needs.append("wheelchair user: prefer wheelchair-accessible venues and accessible ride types; mention accessibility info when known, say when it is unavailable") }
        else if avoidStairs { needs.append("avoids stairs: prefer step-free venues and routes") }
        if simplifiedMode { needs.append("cognitive/attention needs: simplest sentence forms, numbered choices, one idea per sentence") }
        if voiceFirst { needs.append("voice-first user: keep replies natural to hear aloud") }
        if needs.isEmpty { return "No specific accessibility needs recorded. Use the default calm, concise style." }
        return "User accessibility profile: " + needs.joined(separator: ". ") + "."
    }
}
