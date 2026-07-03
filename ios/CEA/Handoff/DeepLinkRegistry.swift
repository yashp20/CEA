import Foundation
import UIKit

/// THE ONLY place hand-off URLs are constructed (CLAUDE.md non-negotiable
/// architecture). Every entry declares platform, capability tier, URL
/// template, required params, installed-app check scheme, web fallback, and
/// the honest copy line for that tier. `LSApplicationQueriesSchemes` in
/// Info.plist must list every appScheme here.
enum HandoffPlatform: String, CaseIterable, Codable {
    case uber
    case lyft
    case doordash
}

enum HandoffTier: String, Codable {
    /// Deep link opens the app with the action pre-filled — one confirming tap.
    case prefilledAction = "prefilled_action"
    /// Link lands on the right page; a tap or two to finish.
    case rightPage = "right_page"
    /// Plain web fallback.
    case fallbackWeb = "fallback_web"

    /// Capability-based copy (never guarantees behavior of a named app).
    var copyLine: String {
        switch self {
        case .prefilledAction:
            return "Opens with your trip pre-filled — you confirm and request there."
        case .rightPage:
            return "Takes you straight to the right page — a tap or two to finish. Nothing is ordered for you."
        case .fallbackWeb:
            return "Opens in your browser — you take it from there."
        }
    }
}

struct RegistryEntry {
    let platform: HandoffPlatform
    let tier: HandoffTier
    let appScheme: String        // for canOpenURL checks
    let displayName: String
}

/// A fully built hand-off link pair: app deep link (when installed) plus a
/// web/universal fallback so there is never a dead end.
struct HandoffLink: Equatable {
    let platform: HandoffPlatform
    let tier: HandoffTier
    let appURL: URL?
    let webURL: URL
    /// Honest description of what opens and what's pre-filled.
    let detail: String

    /// The URL to actually open, preferring the installed app.
    func preferredURL(canOpen: (URL) -> Bool = { UIApplication.shared.canOpenURL($0) }) -> URL {
        if let appURL, canOpen(appURL) { return appURL }
        return webURL
    }
}

struct RidePoint: Equatable {
    let latitude: Double
    let longitude: Double
    let nickname: String?
    let formattedAddress: String?
}

enum DeepLinkRegistry {

    static let entries: [HandoffPlatform: RegistryEntry] = [
        .uber: RegistryEntry(platform: .uber, tier: .prefilledAction, appScheme: "uber", displayName: "Uber"),
        .lyft: RegistryEntry(platform: .lyft, tier: .prefilledAction, appScheme: "lyft", displayName: "Lyft"),
        .doordash: RegistryEntry(platform: .doordash, tier: .rightPage, appScheme: "doordash", displayName: "DoorDash"),
    ]

    // TODO(cea): wire Lyft developer Client ID (free, Lyft dev program) — used
    // as the `partner` parameter on Lyft universal links.
    static let lyftClientID = ""

    /// Whether the platform's app appears installed (requires
    /// LSApplicationQueriesSchemes to include the scheme).
    static func isAppInstalled(_ platform: HandoffPlatform) -> Bool {
        guard let entry = entries[platform],
              let probe = URL(string: "\(entry.appScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    // MARK: Rides (Vertical A)

    /// Uber: pickup/dropoff lat,lng + nicknames/formatted address params.
    /// Product prefill only works with a prefilled pickup; multiple deeplink
    /// actions can't be combined (CLAUDE.md integrations).
    static func uberRideLink(pickup: RidePoint, dropoff: RidePoint, productID: String? = nil) -> HandoffLink {
        var items: [URLQueryItem] = [URLQueryItem(name: "action", value: "setPickup")]
        items.append(contentsOf: queryItems(prefix: "pickup", point: pickup))
        items.append(contentsOf: queryItems(prefix: "dropoff", point: dropoff))
        if let productID {
            items.append(URLQueryItem(name: "product_id", value: productID))
        }

        var appComponents = URLComponents()
        appComponents.scheme = "uber"
        appComponents.host = ""
        appComponents.queryItems = items

        var webComponents = URLComponents(string: "https://m.uber.com/ul/")!
        webComponents.queryItems = items

        return HandoffLink(
            platform: .uber,
            tier: .prefilledAction,
            appURL: appComponents.url,
            webURL: webComponents.url!,
            detail: rideDetail(app: "Uber", pickup: pickup, dropoff: dropoff)
        )
    }

    /// Lyft: `lyft://ridetype?...` app link; `https://lyft.com/ride?...` web
    /// fallback with partner Client ID (falls back to ride.lyft.com if app absent).
    static func lyftRideLink(pickup: RidePoint, dropoff: RidePoint, rideTypeID: String = "lyft") -> HandoffLink {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "id", value: rideTypeID),
            URLQueryItem(name: "pickup[latitude]", value: coord(pickup.latitude)),
            URLQueryItem(name: "pickup[longitude]", value: coord(pickup.longitude)),
            URLQueryItem(name: "destination[latitude]", value: coord(dropoff.latitude)),
            URLQueryItem(name: "destination[longitude]", value: coord(dropoff.longitude)),
        ]
        if !lyftClientID.isEmpty {
            items.append(URLQueryItem(name: "partner", value: lyftClientID))
        }

        var appComponents = URLComponents()
        appComponents.scheme = "lyft"
        appComponents.host = "ridetype"
        appComponents.queryItems = items

        var webComponents = URLComponents(string: "https://lyft.com/ride")!
        webComponents.queryItems = items

        return HandoffLink(
            platform: .lyft,
            tier: .prefilledAction,
            appURL: appComponents.url,
            webURL: webComponents.url!,
            detail: rideDetail(app: "Lyft", pickup: pickup, dropoff: dropoff)
        )
    }

    // MARK: Food (Vertical B)

    /// Chicago demo set: DoorDash store slugs resolved by name match + web
    /// search at registry-demo-set build time (CLAUDE.md integrations).
    /// TODO(cea): extend/replace when the demo city or venue list changes.
    static let doordashDemoStores: [String: String] = [
        "lou malnatis pizzeria": "lou-malnatis-pizzeria-chicago-12431",   // 805 S State St
        "portillos": "portillo-s-chicago-50831",                          // 520 W Taylor St
        "india house": "india-house-chicago-11625",                       // 59 W Grand Ave
        "wildberry pancakes cafe": "wildberry-pancakes-&-cafe-chicago-445161", // 130 E Randolph St
        "star of siam": "star-of-siam-chicago-11627",                     // 11 E Illinois St
    ]

    /// Slug for a venue name from the demo set, or nil → search-page fallback.
    static func doordashSlug(matching name: String) -> String? {
        let normalized = normalize(name)
        guard normalized.count >= 4 else { return nil }
        for (key, slug) in doordashDemoStores {
            if normalized.contains(key) || key.contains(normalized) {
                return slug
            }
        }
        return nil
    }

    /// Lowercased, punctuation/diacritics removed (so "Portillo's" →
    /// "portillos"), whitespace collapsed.
    private static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        let kept = folded.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// DoorDash store page (right_page tier): opens the store page in the app
    /// via universal link. NO item/cart prefill — that requires signed
    /// merchant deeplinks we don't have. When no store slug/ID is resolvable,
    /// links to the DoorDash search page for the restaurant name instead.
    static func doordashStoreLink(storeSlugAndID: String?, restaurantName: String) -> HandoffLink {
        let webURL: URL
        let detail: String
        if let storeSlugAndID, !storeSlugAndID.isEmpty {
            webURL = URL(string: "https://www.doordash.com/store/")!
                .appending(path: storeSlugAndID)
            detail = "Opens the \(restaurantName) page on DoorDash. \(HandoffTier.rightPage.copyLine)"
        } else {
            var components = URLComponents(string: "https://www.doordash.com/search/store/")!
            components.path += restaurantName
            webURL = components.url!
            detail = "Opens a DoorDash search for \(restaurantName). \(HandoffTier.rightPage.copyLine)"
        }
        // Universal link — opens in the DoorDash app when installed; no
        // separate custom-scheme URL is documented for store pages.
        return HandoffLink(platform: .doordash, tier: .rightPage, appURL: nil, webURL: webURL, detail: detail)
    }

    // MARK: Fallbacks (never a dead end)

    static func appleMapsDirections(latitude: Double, longitude: Double, name: String) -> URL {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "daddr", value: "\(coord(latitude)),\(coord(longitude))"),
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "dirflg", value: "w"), // walking
        ]
        return components.url!
    }

    static func phoneCall(number: String) -> URL? {
        let digits = number.filter { "0123456789+".contains($0) }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    // MARK: Helpers

    private static func coord(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func queryItems(prefix: String, point: RidePoint) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "\(prefix)[latitude]", value: coord(point.latitude)),
            URLQueryItem(name: "\(prefix)[longitude]", value: coord(point.longitude)),
        ]
        if let nickname = point.nickname {
            items.append(URLQueryItem(name: "\(prefix)[nickname]", value: nickname))
        }
        if let address = point.formattedAddress {
            items.append(URLQueryItem(name: "\(prefix)[formatted_address]", value: address))
        }
        return items
    }

    private static func rideDetail(app: String, pickup: RidePoint, dropoff: RidePoint) -> String {
        let from = pickup.nickname ?? pickup.formattedAddress ?? "your location"
        let to = dropoff.nickname ?? dropoff.formattedAddress ?? "your destination"
        return "Opens \(app) with pickup (\(from)) and destination (\(to)) pre-filled. You review and request the ride there — CEA never books for you."
    }
}
