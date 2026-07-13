import Foundation

/// v1.1 §3.6 — the verbosity/complexity dial. Generalizes the 3-option /
/// 3-sentence cap into a profile-driven layer: the same underlying answer is
/// rendered terse-and-dense for a power user, short-simple-literal for the
/// cognitive profile, or rich-and-descriptive for a blind user who wants the
/// detail a sighted user gets visually.
///
/// Two halves, both in-repo (this logic is CEA's differentiator, not a
/// vendor's): system-prompt shaping (`promptDirectives`) and a mechanical
/// post-processing guardrail (`shape`) that enforces the caps regardless of
/// model output — the same belt-and-suspenders pattern as the card renderer's
/// max-3 rule.
enum ResponseStyle: String {
    case terse
    case simple
    case standard
    case rich
}

enum ResponseShaper {

    /// Effective style for a profile: an explicit user override wins;
    /// `auto` derives from the rest of the profile.
    static func style(for profile: AccessibilityProfile) -> ResponseStyle {
        switch profile.verbosity {
        case .terse: return .terse
        case .simple: return .simple
        case .standard: return .standard
        case .rich: return .rich
        case .auto:
            if profile.simplifiedMode { return .simple }
            if profile.blindness { return .rich }
            return .standard
        }
    }

    /// Injected into the system prompt so the model writes for the style.
    static func promptDirectives(for style: ResponseStyle) -> String {
        switch style {
        case .terse:
            return """
            Verbosity: TERSE. This user wants maximum information density. Fewest words that \
            carry the facts; no pleasantries, no restating their request. At most 2 sentences.
            """
        case .simple:
            return """
            Verbosity: SIMPLE. Shortest common words, literal language, one idea per sentence. \
            Number every set of choices (1., 2., 3.). Never use idioms or figures of speech. \
            At most 3 short sentences.
            """
        case .standard:
            return "Verbosity: STANDARD. Calm and concise, at most 3 sentences."
        case .rich:
            return """
            Verbosity: RICH. This user cannot skim a screen, so give the detail a sighted user \
            would absorb visually: describe options fully (distance, rating with count, whether \
            it's open, accessibility info or its absence) in flowing spoken-friendly prose. \
            Up to 6 sentences when the content warrants it; never pad.
            """
        }
    }

    /// Hard sentence cap enforced mechanically after generation.
    static func maxSentences(for style: ResponseStyle) -> Int {
        switch style {
        case .terse: return 2
        case .simple: return 3
        case .standard: return 3
        case .rich: return 8 // generous ceiling; the prompt asks for ≤6
        }
    }

    /// Mechanical post-pass: truncate to the style's sentence cap (preserving
    /// the original text, including line breaks in numbered lists) and strip
    /// exclamation-mark enthusiasm. Never rewrites content.
    static func shape(_ text: String, style: ResponseStyle) -> String {
        let cap = maxSentences(for: style)
        var result = text
        let boundaries = sentenceBoundaries(in: text)
        if sentenceCount(in: text) > cap, boundaries.count >= cap {
            let chars = Array(text)
            result = String(chars[..<boundaries[cap - 1]])
        }
        // Style contract: no exclamation marks (word-final only, so names
        // containing "!" are left alone).
        result = result.replacingOccurrences(
            of: "!(\\s)", with: ".$1", options: .regularExpression
        )
        if result.hasSuffix("!") {
            result = String(result.dropLast()) + "."
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Number of sentences, where bare list markers ("1.", "2.") do not end
    /// a sentence — "1. Confirm pickup." is one sentence, not two.
    static func sentenceCount(in text: String) -> Int {
        let boundaries = sentenceBoundaries(in: text)
        let chars = Array(text)
        let lastBoundary = boundaries.last ?? 0
        let tail = lastBoundary < chars.count
            ? String(chars[lastBoundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return boundaries.count + (tail.isEmpty ? 0 : 1)
    }

    /// Character offsets just past each sentence terminator (. ! ? … or a
    /// non-empty line break). List markers like "1." never end a sentence.
    static func sentenceBoundaries(in text: String) -> [Int] {
        let chars = Array(text)
        let terminators: Set<Character> = [".", "!", "?", "…"]
        var boundaries: [Int] = []
        var sentenceStart = 0

        for index in 0..<chars.count {
            let char = chars[index]
            if char == "\n" {
                let line = String(chars[sentenceStart..<index])
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    boundaries.append(index + 1)
                }
                sentenceStart = index + 1
                continue
            }
            guard terminators.contains(char) else { continue }
            let atEnd = index == chars.count - 1
            guard atEnd || chars[index + 1].isWhitespace else { continue }
            if char == "." {
                let sentence = String(chars[sentenceStart...index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let core = String(sentence.dropLast())
                let isListMarker = !core.isEmpty && core.count <= 3 && core.allSatisfy(\.isNumber)
                if isListMarker { continue }
            }
            boundaries.append(index + 1)
            sentenceStart = index + 1
        }
        return boundaries
    }
}
