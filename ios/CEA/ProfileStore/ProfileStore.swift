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
        // Dev/UI-walkthrough hook only (never set by real user flows):
        // launching with -CEACompleteOnboarding jumps straight to home so
        // simulator walkthroughs and future XCUITests can reach it.
        if ProcessInfo.processInfo.arguments.contains("-CEACompleteOnboarding") {
            profile.onboardingCompleted = true
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

    // MARK: Visit frequency (the honest "usual" signal)

    /// Counts a hand-off toward a venue/destination. Deterministic — called
    /// automatically when a ride/food hand-off card is built, so the user
    /// never has to state their regulars. Merges case-insensitively by name.
    func recordVisit(name: String, kind: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<VisitLog>()))?
            .first { $0.name.lowercased() == trimmed.lowercased() && $0.kind == kind }
        let finalCount: Int
        if let existing {
            existing.count += 1
            existing.lastUsedAt = .now
            finalCount = existing.count
        } else {
            context.insert(VisitLog(name: trimmed, kind: kind))
            finalCount = 1
        }
        try? context.save()
        // Privacy carve-out: food venues sync to the vendor (a restaurant name
        // is no more sensitive than a cuisine preference), but RIDE
        // DESTINATIONS stay on-device only — where someone physically travels
        // (clinics, hospitals, homes) is location/health-adjacent and must not
        // leave the device. Frequency for rides still works locally in-prompt.
        guard kind == "food" else { return }
        let slug = trimmed.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let backend = memoryBackend
        Task { await backend.sync(key: "usual_food_\(slug)", value: "requested \(finalCount) time(s): \(trimmed)") }
    }

    /// Top places/destinations for the system prompt, so CEA can offer "your
    /// usual" without being asked. Frequency of REQUESTS only — never the dish.
    var frequentPlacesPromptLines: String {
        let visits = (try? context.fetch(FetchDescriptor<VisitLog>()))?
            .filter { $0.count >= 1 }
            .sorted { $0.count > $1.count } ?? []
        guard !visits.isEmpty else { return "None yet." }
        return visits.prefix(5).map { visit in
            let label = visit.kind == "ride" ? "ride to" : "food from"
            let times = visit.count == 1 ? "once" : "\(visit.count) times"
            return "- \(label) \(visit.name) — requested \(times)"
        }.joined(separator: "\n")
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
