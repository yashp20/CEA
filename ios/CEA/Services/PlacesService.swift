import CoreLocation
import Foundation
import MapKit

/// A venue candidate from a real data source. `wheelchairAccessible == nil`
/// means unknown — the UI and agent must say "accessibility info unavailable",
/// never guess (CLAUDE.md non-negotiable #3).
struct PlaceResult: Codable {
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var rating: Double?
    var userRatingCount: Int?
    var openNow: Bool?
    var wheelchairAccessible: Bool?
    var phone: String?
    var website: String?
    var priceLevel: String?
    var distanceMeters: Double?
}

protocol PlacesSearching {
    func search(query: String, near coordinate: CLLocationCoordinate2D) async throws -> [PlaceResult]
    /// Which real source produced results — surfaced to the agent so it can be
    /// honest about what data (e.g. accessibility attributes) is available.
    var sourceDescription: String { get }
}

/// Google Places API (New) Text Search — primary source; includes
/// `accessibilityOptions.wheelchairAccessibleEntrance` when present.
struct GooglePlacesService: PlacesSearching {
    let apiKey: String
    var sourceDescription: String { "Google Places (includes wheelchair-accessible-entrance data where venues report it)" }

    enum PlacesError: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Places search failed (HTTP \(code))."
            }
        }
    }

    func search(query: String, near coordinate: CLLocationCoordinate2D) async throws -> [PlaceResult] {
        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchText")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.displayName,places.formattedAddress,places.location,places.rating,places.userRatingCount,places.currentOpeningHours.openNow,places.accessibilityOptions,places.nationalPhoneNumber,places.websiteUri,places.priceLevel",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        let body: [String: Any] = [
            "textQuery": query,
            "locationBias": [
                "circle": [
                    "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                    "radius": 5000.0,
                ],
            ],
            "maxResultCount": 10,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PlacesError.badResponse(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(TextSearchResponse.self, from: data)
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return (decoded.places ?? []).map { place in
            PlaceResult(
                name: place.displayName?.text ?? "Unnamed place",
                address: place.formattedAddress,
                latitude: place.location?.latitude ?? 0,
                longitude: place.location?.longitude ?? 0,
                rating: place.rating,
                userRatingCount: place.userRatingCount,
                openNow: place.currentOpeningHours?.openNow,
                wheelchairAccessible: place.accessibilityOptions?.wheelchairAccessibleEntrance,
                phone: place.nationalPhoneNumber,
                website: place.websiteUri,
                priceLevel: place.priceLevel,
                distanceMeters: place.location.map {
                    origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                }
            )
        }
    }

    // MARK: Wire types

    private struct TextSearchResponse: Decodable { let places: [GPlace]? }
    private struct GPlace: Decodable {
        let displayName: LocalizedText?
        let formattedAddress: String?
        let location: LatLng?
        let rating: Double?
        let userRatingCount: Int?
        let currentOpeningHours: OpeningHours?
        let accessibilityOptions: AccessibilityOptions?
        let nationalPhoneNumber: String?
        let websiteUri: String?
        let priceLevel: String?
    }
    private struct LocalizedText: Decodable { let text: String? }
    private struct LatLng: Decodable { let latitude: Double; let longitude: Double }
    private struct OpeningHours: Decodable { let openNow: Bool? }
    private struct AccessibilityOptions: Decodable { let wheelchairAccessibleEntrance: Bool? }
}

/// First-party fallback when no Places key is configured: MKLocalSearch.
/// Provides real names/locations/phone/URL but NO accessibility attributes —
/// results are surfaced with wheelchairAccessible == nil (info unavailable).
struct AppleLocalSearchService: PlacesSearching {
    var sourceDescription: String { "Apple Maps search (no venue accessibility attributes — say accessibility info is unavailable)" }

    func search(query: String, near coordinate: CLLocationCoordinate2D) async throws -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 8000,
            longitudinalMeters: 8000
        )
        let response = try await MKLocalSearch(request: request).start()
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return response.mapItems.prefix(10).map { item in
            let coord = item.placemark.coordinate
            return PlaceResult(
                name: item.name ?? "Unnamed place",
                address: item.placemark.title,
                latitude: coord.latitude,
                longitude: coord.longitude,
                rating: nil,
                userRatingCount: nil,
                openNow: nil,
                wheelchairAccessible: nil, // MKLocalSearch has no such data — never invent it
                phone: item.phoneNumber,
                website: item.url?.absoluteString,
                priceLevel: nil,
                distanceMeters: origin.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            )
        }
    }
}

enum PlacesServiceFactory {
    /// Google Places when a key is configured, honest Apple fallback otherwise.
    static func make() -> PlacesSearching {
        // TODO(cea): wire Google Places API key — set CEA_PLACES_API_KEY in
        // ios/Secrets.xcconfig (not committed); it lands in Info.plist as
        // CEAPlacesAPIKey, restricted by bundle ID in Google Cloud console.
        let key = Bundle.main.object(forInfoDictionaryKey: "CEAPlacesAPIKey") as? String ?? ""
        if key.isEmpty || key.hasPrefix("$(") {
            return AppleLocalSearchService()
        }
        return GooglePlacesService(apiKey: key)
    }
}
