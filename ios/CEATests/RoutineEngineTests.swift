import XCTest
@testable import CEA

/// Routine step execution logic (v1.1 §3.2 / §6): ordering, params
/// round-trips, confirmation requirements, and registry-built ride links.
final class RoutineEngineTests: XCTestCase {

    private func rideStep(order: Int = 0) -> RoutineStep {
        RoutineStep(
            orderIndex: order,
            kindRaw: RoutineStepKind.rideHandoff.rawValue,
            title: "Ride to Union Station",
            paramsJSON: RoutineEngine.encode(RideStepParams(
                destinationName: "Union Station",
                destinationLatitude: 41.878900,
                destinationLongitude: -87.640000
            ))
        )
    }

    private func messageStep(order: Int = 1) -> RoutineStep {
        RoutineStep(
            orderIndex: order,
            kindRaw: RoutineStepKind.ownAccount.rawValue,
            title: "Text Maya my ETA",
            paramsJSON: RoutineEngine.encode(OwnAccountStepParams(
                kind: "message",
                summary: "Text Maya: on my way, ETA 15 minutes.",
                toolName: "send_sms",
                argumentsJSON: "{\"to\":\"Maya\"}"
            ))
        )
    }

    // MARK: Kind + params round-trips

    func testRideParamsRoundTrip() {
        let step = rideStep()
        XCTAssertEqual(RoutineEngine.kind(of: step), .rideHandoff)
        let params = RoutineEngine.rideParams(step)
        XCTAssertEqual(params?.destinationName, "Union Station")
        XCTAssertEqual(params?.destinationLatitude ?? 0, 41.8789, accuracy: 0.0001)
        // Wrong-kind accessors return nil, never garbage.
        XCTAssertNil(RoutineEngine.ownAccountParams(step))
    }

    func testOwnAccountParamsRoundTrip() {
        let step = messageStep()
        XCTAssertEqual(RoutineEngine.kind(of: step), .ownAccount)
        let params = RoutineEngine.ownAccountParams(step)
        XCTAssertEqual(params?.toolName, "send_sms")
        XCTAssertEqual(params?.kind, "message")
        XCTAssertEqual(params?.argumentsJSON, "{\"to\":\"Maya\"}")
        XCTAssertNil(RoutineEngine.rideParams(step))
    }

    func testUnknownKindIsNilNotCrash() {
        let step = RoutineStep(orderIndex: 0, kindRaw: "teleport", title: "??", paramsJSON: "{}")
        XCTAssertNil(RoutineEngine.kind(of: step))
        XCTAssertNil(RoutineEngine.rideParams(step))
    }

    // MARK: Side-effect confirmation rule

    func testOnlyOwnAccountStepsRequireConfirmation() {
        // Ride steps are hand-offs (open another app, no side effect);
        // own-account steps send/create something → explicit confirm.
        XCTAssertFalse(RoutineEngine.requiresConfirmation(rideStep()))
        XCTAssertTrue(RoutineEngine.requiresConfirmation(messageStep()))
    }

    // MARK: Plan (visible before anything runs)

    func testPlanPreservesOrderAndFlags() {
        let routine = Routine(name: "Going home")
        let ride = rideStep(order: 0)
        let message = messageStep(order: 1)
        // Attach out of order; the plan must sort by orderIndex.
        routine.steps = [message, ride]

        let plan = RoutineEngine.plan(for: routine)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].title, "Ride to Union Station")
        XCTAssertEqual(plan[0].kind, .rideHandoff)
        XCTAssertFalse(plan[0].requiresConfirmation)
        XCTAssertEqual(plan[1].title, "Text Maya my ETA")
        XCTAssertTrue(plan[1].requiresConfirmation)
    }

    // MARK: Ride links go through the registry

    func testRideLinksUseRegistryWithDestination() {
        let params = RideStepParams(destinationName: "Union Station",
                                    destinationLatitude: 41.8789,
                                    destinationLongitude: -87.64)
        let pickup = RidePoint(latitude: 41.878, longitude: -87.63, nickname: "Current location", formattedAddress: nil)
        let links = RoutineEngine.rideLinks(for: params, pickup: pickup)

        XCTAssertEqual(links.uber.platform, .uber)
        XCTAssertEqual(links.lyft.platform, .lyft)
        let uberQuery = URLComponents(url: links.uber.webURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "dropoff[nickname]" }?.value
        XCTAssertEqual(uberQuery, "Union Station")
        XCTAssertTrue(links.uber.detail.contains("never books"))
    }

    // MARK: One-utterance matching

    func testRoutineNameMatching() {
        let home = Routine(name: "Going home")
        let meds = Routine(name: "Morning meds")
        let all = [home, meds]

        XCTAssertTrue(RoutineEngine.match("going home", in: all) === home)
        XCTAssertTrue(RoutineEngine.match("run my going home routine", in: all) === home)
        XCTAssertTrue(RoutineEngine.match("MORNING MEDS", in: all) === meds)
        XCTAssertNil(RoutineEngine.match("evening walk", in: all))
        XCTAssertNil(RoutineEngine.match("", in: all))
    }
}
