import XCTest
@testable import CEA

/// Every platform × param combo (CLAUDE.md build/tooling: registry changes
/// require test coverage).
final class DeepLinkRegistryTests: XCTestCase {

    private let pickup = RidePoint(latitude: 41.878100, longitude: -87.629800, nickname: "Home", formattedAddress: "123 W Main St")
    private let dropoff = RidePoint(latitude: 41.878900, longitude: -87.640000, nickname: "Union Station", formattedAddress: nil)
    private let bare = RidePoint(latitude: 40.0, longitude: -75.0, nickname: nil, formattedAddress: nil)

    private func queryDict(_ url: URL?) -> [String: String] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: Uber

    func testUberLinkFullParams() {
        let link = DeepLinkRegistry.uberRideLink(pickup: pickup, dropoff: dropoff)
        XCTAssertEqual(link.platform, .uber)
        XCTAssertEqual(link.tier, .prefilledAction)

        let app = queryDict(link.appURL)
        XCTAssertEqual(link.appURL?.scheme, "uber")
        XCTAssertEqual(app["action"], "setPickup")
        XCTAssertEqual(app["pickup[latitude]"], "41.878100")
        XCTAssertEqual(app["pickup[longitude]"], "-87.629800")
        XCTAssertEqual(app["pickup[nickname]"], "Home")
        XCTAssertEqual(app["pickup[formatted_address]"], "123 W Main St")
        XCTAssertEqual(app["dropoff[latitude]"], "41.878900")
        XCTAssertEqual(app["dropoff[nickname]"], "Union Station")
        XCTAssertNil(app["dropoff[formatted_address]"])

        let web = queryDict(link.webURL)
        XCTAssertEqual(link.webURL.host, "m.uber.com")
        XCTAssertEqual(link.webURL.path(), "/ul/")
        XCTAssertEqual(web["action"], "setPickup")
        XCTAssertEqual(web["dropoff[longitude]"], "-87.640000")
    }

    func testUberLinkMinimalParamsOmitsOptionals() {
        let link = DeepLinkRegistry.uberRideLink(pickup: bare, dropoff: bare)
        let app = queryDict(link.appURL)
        XCTAssertNil(app["pickup[nickname]"])
        XCTAssertNil(app["pickup[formatted_address]"])
        XCTAssertNil(app["product_id"])
        XCTAssertEqual(app["pickup[latitude]"], "40.000000")
    }

    func testUberLinkWithProductID() {
        let link = DeepLinkRegistry.uberRideLink(pickup: pickup, dropoff: dropoff, productID: "wav-product")
        XCTAssertEqual(queryDict(link.appURL)["product_id"], "wav-product")
        XCTAssertEqual(queryDict(link.webURL)["product_id"], "wav-product")
    }

    func testUberNicknameWithSpacesIsPercentEncoded() {
        let point = RidePoint(latitude: 1, longitude: 2, nickname: "Coffee & Co", formattedAddress: nil)
        let link = DeepLinkRegistry.uberRideLink(pickup: point, dropoff: bare)
        XCTAssertFalse(link.webURL.absoluteString.contains("Coffee & Co"))
        XCTAssertEqual(queryDict(link.webURL)["pickup[nickname]"], "Coffee & Co")
    }

    // MARK: Lyft

    func testLyftLinkDefaultRideType() {
        let link = DeepLinkRegistry.lyftRideLink(pickup: pickup, dropoff: dropoff)
        XCTAssertEqual(link.platform, .lyft)
        XCTAssertEqual(link.tier, .prefilledAction)

        let app = queryDict(link.appURL)
        XCTAssertEqual(link.appURL?.scheme, "lyft")
        XCTAssertEqual(link.appURL?.host, "ridetype")
        XCTAssertEqual(app["id"], "lyft")
        XCTAssertEqual(app["pickup[latitude]"], "41.878100")
        XCTAssertEqual(app["destination[latitude]"], "41.878900")
        XCTAssertEqual(app["destination[longitude]"], "-87.640000")

        XCTAssertEqual(link.webURL.host, "lyft.com")
        XCTAssertEqual(link.webURL.path, "/ride")
    }

    func testLyftLinkCustomRideType() {
        let link = DeepLinkRegistry.lyftRideLink(pickup: pickup, dropoff: dropoff, rideTypeID: "lyft_plus")
        XCTAssertEqual(queryDict(link.appURL)["id"], "lyft_plus")
    }

    func testLyftPartnerParamOnlyWhenClientIDConfigured() {
        // Client ID is a TODO(cea) injection point; empty by default.
        let link = DeepLinkRegistry.lyftRideLink(pickup: pickup, dropoff: dropoff)
        if DeepLinkRegistry.lyftClientID.isEmpty {
            XCTAssertNil(queryDict(link.webURL)["partner"])
        } else {
            XCTAssertEqual(queryDict(link.webURL)["partner"], DeepLinkRegistry.lyftClientID)
        }
    }

    // MARK: DoorDash

    func testDoorDashStoreLinkWithSlug() {
        let link = DeepLinkRegistry.doordashStoreLink(storeSlugAndID: "tasty-thai-12345", restaurantName: "Tasty Thai")
        XCTAssertEqual(link.platform, .doordash)
        XCTAssertEqual(link.tier, .rightPage)
        XCTAssertEqual(link.webURL.absoluteString, "https://www.doordash.com/store/tasty-thai-12345")
        XCTAssertNil(link.appURL) // universal link only
        XCTAssertTrue(link.detail.contains("Nothing is ordered for you"))
    }

    func testDoorDashSearchFallbackWithoutSlug() {
        let link = DeepLinkRegistry.doordashStoreLink(storeSlugAndID: nil, restaurantName: "Tasty Thai")
        XCTAssertTrue(link.webURL.absoluteString.hasPrefix("https://www.doordash.com/search/store/"))
        XCTAssertTrue(link.webURL.path.contains("Tasty Thai") || link.webURL.absoluteString.contains("Tasty%20Thai"))
        XCTAssertTrue(link.detail.contains("search"))
    }

    // MARK: Fallbacks

    func testAppleMapsDirectionsIsWalking() {
        let url = DeepLinkRegistry.appleMapsDirections(latitude: 41.8781, longitude: -87.6298, name: "Cafe One")
        let query = queryDict(url)
        XCTAssertEqual(url.host, "maps.apple.com")
        XCTAssertEqual(query["dirflg"], "w")
        XCTAssertEqual(query["q"], "Cafe One")
        XCTAssertEqual(query["daddr"], "41.878100,-87.629800")
    }

    func testPhoneCallStripsFormatting() {
        XCTAssertEqual(DeepLinkRegistry.phoneCall(number: "(312) 555-0142")?.absoluteString, "tel:3125550142")
        XCTAssertEqual(DeepLinkRegistry.phoneCall(number: "+1 312 555 0142")?.absoluteString, "tel:+13125550142")
        XCTAssertNil(DeepLinkRegistry.phoneCall(number: "no digits"))
    }

    // MARK: Preferred URL logic

    func testPreferredURLUsesAppWhenInstalled() {
        let link = DeepLinkRegistry.uberRideLink(pickup: pickup, dropoff: dropoff)
        XCTAssertEqual(link.preferredURL(canOpen: { _ in true }), link.appURL)
        XCTAssertEqual(link.preferredURL(canOpen: { _ in false }), link.webURL)
    }

    // MARK: Copy rules

    func testTierCopyIsCapabilityBased() {
        // Never guaranteed behavior of a named third-party app (CLAUDE.md #6).
        XCTAssertFalse(HandoffTier.prefilledAction.copyLine.isEmpty)
        XCTAssertTrue(HandoffTier.rightPage.copyLine.contains("Nothing is ordered for you"))
        for platform in HandoffPlatform.allCases {
            XCTAssertNotNil(DeepLinkRegistry.entries[platform], "missing registry entry for \(platform)")
        }
    }
}
