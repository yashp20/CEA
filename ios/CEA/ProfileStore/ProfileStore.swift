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
    /// v1.1 §5: vendor persistence for non-sensitive preference memory only.
    /// The AccessibilityProfile itself never goes through this (see
    /// MemoryBackend.swift for the enforced privacy split).
    @ObservationIgnored private let memoryBackend: MemoryBackending

    init(context: ModelContext, memoryBackend: MemoryBackending = ProxyMemoryBackend()) {
        self.context = context
        self.memoryBackend = memoryBackend
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
    /// Local ledger first (source of truth), then best-effort vendor sync for
    /// non-sensitive keys only (§5 privacy split).
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
        let backend = memoryBackend
        Task { await backend.sync(key: key, value: value) }
        return "Saved: \(key) — \(value)."
    }

    func deleteMemory(_ memory: PreferenceMemory) {
        let key = memory.key
        context.delete(memory)
        try? context.save()
        let backend = memoryBackend
        Task { await backend.delete(key: key) }
    }

    /// Clears BOTH the local ledger and the vendor-side copy (§5).
    func deleteAllMemory() {
        for m in memories() { context.delete(m) }
        try? context.save()
        let backend = memoryBackend
        Task { await backend.deleteAll() }
    }

    /// Compact memory lines for the system prompt (keys + values only).
    var memoryPromptLines: String {
        let items = memories()
        guard !items.isEmpty else { return "No saved preferences." }
        return items.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    // MARK: Crowdsource surveys (v1.1 §3.1)

    /// Queues a post-visit survey after a venue hand-off. Deduped per venue;
    /// no-op when the user turned survey prompts off. It is surfaced later
    /// at a non-interrupting moment — never here, never mid-task.
    func queueSurvey(venueKey: String, venueName: String, latitude: Double, longitude: Double) {
        guard profile.surveyPromptsEnabled else { return }
        let descriptor = FetchDescriptor<QueuedSurvey>(predicate: #Predicate { $0.venueKey == venueKey })
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            // Refresh the visit time on the pending one instead of duplicating.
            if let pending = existing.first(where: { !$0.dismissed && $0.completedAt == nil }) {
                pending.handoffAt = .now
                try? context.save()
            }
            return
        }
        context.insert(QueuedSurvey(venueKey: venueKey, venueName: venueName, latitude: latitude, longitude: longitude))
        try? context.save()
    }

    func pendingSurveys() -> [QueuedSurvey] {
        let descriptor = FetchDescriptor<QueuedSurvey>(sortBy: [SortDescriptor(\.handoffAt)])
        return (try? context.fetch(descriptor)) ?? []
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
