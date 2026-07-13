import SwiftData
import XCTest
@testable import CEA

/// v1.1 §5 / §6 — the memory privacy split: sensitive profile fields never
/// leave the device; only non-sensitive preference memory reaches the vendor
/// backend; delete-all clears vendor-side too.
final class MemoryPrivacyTests: XCTestCase {

    /// Records every call; nothing leaves the process.
    private final class SpyBackend: MemoryBackending, @unchecked Sendable {
        var synced: [(key: String, value: String)] = []
        var deleted: [String] = []
        var deleteAllCount = 0

        func sync(key: String, value: String) async {
            guard MemoryPrivacyFilter.isVendorSyncable(key: key) else { return }
            synced.append((key, value))
        }
        func delete(key: String) async { deleted.append(key) }
        func deleteAll() async { deleteAllCount += 1 }
    }

    /// Kept alive for the duration of each test — the store's context dies
    /// with its container.
    private var container: ModelContainer?

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    @MainActor
    private func makeStore(backend: MemoryBackending) throws -> ProfileStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AccessibilityProfile.self, PreferenceMemory.self, ChatSession.self, ChatMessage.self,
            ShortcutUsage.self, Routine.self, RoutineStep.self, QueuedSurvey.self,
            configurations: config
        )
        self.container = container
        return ProfileStore(context: container.mainContext, memoryBackend: backend)
    }

    // MARK: The wire payload structurally cannot carry the profile

    func testVendorPayloadContainsOnlyPreferenceFields() throws {
        let data = try XCTUnwrap(ProxyMemoryBackend.payload(
            op: "add", namespace: "ns", key: "favorite_cuisine", value: "thai"
        ))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Exactly these keys — nothing profile-shaped can ride along.
        XCTAssertEqual(Set(object.keys), ["op", "namespace", "key", "value"])

        // And none of the AccessibilityProfile field names appear anywhere
        // in the encoded payload.
        let encoded = String(decoding: data, as: UTF8.self).lowercased()
        let profileFields = [
            "colorblindness", "lowvision", "largertext", "highcontrast", "blindness",
            "hearingimpaired", "captions", "wheelchair", "avoidstairs",
            "simplifiedmode", "reducemotion", "voicefirst", "spokenresponses",
            "hapticconfirmations", "verbosity", "onboardingcompleted",
        ]
        for field in profileFields {
            XCTAssertFalse(encoded.contains(field), "profile field \(field) leaked into vendor payload")
        }
    }

    // MARK: Sensitive-looking keys never sync

    func testPrivacyFilterBlocksSensitiveKeys() {
        XCTAssertTrue(MemoryPrivacyFilter.isVendorSyncable(key: "favorite_cuisine"))
        XCTAssertTrue(MemoryPrivacyFilter.isVendorSyncable(key: "frequent_destination"))
        XCTAssertFalse(MemoryPrivacyFilter.isVendorSyncable(key: "health_condition"))
        XCTAssertFalse(MemoryPrivacyFilter.isVendorSyncable(key: "medication_time"))
        XCTAssertFalse(MemoryPrivacyFilter.isVendorSyncable(key: "disability_notes"))
        XCTAssertFalse(MemoryPrivacyFilter.isVendorSyncable(key: "accessibility_profile"))
    }

    @MainActor
    func testSavePreferenceSyncsOnlyNonSensitiveKeys() async throws {
        let spy = SpyBackend()
        let store = try makeStore(backend: spy)

        store.savePreference(key: "favorite_cuisine", value: "thai")
        store.savePreference(key: "medication_time", value: "9am") // stays local-only
        // Drain the fire-and-forget sync tasks.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spy.synced.map(\.key), ["favorite_cuisine"])
        // Both live in the local ledger regardless.
        XCTAssertEqual(store.memories().count, 2)
    }

    // MARK: Profile mutations never touch the backend

    @MainActor
    func testProfileChangesNeverReachVendor() async throws {
        let spy = SpyBackend()
        let store = try makeStore(backend: spy)

        store.profile.wheelchair = true
        store.profile.blindness = true
        store.profile.colorBlindnessTypeRaw = ColorBlindType.deuteranopia.rawValue
        store.save()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(spy.synced.isEmpty)
        XCTAssertTrue(spy.deleted.isEmpty)
        XCTAssertEqual(spy.deleteAllCount, 0)
    }

    // MARK: Delete-all clears both sides

    @MainActor
    func testDeleteAllClearsLocalAndVendor() async throws {
        let spy = SpyBackend()
        let store = try makeStore(backend: spy)
        store.savePreference(key: "favorite_cuisine", value: "thai")

        store.deleteAllMemory()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(store.memories().isEmpty)
        XCTAssertEqual(spy.deleteAllCount, 1)
    }

    @MainActor
    func testSingleDeleteAlsoDeletesVendorSide() async throws {
        let spy = SpyBackend()
        let store = try makeStore(backend: spy)
        store.savePreference(key: "favorite_cuisine", value: "thai")

        if let memory = store.memories().first {
            store.deleteMemory(memory)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spy.deleted, ["favorite_cuisine"])
    }
}
