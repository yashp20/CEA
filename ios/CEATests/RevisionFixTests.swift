import SwiftData
import XCTest
@testable import CEA

/// Regression tests for the post-v1.1 revision bugs:
/// 1. shortcuts seed chats, never deep-link to apps;
/// 3. blank "New chat" sessions are reused/hidden/purged, not multiplied;
/// 4. hand-off cards are rendered mechanically by build_handoff_link with
///    registry URLs — never dependent on the model transcribing links.
final class RevisionFixTests: XCTestCase {

    private var container: ModelContainer?

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    @MainActor
    private func makeStore() throws -> (ProfileStore, ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AccessibilityProfile.self, PreferenceMemory.self, ChatSession.self, ChatMessage.self,
            ShortcutUsage.self, Routine.self, RoutineStep.self, QueuedSurvey.self,
            configurations: config
        )
        self.container = container
        struct NoopBackend: MemoryBackending {
            func sync(key: String, value: String) async {}
            func delete(key: String) async {}
            func deleteAll() async {}
        }
        return (ProfileStore(context: container.mainContext, memoryBackend: NoopBackend()), container.mainContext)
    }

    // MARK: Bug 1 — shortcuts are chat seeds only

    func testAllShortcutsSeedChatsNotApps() {
        XCTAssertFalse(CEAShortcut.defaults.isEmpty)
        for shortcut in CEAShortcut.defaults {
            XCTAssertFalse(shortcut.seedText.isEmpty, "\(shortcut.id) must seed a request")
            XCTAssertFalse(shortcut.seedText.lowercased().contains("http"), "\(shortcut.id) must not carry a link")
        }
        XCTAssertEqual(Set(CEAShortcut.defaults.map(\.id)).count, CEAShortcut.defaults.count, "shortcut ids must be unique")
    }

    func testHandoffUsageMapsToSeedShortcuts() {
        XCTAssertEqual(ShortcutUsageTracker.shortcutKey(for: URL(string: "uber://?action=setPickup")!), "seed-ride")
        XCTAssertEqual(ShortcutUsageTracker.shortcutKey(for: URL(string: "https://m.uber.com/ul/?x=1")!), "seed-ride")
        XCTAssertEqual(ShortcutUsageTracker.shortcutKey(for: URL(string: "https://lyft.com/ride?x=1")!), "seed-ride")
        XCTAssertEqual(ShortcutUsageTracker.shortcutKey(for: URL(string: "https://www.doordash.com/store/x-1")!), "seed-food")
        XCTAssertEqual(ShortcutUsageTracker.shortcutKey(for: URL(string: "https://maps.apple.com/?daddr=1,2")!), "seed-directions")
        XCTAssertNil(ShortcutUsageTracker.shortcutKey(for: URL(string: "tel:3125550142")!))
        XCTAssertNil(ShortcutUsageTracker.shortcutKey(for: URL(string: "https://example.com")!))
    }

    // MARK: Bug 3 — blank-session housekeeping

    @MainActor
    func testBlankSessionsAreReusedHiddenAndPurged() throws {
        let (_, context) = try makeStore()

        let written = ChatSession(title: "Ride to Union Station")
        context.insert(written)
        let message = ChatMessage(role: .user, text: "hi")
        message.session = written
        context.insert(message)
        let blankA = ChatSession()
        let blankB = ChatSession()
        context.insert(blankA)
        context.insert(blankB)
        try context.save()

        let all = [written, blankA, blankB]
        // Hidden from the list:
        XCTAssertEqual(SessionHousekeeping.listable(all).map(\.title), ["Ride to Union Station"])
        // Reused instead of minting a new one:
        XCTAssertNotNil(SessionHousekeeping.reusableEmpty(all))
        XCTAssertTrue(SessionHousekeeping.reusableEmpty(all)?.messages.isEmpty ?? false)
        // Purge keeps only the one in use:
        let redundant = SessionHousekeeping.redundantEmpties(all, keeping: blankA)
        XCTAssertEqual(redundant.count, 1)
        XCTAssertTrue(redundant.first === blankB)
        // A session with content is never considered redundant.
        XCTAssertFalse(SessionHousekeeping.redundantEmpties(all, keeping: nil).contains(where: { $0 === written }))
    }

    // MARK: Bug 4 — hand-off cards rendered mechanically

    @MainActor
    private func rideInput() -> JSONValue {
        .object([
            "kind": .string("ride"),
            "pickup_latitude": .number(41.878), "pickup_longitude": .number(-87.63),
            "pickup_name": .string("Home"),
            "destination_latitude": .number(41.8789), "destination_longitude": .number(-87.64),
            "destination_name": .string("Union Station"),
        ])
    }

    @MainActor
    func testBuildHandoffLinkRendersRideCardItself() async throws {
        let (store, _) = try makeStore()
        let toolbox = AgentToolbox(profileStore: store)

        var events: [AgentEvent] = []
        let result = await toolbox.execute(name: "build_handoff_link", input: rideInput()) { events.append($0) }

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("already displayed"))
        let cards = events.compactMap { if case .card(let card) = $0 { return card } else { return nil } }
        XCTAssertEqual(cards.count, 1)
        guard case .handoff(let handoff) = cards[0] else { return XCTFail("expected a handoff card") }
        XCTAssertEqual(handoff.title, "Ride to Union Station")
        XCTAssertEqual(handoff.actions.count, 2)
        // Every button must be openable — this is the bug the user hit.
        XCTAssertEqual(handoff.actions.compactMap(\.url).count, 2)
        XCTAssertTrue(handoff.actions[0].urlString.contains("uber"))
        XCTAssertTrue(handoff.actions[1].urlString.contains("lyft"))
    }

    @MainActor
    func testBuildHandoffLinkRendersFoodCardWithFallbacks() async throws {
        let (store, _) = try makeStore()
        let toolbox = AgentToolbox(profileStore: store)
        let input: JSONValue = .object([
            "kind": .string("food"),
            "restaurant_name": .string("Star of Siam"),
            "latitude": .number(41.891), "longitude": .number(-87.628),
            "phone": .string("(312) 555-0142"),
            "website": .string("https://starofsiam.example"),
        ])

        var events: [AgentEvent] = []
        let result = await toolbox.execute(name: "build_handoff_link", input: input) { events.append($0) }

        XCTAssertFalse(result.isError)
        let cards = events.compactMap { if case .card(let card) = $0 { return card } else { return nil } }
        guard case .handoff(let handoff)? = cards.first else { return XCTFail("expected a handoff card") }
        XCTAssertEqual(handoff.actions.count, 1)
        XCTAssertTrue(handoff.actions[0].urlString.contains("doordash.com/store/star-of-siam"))
        let fallbackLabels = (handoff.fallbacks ?? []).map(\.label)
        XCTAssertTrue(fallbackLabels.contains("Walking directions"))
        XCTAssertTrue(fallbackLabels.contains(where: { $0.hasPrefix("Call") }))
        XCTAssertTrue(fallbackLabels.contains("Website"))
        XCTAssertEqual((handoff.fallbacks ?? []).compactMap(\.url).count, 3)

        // §3.1: the food hand-off also queued the post-visit survey.
        XCTAssertEqual(store.pendingSurveys().count, 1)
        XCTAssertEqual(store.pendingSurveys().first?.venueName, "Star of Siam")
    }

    @MainActor
    func testRenderCardRejectsLinklessHandoff() async throws {
        let (store, _) = try makeStore()
        let toolbox = AgentToolbox(profileStore: store)
        // The failure mode the user saw: a handoff card with no usable links.
        let input: JSONValue = .object([
            "type": .string("handoff"),
            "title": .string("Ready to hand off"),
        ])

        var events: [AgentEvent] = []
        let result = await toolbox.execute(name: "render_card", input: input) { events.append($0) }

        XCTAssertTrue(result.isError)
        XCTAssertTrue(events.isEmpty, "an empty hand-off shell must never render")
        XCTAssertTrue(result.content.contains("build_handoff_link"))
    }

    func testHandoffActionURLIsLenient() {
        let messy = HandoffAction(label: "Maps", urlString: "https://maps.apple.com/?q=Star of Siam", detail: nil)
        XCTAssertNotNil(messy.url, "a space must not swallow a hand-off button")
    }
}
