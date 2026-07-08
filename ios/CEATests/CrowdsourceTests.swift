import XCTest
@testable import CEA

/// Crowdsource report storage/retrieval logic (v1.1 §3.1 / §6): venue keys,
/// aggregate decoding, honest provenance, barrier flags, survey timing.
final class CrowdsourceTests: XCTestCase {

    // MARK: Venue keys

    func testVenueKeyNormalization() {
        let key = CrowdsourceService.venueKey(name: "Lou Malnati's Pizzeria", latitude: 41.8781234, longitude: -87.6297999)
        XCTAssertEqual(key, "lou malnatis pizzeria@41.878,-87.630")
        // Stable across messy re-spellings of the same place.
        let again = CrowdsourceService.venueKey(name: "LOU MALNATIS pizzeria", latitude: 41.87799, longitude: -87.62988)
        XCTAssertEqual(key, again)
    }

    // MARK: Aggregate decoding (worker wire format)

    private func decodeAggregate(_ json: String) throws -> CrowdAggregate {
        try JSONDecoder().decode(CrowdAggregate.self, from: Data(json.utf8))
    }

    func testAggregateDecoding() throws {
        let aggregate = try decodeAggregate(
            #"{"total":4,"attributes":{"step_free_entry":{"yes":3,"no":0,"last_at":"2026-06-20T12:00:00.000Z"},"low_noise":{"yes":0,"no":1,"last_at":"2026-06-01T12:00:00.000Z"}}}"#
        )
        XCTAssertEqual(aggregate.total, 4)
        XCTAssertEqual(aggregate.entry(for: .stepFreeEntry)?.yes, 3)
        XCTAssertEqual(aggregate.entry(for: .lowNoise)?.no, 1)
        XCTAssertNotNil(aggregate.entry(for: .stepFreeEntry)?.lastAt)
        XCTAssertNil(aggregate.entry(for: .doorWidth))
    }

    // MARK: Provenance (honest by construction)

    func testProvenanceConfirmed() throws {
        let now = ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z")!
        let aggregate = try decodeAggregate(
            #"{"total":3,"attributes":{"step_free_entry":{"yes":3,"no":0,"last_at":"2026-06-20T12:00:00.000Z"}}}"#
        )
        let line = CrowdsourceService.provenanceLine(aggregate: aggregate, for: .stepFreeEntry, now: now)
        XCTAssertTrue(line.contains("confirmed by 3 CEA users"), line)
        XCTAssertTrue(line.contains("last confirmed 2 weeks ago"), line)
    }

    func testProvenanceSingularUser() throws {
        let aggregate = try decodeAggregate(
            #"{"total":1,"attributes":{"asl_friendly":{"yes":1,"no":0,"last_at":"2026-07-01T12:00:00.000Z"}}}"#
        )
        let line = CrowdsourceService.provenanceLine(aggregate: aggregate, for: .aslFriendly)
        XCTAssertTrue(line.contains("1 CEA user,"), line)
    }

    func testProvenanceMixedReports() throws {
        let aggregate = try decodeAggregate(
            #"{"total":3,"attributes":{"step_free_entry":{"yes":2,"no":1,"last_at":"2026-07-01T12:00:00.000Z"}}}"#
        )
        let line = CrowdsourceService.provenanceLine(aggregate: aggregate, for: .stepFreeEntry)
        XCTAssertTrue(line.contains("Mixed reports"), line)
        XCTAssertTrue(line.contains("2 yes, 1 no"), line)
    }

    func testProvenanceNoReports() {
        XCTAssertEqual(
            CrowdsourceService.provenanceLine(aggregate: nil, for: .stepFreeEntry),
            "No reports from CEA users yet."
        )
        let empty = CrowdAggregate(total: 0, attributes: [:])
        XCTAssertEqual(
            CrowdsourceService.provenanceLine(aggregate: empty, for: .stepFreeEntry),
            "No reports from CEA users yet."
        )
    }

    // MARK: Barrier detection

    func testBarrierFlagOnlyForMobilityProfilesAndNegativeReports() throws {
        let negative = try decodeAggregate(
            #"{"total":2,"attributes":{"step_free_entry":{"yes":0,"no":2,"last_at":"2026-07-01T12:00:00.000Z"}}}"#
        )
        let wheelchair = AccessibilityProfile(wheelchair: true)
        XCTAssertNotNil(CrowdsourceService.barrierWarning(aggregate: negative, profile: wheelchair))
        // No mobility need → no flag, even with negative reports.
        XCTAssertNil(CrowdsourceService.barrierWarning(aggregate: negative, profile: AccessibilityProfile()))
        // Positive reports → no flag.
        let positive = try decodeAggregate(
            #"{"total":2,"attributes":{"step_free_entry":{"yes":2,"no":0,"last_at":"2026-07-01T12:00:00.000Z"}}}"#
        )
        XCTAssertNil(CrowdsourceService.barrierWarning(aggregate: positive, profile: wheelchair))
        // Missing data is never inferred as a barrier.
        XCTAssertNil(CrowdsourceService.barrierWarning(aggregate: nil, profile: wheelchair))
    }

    // MARK: Profile-adapted question order

    func testQuestionOrderAdaptsToProfile() {
        let wheelchair = CrowdsourceService.priorityAttributes(for: AccessibilityProfile(wheelchair: true))
        XCTAssertEqual(wheelchair.first, .stepFreeEntry)
        let deaf = CrowdsourceService.priorityAttributes(for: AccessibilityProfile(hearingImpaired: true))
        XCTAssertEqual(deaf.first, .aslFriendly)
        // Everyone gets the full vocabulary, no duplicates.
        XCTAssertEqual(Set(wheelchair).count, CrowdAttribute.allCases.count)
        XCTAssertEqual(wheelchair.count, CrowdAttribute.allCases.count)
    }

    // MARK: Survey timing (never interrupt an in-progress action)

    func testSurveyNotEligibleImmediatelyAfterHandoff() {
        let survey = QueuedSurvey(venueKey: "k", venueName: "Star of Siam", latitude: 41.9, longitude: -87.6, handoffAt: .now)
        let result = SurveyLogic.eligibleSurvey(from: [survey], profile: AccessibilityProfile())
        XCTAssertNil(result, "a survey minutes after the hand-off would interrupt the errand")
    }

    func testSurveyEligibleAfterQuietPeriod() {
        let survey = QueuedSurvey(venueKey: "k", venueName: "Star of Siam", latitude: 41.9, longitude: -87.6,
                                  handoffAt: .now.addingTimeInterval(-3 * 60 * 60))
        let result = SurveyLogic.eligibleSurvey(from: [survey], profile: AccessibilityProfile())
        XCTAssertTrue(result === survey)
    }

    func testDismissedCompletedAndDisabledAreNeverEligible() {
        let old = Date.now.addingTimeInterval(-3 * 60 * 60)
        let dismissed = QueuedSurvey(venueKey: "a", venueName: "A", latitude: 0, longitude: 0, handoffAt: old)
        dismissed.dismissed = true
        let completed = QueuedSurvey(venueKey: "b", venueName: "B", latitude: 0, longitude: 0, handoffAt: old)
        completed.completedAt = .now
        XCTAssertNil(SurveyLogic.eligibleSurvey(from: [dismissed, completed], profile: AccessibilityProfile()))

        // The kill switch: prompts off → nothing surfaces, ever.
        let eligible = QueuedSurvey(venueKey: "c", venueName: "C", latitude: 0, longitude: 0, handoffAt: old)
        let optedOut = AccessibilityProfile(surveyPromptsEnabled: false)
        XCTAssertNil(SurveyLogic.eligibleSurvey(from: [eligible], profile: optedOut))
    }
}
