import Foundation

/// Structured card payloads returned by the agent's `render_card` tool so the
/// UI never regex-parses prose (CLAUDE.md agent loop §3). Decoding is lenient
/// (optionals everywhere); the renderer enforces the style contract
/// mechanically — option lists are truncated to 3 regardless of model output.
enum CardPayload: Codable, Equatable {
    case topThree(TopThreeCard)
    case rideConfirm(RideConfirmCard)
    case handoff(HandoffCard)
    case ownAccountConfirm(OwnAccountConfirmCard)

    private enum CodingKeys: String, CodingKey { case type }

    enum Kind: String, Codable {
        case topThree = "top_three"
        case rideConfirm = "ride_confirm"
        case handoff = "handoff"
        case ownAccountConfirm = "own_account_confirm"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .topThree:
            var card = try TopThreeCard(from: decoder)
            // Hard cap: max 3 options, ever (PRD F2).
            card.options = Array(card.options.prefix(3))
            self = .topThree(card)
        case .rideConfirm:
            self = .rideConfirm(try RideConfirmCard(from: decoder))
        case .handoff:
            self = .handoff(try HandoffCard(from: decoder))
        case .ownAccountConfirm:
            self = .ownAccountConfirm(try OwnAccountConfirmCard(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topThree(let card):
            try container.encode(Kind.topThree, forKey: .type)
            try card.encode(to: encoder)
        case .rideConfirm(let card):
            try container.encode(Kind.rideConfirm, forKey: .type)
            try card.encode(to: encoder)
        case .handoff(let card):
            try container.encode(Kind.handoff, forKey: .type)
            try card.encode(to: encoder)
        case .ownAccountConfirm(let card):
            try container.encode(Kind.ownAccountConfirm, forKey: .type)
            try card.encode(to: encoder)
        }
    }
}

/// Top-3 venue list (Vertical B).
struct TopThreeCard: Codable, Equatable {
    var title: String?
    var options: [PlaceOption]

    private enum CodingKeys: String, CodingKey { case title, options }
}

struct PlaceOption: Codable, Equatable, Identifiable {
    var id: String { name + (address ?? "") }
    var name: String
    /// Short, spoken-friendly description from real data only.
    var summary: String?
    var rating: Double?
    var distanceText: String?
    var openNow: Bool?
    /// nil means unknown → UI shows "accessibility info unavailable" (never guessed).
    var wheelchairAccessible: Bool?
    var address: String?
    var phone: String?
    var website: String?
    var latitude: Double?
    var longitude: Double?

    private enum CodingKeys: String, CodingKey {
        case name, summary, rating
        case distanceText = "distance_text"
        case openNow = "open_now"
        case wheelchairAccessible = "wheelchair_accessible"
        case address, phone, website, latitude, longitude
    }
}

/// One-line ride confirmation before hand-off (Vertical A).
struct RideConfirmCard: Codable, Equatable {
    var summary: String
    var pickupName: String?
    var destinationName: String?
    var pickupLatitude: Double?
    var pickupLongitude: Double?
    var destinationLatitude: Double?
    var destinationLongitude: Double?
    /// e.g. "Wheelchair-accessible ride types suggested" — from profile, not invented.
    var note: String?

    private enum CodingKeys: String, CodingKey {
        case summary
        case pickupName = "pickup_name"
        case destinationName = "destination_name"
        case pickupLatitude = "pickup_latitude"
        case pickupLongitude = "pickup_longitude"
        case destinationLatitude = "destination_latitude"
        case destinationLongitude = "destination_longitude"
        case note
    }
}

/// Hand-off card: what opens, what's prefilled, honest tier copy, fallbacks.
struct HandoffCard: Codable, Equatable {
    var title: String?
    /// Primary actions, each a registry-built link (max 3 enforced on decode).
    var actions: [HandoffAction]
    /// Fallbacks (Apple Maps directions, call, website) — never a dead end.
    var fallbacks: [HandoffAction]?

    private enum CodingKeys: String, CodingKey { case title, actions, fallbacks }

    init(title: String?, actions: [HandoffAction], fallbacks: [HandoffAction]? = nil) {
        self.title = title
        self.actions = actions
        self.fallbacks = fallbacks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        let decoded = try container.decodeIfPresent([HandoffAction].self, forKey: .actions) ?? []
        actions = Array(decoded.prefix(3))
        fallbacks = try container.decodeIfPresent([HandoffAction].self, forKey: .fallbacks)
    }
}

/// v1.1 §4 — confirm-before-side-effect card for own-account actions
/// (reminder, calendar event, note, message via the user's Zapier). Shows
/// exactly what will happen; the action runs ONLY when the user taps Confirm
/// in this card. Never used for marketplace transactions.
struct OwnAccountConfirmCard: Codable, Equatable {
    /// Plain-language description of the side effect ("Text Maya your ETA").
    var summary: String
    /// One of: message | reminder | calendar_event | note | list_item.
    var kind: String
    /// The MCP tool to call on the user's Zapier server.
    var toolName: String?
    /// Serialized JSON arguments for that tool.
    var argumentsJSON: String?
    /// Set after the user confirmed and the call succeeded (prevents re-runs).
    var completed: Bool?

    private enum CodingKeys: String, CodingKey {
        case summary, kind, completed
        case toolName = "tool_name"
        case argumentsJSON = "arguments_json"
    }
}

struct HandoffAction: Codable, Equatable, Identifiable {
    var id: String { label + urlString }
    var label: String
    /// The link to open (registry-built app/universal link, tel:, maps, or web).
    var urlString: String
    /// Honest one-liner: what will open and what's pre-filled.
    var detail: String?

    private enum CodingKeys: String, CodingKey {
        case label
        case urlString = "url"
        case detail
    }

    /// Lenient: falls back to percent-encoding so a space or stray character
    /// never silently swallows a hand-off button.
    var url: URL? {
        if let direct = URL(string: urlString) { return direct }
        return urlString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            .flatMap(URL.init(string:))
    }
}
