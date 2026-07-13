import XCTest
@testable import CEA

/// Profile serialization into the system prompt (CLAUDE.md test requirements).
final class SystemPromptTests: XCTestCase {

    func testDefaultProfileSummary() {
        let profile = AccessibilityProfile()
        XCTAssertTrue(profile.promptSummary.contains("No specific accessibility needs"))
    }

    func testWheelchairProfileSummary() {
        let profile = AccessibilityProfile(wheelchair: true)
        XCTAssertTrue(profile.promptSummary.contains("wheelchair"))
        XCTAssertTrue(profile.promptSummary.contains("unavailable"))
    }

    func testBlindProfileTrumpsLowVision() {
        let profile = AccessibilityProfile(lowVision: true, blindness: true)
        XCTAssertTrue(profile.promptSummary.contains("VoiceOver"))
        XCTAssertTrue(profile.promptSummary.contains("self-describing"))
    }

    func testDeafProfileNeverReferencesSounds() {
        let profile = AccessibilityProfile(hearingImpaired: true)
        XCTAssertTrue(profile.promptSummary.contains("never reference sounds"))
    }

    func testCognitiveProfileSummary() {
        let profile = AccessibilityProfile(simplifiedMode: true)
        XCTAssertTrue(profile.promptSummary.contains("numbered choices"))
    }

    func testPromptInjectsProfileAndMemory() {
        let prompt = SystemPrompt.build(
            profileSummary: "PROFILE_SENTINEL",
            memoryLines: "- favorite_cuisine: thai"
        )
        XCTAssertTrue(prompt.contains("PROFILE_SENTINEL"))
        XCTAssertTrue(prompt.contains("favorite_cuisine: thai"))
        // Style contract essentials are present.
        XCTAssertTrue(prompt.contains("3 sentences"))
        XCTAssertTrue(prompt.contains("more than 3 options") || prompt.contains("3 options"))
        XCTAssertTrue(prompt.contains("confirms the final"))
    }

    @MainActor
    func testAPITranscriptMapping() {
        let history = [
            ChatMessage(role: .user, text: "hi", createdAt: .now),
            ChatMessage(role: .notice, text: "Saved: something", createdAt: .now),
            ChatMessage(role: .assistant, text: "hello", createdAt: .now),
            ChatMessage(role: .assistant, text: "second part", createdAt: .now),
        ]
        let transcript = AgentClient.apiTranscript(from: history)
        XCTAssertEqual(transcript.count, 2)
        XCTAssertEqual(transcript[0].role, "user")
        XCTAssertEqual(transcript[1].role, "assistant")
        XCTAssertEqual(transcript[1].content.count, 2) // merged same-role turns
    }

    @MainActor
    func testAPITranscriptDropsLeadingAssistant() {
        let history = [ChatMessage(role: .assistant, text: "welcome", createdAt: .now)]
        let transcript = AgentClient.apiTranscript(from: history)
        XCTAssertTrue(transcript.isEmpty)
    }
}
