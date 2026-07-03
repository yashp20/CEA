import Foundation
import SwiftData

/// The structured accessibility profile (PRD F1/F3/F5). Single instance,
/// on-device only, injected into every LLM system prompt as a short summary.
@Model
final class AccessibilityProfile {
    // Vision
    var colorBlindness: Bool
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

    // Bookkeeping
    var onboardingCompleted: Bool
    var createdAt: Date

    init(
        colorBlindness: Bool = false,
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
        onboardingCompleted: Bool = false
    ) {
        self.colorBlindness = colorBlindness
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
        self.onboardingCompleted = onboardingCompleted
        self.createdAt = .now
    }
}

extension AccessibilityProfile {
    /// Plain-language summary injected into the system prompt (PRD F3).
    /// Kept short: only active needs are mentioned.
    var promptSummary: String {
        var needs: [String] = []
        if blindness { needs.append("blind or low-vision VoiceOver user: every reply must be fully self-describing spoken text, never reference visual layout like 'see below'") }
        else if lowVision { needs.append("low vision: prefers concise spoken-friendly descriptions") }
        if colorBlindness { needs.append("color blindness: never describe anything by color alone") }
        if hearingImpaired { needs.append("deaf or hard of hearing: never reference sounds; confirmations are visual and haptic") }
        if wheelchair { needs.append("wheelchair user: prefer wheelchair-accessible venues and accessible ride types; mention accessibility info when known, say when it is unavailable") }
        else if avoidStairs { needs.append("avoids stairs: prefer step-free venues and routes") }
        if simplifiedMode { needs.append("cognitive/attention needs: simplest sentence forms, numbered choices, one idea per sentence") }
        if voiceFirst { needs.append("voice-first user: keep replies natural to hear aloud") }
        if needs.isEmpty { return "No specific accessibility needs recorded. Use the default calm, concise style." }
        return "User accessibility profile: " + needs.joined(separator: ". ") + "."
    }
}
