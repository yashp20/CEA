import MapKit
import SwiftUI

/// Embedded result map for cards: markers plus an optional MKDirections
/// walking preview. Honesty constraint (PRD §5): MapKit has no wheelchair
/// routing data, so this is labeled a walking preview and never claims an
/// accessibility-verified route. Venue accessibility labels come from Places
/// data only, rendered by the cards — not by the map.
struct ResultMapView: View {
    struct Pin: Identifiable {
        let id = UUID()
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    let pins: [Pin]
    /// When set, a walking route preview is drawn from `routeOrigin` to the
    /// first pin.
    var routeOrigin: CLLocationCoordinate2D?
    var highContrast: Bool
    var colorBlindType: ColorBlindType? = nil

    @State private var route: MKRoute?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(region)) {
                ForEach(pins) { pin in
                    Marker(pin.name, coordinate: pin.coordinate)
                        .tint(Theme.accent(for: colorBlindType, highContrast: highContrast))
                }
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(
                            Theme.accent(for: colorBlindType, highContrast: highContrast),
                            style: StrokeStyle(lineWidth: highContrast ? 6 : 4, lineCap: .round)
                        )
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
            .accessibilityElement()
            .accessibilityLabel(accessibilityDescription)

            if route != nil {
                // Label, not color, carries the meaning (PRD §9).
                Label("Walking preview only — not an accessibility-verified route.", systemImage: "figure.walk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: pins.first?.coordinate.latitude) {
            await loadRouteIfNeeded()
        }
    }

    private var region: MKCoordinateRegion {
        var coordinates = pins.map(\.coordinate)
        if let routeOrigin { coordinates.append(routeOrigin) }
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                      span: .init(latitudeDelta: 1, longitudeDelta: 1))
        }
        let lats = coordinates.map(\.latitude)
        let lngs = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lngs.min()! + lngs.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.012),
            longitudeDelta: max((lngs.max()! - lngs.min()!) * 1.6, 0.012)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private var accessibilityDescription: String {
        let names = pins.map(\.name).joined(separator: ", ")
        return route != nil
            ? "Map showing \(names) with a walking route preview. Route accessibility is not verified."
            : "Map showing \(names)."
    }

    private func loadRouteIfNeeded() async {
        guard let routeOrigin, let destination = pins.first?.coordinate, route == nil else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeOrigin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .walking
        route = try? await MKDirections(request: request).calculate().routes.first
    }
}
