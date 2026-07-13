import Foundation

/// v1.1 §5 — vendor persistence for PREFERENCE MEMORY ONLY (Super Memory via
/// the CEA proxy; the vendor key lives server-side, never in the bundle).
///
/// The privacy split, enforced here and asserted by tests:
/// - The accessibility profile (disability/health-adjacent) is NEVER sent to
///   the memory vendor. The payload type below is built from preference
///   key/value strings only — it structurally cannot carry profile fields.
/// - Only non-sensitive preference memory syncs; sensitive-looking keys are
///   filtered out and stay local-only.
/// - The local SwiftData ledger remains the user-visible source of truth;
///   the vendor is just storage. The profile-shaping logic that turns memory
///   into adapted responses stays in this repo (SystemPrompt/ResponseShaper).
/// - "Delete all memory" clears local AND vendor-side.
protocol MemoryBackending {
    func sync(key: String, value: String) async
    func delete(key: String) async
    func deleteAll() async
}

/// Belt-and-suspenders filter: save_preference already forbids sensitive
/// data, but nothing that even looks health/disability-adjacent may reach
/// the vendor. Blocked keys still work locally.
enum MemoryPrivacyFilter {
    private static let blockedFragments = [
        "health", "medical", "diagnos", "disab", "condition",
        "medicat", "therap", "symptom", "profile", "accessib",
    ]

    static func isVendorSyncable(key: String) -> Bool {
        let normalized = key.lowercased()
        return !blockedFragments.contains { normalized.contains($0) }
    }
}

/// Anonymous, install-scoped namespace for vendor storage — a random UUID,
/// never derived from the user's identity or profile.
enum MemoryNamespace {
    private static let defaultsKey = "cea.memory.namespace"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }
}

/// The exact wire payload sent to the proxy's /memory route. Built ONLY from
/// preference-memory strings; adding a profile field here should fail code
/// review and the privacy tests.
struct VendorMemoryPayload: Codable, Equatable {
    var op: String        // add | delete | delete_all
    var namespace: String
    var key: String?
    var value: String?
}

/// Talks to the proxy's /memory route (which forwards to Super Memory with
/// the server-side key). Best-effort: the local ledger is authoritative, so
/// sync failures degrade silently; nothing is ever faked as synced.
struct ProxyMemoryBackend: MemoryBackending {

    static func payload(op: String, namespace: String, key: String? = nil, value: String? = nil) -> Data? {
        try? JSONEncoder().encode(VendorMemoryPayload(op: op, namespace: namespace, key: key, value: value))
    }

    func sync(key: String, value: String) async {
        guard MemoryPrivacyFilter.isVendorSyncable(key: key) else { return }
        await post(Self.payload(op: "add", namespace: MemoryNamespace.id, key: key, value: value))
    }

    func delete(key: String) async {
        await post(Self.payload(op: "delete", namespace: MemoryNamespace.id, key: key))
    }

    func deleteAll() async {
        await post(Self.payload(op: "delete_all", namespace: MemoryNamespace.id))
    }

    private func post(_ body: Data?) async {
        guard let body, let url = ProxyConfig.baseURL?.appending(path: "memory") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }
}
