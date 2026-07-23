import Foundation
import SwiftData
import SwiftUI

/// Per-shortcut usage counter (v1.1 §2): shortcuts personalize by real usage
/// where data exists, defaults otherwise. On-device only.
@Model
final class ShortcutUsage {
    var key: String
    var count: Int
    var lastUsedAt: Date

    init(key: String, count: Int = 0, lastUsedAt: Date = .now) {
        self.key = key
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

/// A home-screen shortcut. Every shortcut seeds a CEA request into the
/// composer — the conversation is the product; shortcuts are just faster ways
/// into it. (Revised: the v1.1 first cut also had open-the-app links here,
/// which read as app hyperlinks rather than easier chats — removed.)
struct CEAShortcut: Identifiable {
    let id: String       // usage-tracking key
    let title: String
    let icon: String
    /// The request placed into the composer; the user finishes and sends.
    let seedText: String
    let accessibilityHint: String

    /// The core default set (shown until usage data reorders it).
    static let defaults: [CEAShortcut] = [
        CEAShortcut(
            id: "seed-ride", title: "Ride", icon: "car.fill",
            seedText: "Get me a ride to ",
            accessibilityHint: "Starts a ride request in the message box. You finish it and send."
        ),
        CEAShortcut(
            id: "seed-ride-home", title: "Ride home", icon: "house.fill",
            seedText: "Get me a ride home",
            accessibilityHint: "Puts a ride-home request in the message box, ready to send."
        ),
        CEAShortcut(
            id: "seed-food", title: "Food", icon: "fork.knife",
            seedText: "Food nearby",
            accessibilityHint: "Puts a nearby-food request in the message box, ready to send."
        ),
        CEAShortcut(
            id: "seed-coffee", title: "Coffee", icon: "cup.and.saucer.fill",
            seedText: "Coffee nearby",
            accessibilityHint: "Puts a nearby-coffee request in the message box, ready to send."
        ),
        CEAShortcut(
            id: "seed-directions", title: "Directions", icon: "figure.walk",
            seedText: "Walking directions to ",
            accessibilityHint: "Starts a directions request in the message box."
        ),
        CEAShortcut(
            id: "seed-reminder", title: "Reminder", icon: "bell",
            seedText: "Remind me to ",
            accessibilityHint: "Starts a reminder request. You confirm before anything is created."
        ),
    ]
}

/// Usage bookkeeping shared by the shortcut strip and hand-off tracking.
@MainActor
enum ShortcutUsageTracker {
    static func record(key: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<ShortcutUsage>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.count += 1
            existing.lastUsedAt = .now
        } else {
            context.insert(ShortcutUsage(key: key, count: 1))
        }
        try? context.save()
    }

    /// Which shortcut a hand-off open counts toward (rides → the ride seeds,
    /// food → the food seed, maps → directions). Pure and testable.
    nonisolated static func shortcutKey(for url: URL) -> String? {
        switch url.scheme {
        case "uber", "lyft": return "seed-ride"
        case "doordash": return "seed-food"
        case "tel": return nil
        default:
            let host = url.host() ?? ""
            if host.contains("uber.com") || host.contains("lyft.com") { return "seed-ride" }
            if host.contains("doordash.com") { return "seed-food" }
            if host.contains("maps.apple.com") { return "seed-directions" }
            return nil
        }
    }

    /// Hand-off opens count toward shortcut personalization.
    static func recordHandoff(url: URL, in context: ModelContext) {
        if let key = shortcutKey(for: url) {
            record(key: key, in: context)
        }
    }
}

/// The floating shortcut widgets on home (v1.1 §2). Personalized by usage;
/// every widget has a label + hint; the float animation routes through the
/// Reduce-Motion helper and is fully static when motion is reduced.
struct ShortcutStrip: View {
    var profile: AccessibilityProfile
    var reduceMotion: Bool
    /// Seeds the composer with a request (the user finishes and sends).
    var onSeed: (String) -> Void

    @Environment(\.modelContext) private var context
    @Query private var usage: [ShortcutUsage]
    @State private var bob = false

    private var ranked: [CEAShortcut] {
        let counts = Dictionary(uniqueKeysWithValues: usage.map { ($0.key, $0.count) })
        return CEAShortcut.defaults
            .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: Theme.spacing)], spacing: Theme.spacing) {
            ForEach(Array(ranked.prefix(6).enumerated()), id: \.element.id) { index, shortcut in
                button(for: shortcut)
                    // Gentle float, phase-shifted per widget; static under
                    // Reduce Motion (Motion helper contract).
                    .offset(y: !reduceMotion && bob ? (index.isMultiple(of: 2) ? -3 : 3) : 0)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcuts that start a request for you")
    }

    private func button(for shortcut: CEAShortcut) -> some View {
        Button {
            Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
            ShortcutUsageTracker.record(key: shortcut.id, in: context)
            onSeed(shortcut.seedText)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: shortcut.icon)
                    .font(.title3)
                    .foregroundStyle(Theme.brandGradient(for: profile.colorBlindType, highContrast: profile.highContrast))
                Text(shortcut.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(Theme.minTapTarget, 64))
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4)
                    .strokeBorder(profile.highContrast ? Color.primary.opacity(0.5) : Color(.systemGray5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shortcut.title)
        .accessibilityHint(shortcut.accessibilityHint)
    }
}
