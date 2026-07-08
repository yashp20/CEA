import Foundation

/// v1.1 §3.1 — crowdsourced accessibility data layer (client side).
///
/// After a venue hand-off, CEA queues a short structured survey and — at a
/// natural, non-interrupting moment — asks ONE profile-adapted question.
/// Reports are anonymous by construction (attribute + yes/no + venue; no
/// user IDs, no profile data) and stored on the CEA Worker. Aggregates come
/// back with honest provenance ("confirmed by 3 CEA users, last confirmed
/// 2 weeks ago"; "no reports yet") and feed proactive barrier flags.
enum CrowdAttribute: String, CaseIterable, Codable {
    case stepFreeEntry = "step_free_entry"
    case doorWidth = "door_width"
    case lowNoise = "low_noise"
    case evenLighting = "even_lighting"
    case accessibleBathroom = "accessible_bathroom"
    case aslFriendly = "asl_friendly"

    /// One short, plain question (asked one at a time, always skippable).
    var question: String {
        switch self {
        case .stepFreeEntry: return "Was the entrance step-free?"
        case .doorWidth: return "Was the doorway wide enough for a wheelchair?"
        case .lowNoise: return "Was it quiet enough to talk comfortably?"
        case .evenLighting: return "Was the lighting bright and even?"
        case .accessibleBathroom: return "Was there an accessible bathroom?"
        case .aslFriendly: return "Could staff communicate without speech, like writing or ASL?"
        }
    }

    /// Short label used in provenance lines.
    var displayName: String {
        switch self {
        case .stepFreeEntry: return "Step-free entry"
        case .doorWidth: return "Wide doorway"
        case .lowNoise: return "Low noise"
        case .evenLighting: return "Even lighting"
        case .accessibleBathroom: return "Accessible bathroom"
        case .aslFriendly: return "ASL-friendly staff"
        }
    }
}

struct CrowdAggregate: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        var yes: Int
        var no: Int
        var lastAt: Date?

        private enum CodingKeys: String, CodingKey {
            case yes, no
            case lastAt = "last_at"
        }

        init(yes: Int, no: Int, lastAt: Date?) {
            self.yes = yes
            self.no = no
            self.lastAt = lastAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            yes = try container.decodeIfPresent(Int.self, forKey: .yes) ?? 0
            no = try container.decodeIfPresent(Int.self, forKey: .no) ?? 0
            if let raw = try container.decodeIfPresent(String.self, forKey: .lastAt) {
                lastAt = ISO8601DateFormatter.crowd.date(from: raw)
            } else {
                lastAt = nil
            }
        }
    }

    var total: Int
    var attributes: [String: Entry]

    init(total: Int, attributes: [String: Entry]) {
        self.total = total
        self.attributes = attributes
    }

    func entry(for attribute: CrowdAttribute) -> Entry? {
        attributes[attribute.rawValue]
    }
}

private extension ISO8601DateFormatter {
    static let crowd: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum CrowdsourceService {

    /// Stable anonymous venue key: normalized name + coords rounded to
    /// ~100 m — same recipe as the DoorDash demo-set matching.
    static func venueKey(name: String, latitude: Double, longitude: Double) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        let kept = folded.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        let normalized = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(format: "%@@%.3f,%.3f", normalized, latitude, longitude)
    }

    private static var reportsURL: URL? {
        ProxyConfig.baseURL?.appending(path: "reports")
    }

    /// Submits one anonymous report. Throws on failure — callers surface the
    /// honest error; nothing is faked as sent.
    static func submit(venueKey: String, venueName: String, latitude: Double, longitude: Double,
                       attribute: CrowdAttribute, value: Bool) async throws {
        guard let url = reportsURL else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "The CEA service isn't configured on this build."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "venue_key": venueKey,
            "venue_name": venueName,
            "latitude": latitude,
            "longitude": longitude,
            "attribute": attribute.rawValue,
            "value": value,
        ] as [String: Any])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Couldn't send the report (HTTP \(code)). Nothing was saved."])
        }
    }

    /// Aggregate for a venue; nil when the layer is unreachable/unconfigured
    /// (callers then show nothing rather than a guess).
    static func aggregate(venueKey: String) async -> CrowdAggregate? {
        guard var components = reportsURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        components.queryItems = [URLQueryItem(name: "venue_key", value: venueKey)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(CrowdAggregate.self, from: data)
    }

    // MARK: Provenance (honest by construction)

    /// One line for result cards. Examples:
    /// "Step-free entry confirmed by 3 CEA users, last confirmed 2 weeks ago."
    /// "Mixed reports on step-free entry (2 yes, 1 no)."
    /// "No reports from CEA users yet."
    static func provenanceLine(aggregate: CrowdAggregate?, for attribute: CrowdAttribute, now: Date = .now) -> String {
        guard let aggregate, let entry = aggregate.entry(for: attribute), entry.yes + entry.no > 0 else {
            return "No reports from CEA users yet."
        }
        if entry.no == 0 {
            let users = entry.yes == 1 ? "1 CEA user" : "\(entry.yes) CEA users"
            if let lastAt = entry.lastAt {
                let ago = RelativeDateTimeFormatter.crowd.localizedString(for: lastAt, relativeTo: now)
                return "\(attribute.displayName) confirmed by \(users), last confirmed \(ago)."
            }
            return "\(attribute.displayName) confirmed by \(users)."
        }
        if entry.yes == 0 {
            let users = entry.no == 1 ? "1 CEA user" : "\(entry.no) CEA users"
            return "\(attribute.displayName) NOT found by \(users)."
        }
        return "Mixed reports on \(attribute.displayName.lowercased()) (\(entry.yes) yes, \(entry.no) no)."
    }

    /// The attribute this profile cares about most (drives which provenance
    /// line a card leads with, and the survey question order).
    static func priorityAttributes(for profile: AccessibilityProfile) -> [CrowdAttribute] {
        var ordered: [CrowdAttribute] = []
        if profile.wheelchair || profile.avoidStairs {
            ordered += [.stepFreeEntry, .doorWidth, .accessibleBathroom]
        }
        if profile.hearingImpaired {
            ordered += [.aslFriendly, .lowNoise]
        }
        if profile.blindness || profile.lowVision {
            ordered += [.evenLighting]
        }
        if profile.simplifiedMode {
            ordered += [.lowNoise]
        }
        for attribute in CrowdAttribute.allCases where !ordered.contains(attribute) {
            ordered.append(attribute)
        }
        return ordered
    }

    /// Proactive barrier flag (§3.1): true when the majority of reports for
    /// a mobility-relevant attribute say "no" and the profile needs it.
    /// Never inferred from missing data — only from actual reports.
    static func barrierWarning(aggregate: CrowdAggregate?, profile: AccessibilityProfile) -> String? {
        guard profile.wheelchair || profile.avoidStairs, let aggregate else { return nil }
        for attribute in [CrowdAttribute.stepFreeEntry, .doorWidth] {
            if let entry = aggregate.entry(for: attribute), entry.no > entry.yes, entry.no >= 1 {
                return "Possible barrier: CEA users reported \(attribute.displayName.lowercased()) issues here."
            }
        }
        return nil
    }
}

private extension RelativeDateTimeFormatter {
    static let crowd: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
