import Foundation
import SwiftData

/// One remembered preference (PRD F3): lightweight key-value the agent may
/// write via the save_preference tool, always with a visible confirmation.
/// Every item is viewable and deletable in Profile → Memory.
@Model
final class PreferenceMemory {
    var key: String
    var value: String
    var createdAt: Date

    init(key: String, value: String, createdAt: Date = .now) {
        self.key = key
        self.value = value
        self.createdAt = createdAt
    }
}

/// Frequency of the venues/destinations the user is handed off to, counted
/// automatically on each hand-off. This is the honest "usual" signal: the app
/// knows WHICH place/ride the user requested and how often — it never sees the
/// actual order/dish (hand-off happens before that), so nothing here implies it.
/// On-device only; non-sensitive; surfaced into the agent prompt so CEA can
/// offer "your usual" without being told.
@Model
final class VisitLog {
    var name: String          // venue or destination label
    var kind: String          // "food" | "ride"
    var count: Int
    var lastUsedAt: Date

    init(name: String, kind: String, count: Int = 1, lastUsedAt: Date = .now) {
        self.name = name
        self.kind = kind
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}
