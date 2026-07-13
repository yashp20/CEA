import XCTest
@testable import CEA

/// Card JSON decoding (CLAUDE.md test requirements) including the mechanical
/// max-3-options cap.
final class CardDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> CardPayload {
        try JSONDecoder().decode(CardPayload.self, from: Data(json.utf8))
    }

    func testTopThreeDecodesAndCapsOptionsAtThree() throws {
        let json = """
        {"type":"top_three","title":"Indian food nearby","options":[
            {"name":"A","summary":"s1","rating":4.5,"wheelchair_accessible":true},
            {"name":"B","open_now":true,"wheelchair_accessible":false},
            {"name":"C","distance_text":"400 m"},
            {"name":"D"},
            {"name":"E"}
        ]}
        """
        guard case .topThree(let card) = try decode(json) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(card.options.count, 3, "options must be capped at 3 regardless of model output")
        XCTAssertEqual(card.title, "Indian food nearby")
        XCTAssertEqual(card.options[0].wheelchairAccessible, true)
        XCTAssertEqual(card.options[1].wheelchairAccessible, false)
        XCTAssertNil(card.options[2].wheelchairAccessible, "missing accessibility data must decode as unknown, not false")
    }

    func testRideConfirmDecodes() throws {
        let json = """
        {"type":"ride_confirm","summary":"Pickup at home, drop-off Union Station.",
         "pickup_name":"Home","destination_name":"Union Station",
         "pickup_latitude":41.87,"pickup_longitude":-87.62,
         "destination_latitude":41.88,"destination_longitude":-87.64,
         "note":"Accessible ride types are chosen in the app."}
        """
        guard case .rideConfirm(let card) = try decode(json) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(card.destinationName, "Union Station")
        XCTAssertEqual(card.pickupLatitude ?? 0, 41.87, accuracy: 0.001)
        XCTAssertNotNil(card.note)
    }

    func testHandoffDecodesAndCapsActions() throws {
        let json = """
        {"type":"handoff","title":"Ride ready","actions":[
            {"label":"Open Uber","url":"uber://?action=setPickup","detail":"Pre-filled"},
            {"label":"Open Lyft","url":"https://lyft.com/ride"},
            {"label":"X","url":"https://x.example"},
            {"label":"Y","url":"https://y.example"}
        ],"fallbacks":[{"label":"Directions","url":"https://maps.apple.com/?daddr=1,2"}]}
        """
        guard case .handoff(let card) = try decode(json) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(card.actions.count, 3, "handoff actions must be capped at 3")
        XCTAssertEqual(card.actions[0].url?.scheme, "uber")
        XCTAssertEqual(card.fallbacks?.count, 1)
    }

    func testUnknownCardTypeThrows() {
        XCTAssertThrowsError(try decode(#"{"type":"mystery_card"}"#))
    }

    func testCardRoundTripThroughTranscriptStorage() throws {
        let original = CardPayload.handoff(HandoffCard(
            title: "T",
            actions: [HandoffAction(label: "Open", urlString: "https://example.com", detail: "d")]
        ))
        let data = try JSONEncoder().encode(original)
        let message = ChatMessage(role: .assistant, text: "", cardJSON: String(data: data, encoding: .utf8))
        XCTAssertEqual(message.card, original)
    }

    // MARK: API wire shapes

    func testToolUseBlockDecodes() throws {
        let json = """
        {"content":[
            {"type":"text","text":"Let me check."},
            {"type":"tool_use","id":"toolu_1","name":"search_places","input":{"query":"thai","latitude":41.8}}
        ],"stop_reason":"tool_use"}
        """
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.stopReason, "tool_use")
        guard case .toolUse(let id, let name, let input) = response.content[1] else {
            return XCTFail("expected tool_use block")
        }
        XCTAssertEqual(id, "toolu_1")
        XCTAssertEqual(name, "search_places")
        XCTAssertEqual(input["query"]?.stringValue, "thai")
        XCTAssertEqual(input["latitude"]?.doubleValue ?? 0, 41.8, accuracy: 0.001)
    }

    func testToolResultEncodesWithError() throws {
        let block = APIContentBlock.toolResult(toolUseID: "toolu_1", content: "boom", isError: true)
        let data = try JSONEncoder().encode(block)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""type":"tool_result""#))
        XCTAssertTrue(json.contains(#""tool_use_id":"toolu_1""#))
        XCTAssertTrue(json.contains(#""is_error":true"#))
    }

    func testUnknownContentBlockDecodesAsEmptyText() throws {
        let json = #"{"content":[{"type":"thinking","thinking":""}],"stop_reason":"end_turn"}"#
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        guard case .text(let text) = response.content[0] else {
            return XCTFail("expected tolerant text decode")
        }
        XCTAssertEqual(text, "")
    }
}
