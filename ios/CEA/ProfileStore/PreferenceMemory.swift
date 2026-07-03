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
