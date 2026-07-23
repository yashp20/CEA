import CoreLocation
import SwiftUI

/// Renders a CardPayload. The renderer is the mechanical enforcement point
/// for "max 3 options" (already applied on decode) and for accessibility:
/// one VoiceOver element per option, labels not color for meaning.
struct CardView: View {
    let card: CardPayload
    let profile: AccessibilityProfile
    var reduceMotion: Bool
    var onOpenURL: (URL) -> Void
    /// The persisted message backing this card (used by cards that update
    /// their own state, e.g. own-account confirmation completion).
    var message: ChatMessage?

    var body: some View {
        switch card {
        case .topThree(let card):
            TopThreeCardView(card: card, profile: profile, onOpenURL: onOpenURL)
        case .rideConfirm(let card):
            RideConfirmCardView(card: card, profile: profile)
        case .handoff(let card):
            HandoffCardView(card: card, profile: profile, reduceMotion: reduceMotion, onOpenURL: onOpenURL)
        case .ownAccountConfirm(let card):
            OwnAccountConfirmCardView(card: card, message: message, profile: profile, reduceMotion: reduceMotion)
        }
    }
}

// MARK: Own-account confirmation (v1.1 §4)

/// Confirm-before-side-effect: shows exactly what will happen; the Zapier
/// call fires only on Confirm. Completion persists onto the message so a
/// confirmed action can never re-run.
struct OwnAccountConfirmCardView: View {
    let card: OwnAccountConfirmCard
    let message: ChatMessage?
    let profile: AccessibilityProfile
    var reduceMotion: Bool

    @Environment(\.modelContext) private var context
    @State private var running = false
    @State private var resultLine: String?
    @State private var errorLine: String?
    @State private var cancelled = false
    @State private var flash = false

    private var completed: Bool { card.completed == true || resultLine != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Label("Check before I do it", systemImage: "hand.raised")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(card.summary)
                .font(.body.weight(.medium))

            Text("Runs through your own connected account (Zapier). Nothing happens until you confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if completed {
                Label(resultLine ?? "Done — confirmed earlier.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.positive(for: profile.colorBlindType, highContrast: profile.highContrast))
            } else if cancelled {
                Label("Cancelled. Nothing was sent or created.", systemImage: "xmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let errorLine {
                Label(errorLine, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.caution(for: profile.colorBlindType, highContrast: profile.highContrast))
            }

            if !completed && !cancelled {
                HStack(spacing: Theme.spacing) {
                    Button {
                        cancelled = true
                        Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .frame(minHeight: Theme.minTapTarget)
                    }
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
                    .foregroundStyle(.primary)
                    .accessibilityHint("Nothing will be sent or created.")

                    Button(action: confirm) {
                        HStack {
                            if running { ProgressView().tint(.white) }
                            Text(running ? "Working…" : "Confirm")
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .frame(minHeight: Theme.minTapTarget)
                    }
                    .disabled(running)
                    .background(Theme.brandGradient(for: profile.colorBlindType, highContrast: profile.highContrast), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
                    .foregroundStyle(.white)
                    .accessibilityHint("Runs the action through your Zapier account.")
                }
            }
        }
        .ceaCard(highContrast: profile.highContrast)
        .visualFlash(trigger: $flash, reduceMotion: reduceMotion)
        .accessibilityElement(children: .contain)
    }

    private func confirm() {
        running = true
        errorLine = nil
        Task { @MainActor in
            defer { running = false }
            do {
                let result = try await ZapierMCPService.shared.callTool(
                    name: card.toolName ?? "",
                    argumentsJSON: card.argumentsJSON
                )
                resultLine = "Done. \(result)"
                Haptics.shared.play(.confirmed, enabled: profile.hapticsEnabled)
                flash = true
                persistCompletion()
            } catch {
                errorLine = error.localizedDescription
                Haptics.shared.play(.headsUp, enabled: profile.hapticsEnabled)
            }
        }
    }

    /// Marks the persisted card completed so relaunches can't re-run it.
    private func persistCompletion() {
        guard let message else { return }
        var updated = card
        updated.completed = true
        if let data = try? JSONEncoder().encode(CardPayload.ownAccountConfirm(updated)) {
            message.cardJSON = String(data: data, encoding: .utf8)
            try? context.save()
        }
    }
}

// MARK: Top three (Vertical B)

struct TopThreeCardView: View {
    let card: TopThreeCard
    let profile: AccessibilityProfile
    var onOpenURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            if let title = card.title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(card.options.prefix(3).enumerated()), id: \.element.id) { index, option in
                PlaceOptionRow(index: index + 1, option: option, profile: profile)
            }
            if !mapPins.isEmpty {
                ResultMapView(pins: mapPins, routeOrigin: nil, highContrast: profile.highContrast, colorBlindType: profile.colorBlindType)
            }
        }
        .ceaCard(highContrast: profile.highContrast)
    }

    private var mapPins: [ResultMapView.Pin] {
        card.options.prefix(3).compactMap { option in
            guard let lat = option.latitude, let lng = option.longitude else { return nil }
            return ResultMapView.Pin(name: option.name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
    }
}

private struct PlaceOptionRow: View {
    let index: Int
    let option: PlaceOption
    let profile: AccessibilityProfile

    /// §3.1: community aggregate for this venue (nil until loaded; absence
    /// renders as "no reports yet", never a guess).
    @State private var aggregate: CrowdAggregate?
    @State private var aggregateLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accent(for: profile.colorBlindType, highContrast: profile.highContrast))
                Text(option.name)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            if let summary = option.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let rating = option.rating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                }
                if let distance = option.distanceText {
                    Label(distance, systemImage: "figure.walk")
                }
                if let open = option.openNow {
                    Label(open ? "Open now" : "Closed", systemImage: open ? "clock" : "clock.badge.xmark")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Accessibility state: explicit label + icon, never color-only,
            // and honest "info unavailable" when the data doesn't say.
            accessibilityBadge
                .font(.caption.weight(.medium))

            // §3.1: community provenance + proactive barrier flag, from real
            // reports only.
            if let warning = CrowdsourceService.barrierWarning(aggregate: aggregate, profile: profile) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.caution(for: profile.colorBlindType, highContrast: profile.highContrast))
            }
            if aggregateLoaded {
                Text(provenanceLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
        .task {
            guard !aggregateLoaded, let lat = option.latitude, let lng = option.longitude else { return }
            let key = CrowdsourceService.venueKey(name: option.name, latitude: lat, longitude: lng)
            aggregate = await CrowdsourceService.aggregate(venueKey: key)
            aggregateLoaded = true
            if CrowdsourceService.barrierWarning(aggregate: aggregate, profile: profile) != nil {
                // The visible flag above is the visual twin of this heads-up.
                Haptics.shared.play(.headsUp, enabled: profile.hapticsEnabled)
            }
        }
    }

    private var provenanceLine: String {
        let attribute = CrowdsourceService.priorityAttributes(for: profile).first ?? .stepFreeEntry
        return CrowdsourceService.provenanceLine(aggregate: aggregate, for: attribute)
    }

    @ViewBuilder
    private var accessibilityBadge: some View {
        switch option.wheelchairAccessible {
        case .some(true):
            Label("Wheelchair-accessible entrance", systemImage: "figure.roll")
                .foregroundStyle(Theme.positive(for: profile.colorBlindType, highContrast: profile.highContrast))
        case .some(false):
            Label("No accessible entrance reported", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.caution(for: profile.colorBlindType, highContrast: profile.highContrast))
        case .none:
            Label("Accessibility info unavailable", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var voiceOverLabel: String {
        var parts: [String] = ["Option \(index): \(option.name)"]
        if let summary = option.summary { parts.append(summary) }
        if let rating = option.rating { parts.append("Rated \(String(format: "%.1f", rating))") }
        if let distance = option.distanceText { parts.append(distance) }
        if let open = option.openNow { parts.append(open ? "Open now" : "Closed") }
        switch option.wheelchairAccessible {
        case .some(true): parts.append("Wheelchair-accessible entrance")
        case .some(false): parts.append("No accessible entrance reported")
        case .none: parts.append("Accessibility info unavailable")
        }
        if let warning = CrowdsourceService.barrierWarning(aggregate: aggregate, profile: profile) {
            parts.append(warning)
        }
        if aggregateLoaded {
            parts.append(provenanceLine)
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: Ride confirm (Vertical A)

struct RideConfirmCardView: View {
    let card: RideConfirmCard
    let profile: AccessibilityProfile

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Label("Ride check", systemImage: "car.fill")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(card.summary)
                .font(.body)
            if let note = card.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !pins.isEmpty {
                ResultMapView(pins: pins, routeOrigin: origin, highContrast: profile.highContrast, colorBlindType: profile.colorBlindType)
            }
        }
        .ceaCard(highContrast: profile.highContrast)
        .accessibilityElement(children: .combine)
    }

    private var origin: CLLocationCoordinate2D? {
        guard let lat = card.pickupLatitude, let lng = card.pickupLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private var pins: [ResultMapView.Pin] {
        var result: [ResultMapView.Pin] = []
        if let lat = card.destinationLatitude, let lng = card.destinationLongitude {
            result.append(.init(name: card.destinationName ?? "Destination",
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)))
        }
        return result
    }
}

// MARK: Hand-off (F4)

struct HandoffCardView: View {
    let card: HandoffCard
    let profile: AccessibilityProfile
    var reduceMotion: Bool
    var onOpenURL: (URL) -> Void

    @State private var flash = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text(card.title ?? "Ready to hand off")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if card.actions.compactMap(\.url).isEmpty {
                // Honest failure state: never an empty shell of a card.
                Label("I couldn't build the links for this hand-off. Ask me to try again.",
                      systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(card.actions.prefix(3)) { action in
                handoffButton(action, prominent: true)
            }

            if let fallbacks = card.fallbacks, !fallbacks.isEmpty {
                Divider()
                Text("Other ways to get there")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(fallbacks.prefix(3)) { action in
                    handoffButton(action, prominent: false)
                }
            }

            // One honest line, not a legal wall (PRD F4) — capability-general,
            // not just orders/rides.
            Text("CEA never completes the action for you — you confirm in the app that opens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .ceaCard(highContrast: profile.highContrast)
        .visualFlash(trigger: $flash, reduceMotion: reduceMotion)
    }

    @ViewBuilder
    private func handoffButton(_ action: HandoffAction, prominent: Bool) -> some View {
        if let url = action.url {
            Button {
                Haptics.shared.play(.confirmed, enabled: profile.hapticsEnabled)
                if profile.hapticsEnabled {
                    withAnimation(Motion.snappy(reduceMotion: reduceMotion)) { flash = true }
                }
                onOpenURL(url)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(action.label)
                            .font(prominent ? .body.weight(.semibold) : .subheadline)
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .accessibilityHidden(true)
                    }
                    if let detail = action.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(prominent ? Color.white.opacity(0.85) : Color.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .frame(minHeight: Theme.minTapTarget)
            }
            .buttonStyle(.plain)
            .background(
                prominent
                    ? AnyShapeStyle(Theme.brandGradient(for: profile.colorBlindType, highContrast: profile.highContrast))
                    : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4)
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .accessibilityLabel("\(action.label). \(action.detail ?? "") Opens another app.")
            .accessibilityAddTraits(.isLink)
        }
    }
}
