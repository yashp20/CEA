import XCTest
@testable import CEA

/// Verbosity-shaping output per profile (v1.1 §3.6 / §6).
final class ResponseShaperTests: XCTestCase {

    // MARK: Style derivation

    func testDefaultProfileIsStandard() {
        XCTAssertEqual(ResponseShaper.style(for: AccessibilityProfile()), .standard)
    }

    func testCognitiveProfileDerivesSimple() {
        XCTAssertEqual(ResponseShaper.style(for: AccessibilityProfile(simplifiedMode: true)), .simple)
    }

    func testBlindProfileDerivesRich() {
        XCTAssertEqual(ResponseShaper.style(for: AccessibilityProfile(blindness: true)), .rich)
    }

    func testExplicitOverrideBeatsDerivation() {
        // A blind user who prefers terse replies gets terse, not rich.
        let profile = AccessibilityProfile(blindness: true, verbosityRaw: VerbosityLevel.terse.rawValue)
        XCTAssertEqual(ResponseShaper.style(for: profile), .terse)
    }

    // MARK: Prompt directives

    func testDirectivesDifferPerStyle() {
        let all: [ResponseStyle] = [.terse, .simple, .standard, .rich]
        let directives = all.map { ResponseShaper.promptDirectives(for: $0) }
        XCTAssertEqual(Set(directives).count, all.count)
        XCTAssertTrue(ResponseShaper.promptDirectives(for: .simple).contains("Number"))
        XCTAssertTrue(ResponseShaper.promptDirectives(for: .rich).contains("spoken-friendly"))
    }

    func testSystemPromptInjectsDirectives() {
        let prompt = SystemPrompt.build(
            profileSummary: "x",
            memoryLines: "y",
            styleDirectives: "STYLE_SENTINEL"
        )
        XCTAssertTrue(prompt.contains("STYLE_SENTINEL"))
    }

    // MARK: Sentence counting

    func testSentenceCounting() {
        XCTAssertEqual(ResponseShaper.sentenceCount(in: "One. Two? Three."), 3)
        XCTAssertEqual(ResponseShaper.sentenceCount(in: "No terminator at all"), 1)
        XCTAssertEqual(ResponseShaper.sentenceCount(in: ""), 0)
    }

    func testListMarkersDoNotEndSentences() {
        // "1. Confirm pickup." is one sentence, not two (simplified mode
        // relies on numbered choices surviving the shaper).
        let text = "Okay. 1. Confirm pickup at your location. 2. I prepare the ride."
        XCTAssertEqual(ResponseShaper.sentenceCount(in: text), 3)
    }

    // MARK: Mechanical shaping

    private let fiveSentences = "First fact. Second fact. Third fact. Fourth fact. Fifth fact."

    func testTerseCapsAtTwoSentences() {
        let shaped = ResponseShaper.shape(fiveSentences, style: .terse)
        XCTAssertEqual(shaped, "First fact. Second fact.")
    }

    func testStandardCapsAtThreeSentences() {
        let shaped = ResponseShaper.shape(fiveSentences, style: .standard)
        XCTAssertEqual(shaped, "First fact. Second fact. Third fact.")
    }

    func testRichKeepsAllFiveSentences() {
        XCTAssertEqual(ResponseShaper.shape(fiveSentences, style: .rich), fiveSentences)
    }

    func testShapePreservesNumberedListLineBreaks() {
        let text = "Two choices.\n1. Thai Palace, 400 meters away.\n2. Star of Siam, open now."
        let shaped = ResponseShaper.shape(text, style: .simple)
        XCTAssertEqual(shaped, text) // 3 sentences — untouched, newlines intact
    }

    func testExclamationMarksBecomePeriods() {
        XCTAssertEqual(ResponseShaper.shape("Found it! Great spot.", style: .standard),
                       "Found it. Great spot.")
        XCTAssertEqual(ResponseShaper.shape("Done!", style: .standard), "Done.")
    }

    func testShapeNeverRewritesWithinCap() {
        let text = "Pickup at home, drop-off Union Station — shall I prepare Uber and Lyft?"
        XCTAssertEqual(ResponseShaper.shape(text, style: .standard), text)
    }
}
