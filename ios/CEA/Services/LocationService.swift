import CoreLocation
import Foundation

/// When-in-use location, exposed as coarse coordinates only (rounded to
/// ~100 m) — raw location never leaves the device except as these coarse
/// values inside tool results (CLAUDE.md data & privacy).
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<CLLocation, Error>] = []

    enum LocationError: LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied: return "Location permission is off. You can enable it in Settings, or tell me your pickup address instead."
            case .unavailable: return "Your location isn't available right now. You can tell me an address instead."
            }
        }
    }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// One-shot current location.
    func currentLocation() async throws -> CLLocation {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            manager.requestLocation()
        }
    }

    /// Coarse coordinate for prompts/tool results: 3 decimals ≈ 110 m.
    static func coarse(_ value: CLLocationDegrees) -> Double {
        (value * 1000).rounded() / 1000
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: LocationError.unavailable) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            if !continuations.isEmpty { manager.requestLocation() }
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume(throwing: LocationError.denied) }
        }
    }
}
