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

    var body: some View {
        switch card {
        case .topThree(let card):
            TopThreeCardView(card: card, profile: profile, onOpenURL: onOpenURL)
        case .rideConfirm(let card):
            RideConfirmCardView(card: card, profile: profile)
        case .handoff(let card):
            HandoffCardView(card: card, profile: profile, reduceMotion: reduceMotion, onOpenURL: onOpenURL)
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
                ResultMapView(pins: mapPins, routeOrigin: nil, highContrast: profile.highContrast)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accent(highContrast: profile.highContrast))
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
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
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
                ResultMapView(pins: pins, routeOrigin: origin, highContrast: profile.highContrast)
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

            // One honest line, not a legal wall (PRD F4).
            Text("CEA doesn't place orders or book rides — you confirm in the app that opens.")
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
                    ? AnyShapeStyle(Theme.brandGradient(highContrast: profile.highContrast))
                    : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4)
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .accessibilityLabel("\(action.label). \(action.detail ?? "") Opens another app.")
            .accessibilityAddTraits(.isLink)
        }
    }
}
