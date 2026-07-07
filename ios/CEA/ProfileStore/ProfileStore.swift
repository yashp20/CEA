import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Loads (or creates) the single AccessibilityProfile and exposes it to the
/// view tree. Also performs launch-time read-only UIAccessibility seeding
/// (PRD F1: users confirm rather than declare) and keeps observing system
/// notifications so system settings win when stricter.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profile: AccessibilityProfile
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        let descriptor = FetchDescriptor<AccessibilityProfile>()
        if let existing = try? context.fetch(descriptor).first {
            self.profile = existing
        } else {
            let fresh = AccessibilityProfile()
            context.insert(fresh)
            self.profile = fresh
            seedFromSystemSettings(into: fresh)
            try? context.save()
        }
    }

    /// Read-only seeding from UIAccessibility. Never writes system settings.
    private func seedFromSystemSettings(into profile: AccessibilityProfile) {
        if UIAccessibility.isVoiceOverRunning {
            profile.blindness = true
            profile.voiceFirst = true
        }
        if UIAccessibility.isReduceMotionEnabled {
            profile.reduceMotion = true
        }
        if UIAccessibility.isDarkerSystemColorsEnabled {
            profile.highContrast = true
        }
        if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            profile.largerText = true
        }
        if UIAccessibility.isClosedCaptioningEnabled {
            profile.captions = true
            profile.hearingImpaired = true
        }
    }

    func save() {
        try? context.save()
    }

    // MARK: Memory ledger

    func memories() -> [PreferenceMemory] {
        let descriptor = FetchDescriptor<PreferenceMemory>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Writes a preference and returns the confirmation line to show in chat.
    @discardableResult
    func savePreference(key: String, value: String) -> String {
        // Replace an existing entry with the same key rather than duplicating.
        if let existing = memories().first(where: { $0.key == key }) {
            existing.value = value
            existing.createdAt = .now
        } else {
            context.insert(PreferenceMemory(key: key, value: value))
        }
        try? context.save()
        return "Saved: \(key) — \(value)."
    }

    func deleteMemory(_ memory: PreferenceMemory) {
        context.delete(memory)
        try? context.save()
    }

    func deleteAllMemory() {
        for m in memories() { context.delete(m) }
        try? context.save()
    }

    /// Compact memory lines for the system prompt (keys + values only).
    var memoryPromptLines: String {
        let items = memories()
        guard !items.isEmpty else { return "No saved preferences." }
        return items.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    // MARK: Routines (v1.1 §3.2)

    func allRoutines() -> [Routine] {
        let descriptor = FetchDescriptor<Routine>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Derived UI values

    /// Extra type scaling on top of Dynamic Type for the Larger Text toggle.
    var typeScale: CGFloat { profile.largerText ? 1.25 : 1.0 }
}
