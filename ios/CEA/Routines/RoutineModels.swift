import Foundation
import SwiftData

/// v1.1 §3.2 — a saved multi-step flow ("Going home" = ride hand-off + text
/// a contact + set a reminder). User-created, editable, and every step is
/// visible before it runs. On-device only.
@Model
final class Routine {
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RoutineStep.routine)
    var steps: [RoutineStep] = []

    init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    var sortedSteps: [RoutineStep] {
        steps.sorted { $0.orderIndex < $1.orderIndex }
    }
}

/// One step. `kindRaw` + `paramsJSON` keep the schema open without
/// migrations; `RoutineEngine` owns encoding/decoding.
@Model
final class RoutineStep {
    var orderIndex: Int
    var kindRaw: String
    /// User-visible description shown before the step runs.
    var title: String
    var paramsJSON: String
    var routine: Routine?

    init(orderIndex: Int, kindRaw: String, title: String, paramsJSON: String) {
        self.orderIndex = orderIndex
        self.kindRaw = kindRaw
        self.title = title
        self.paramsJSON = paramsJSON
    }
}

enum RoutineStepKind: String, CaseIterable {
    /// Opens Uber/Lyft with the destination pre-filled. Stays a hand-off:
    /// the user requests the ride in the other app (non-negotiable #1).
    case rideHandoff = "ride_handoff"
    /// An own-account action through the §4 Zapier layer (message, reminder,
    /// calendar event, note, list item). Side effect → explicit confirm.
    case ownAccount = "own_account"

    var displayName: String {
        switch self {
        case .rideHandoff: return "Ride hand-off"
        case .ownAccount: return "Own-account action"
        }
    }
}

struct RideStepParams: Codable, Equatable {
    var destinationName: String
    var destinationLatitude: Double
    var destinationLongitude: Double

    private enum CodingKeys: String, CodingKey {
        case destinationName = "destination_name"
        case destinationLatitude = "destination_latitude"
        case destinationLongitude = "destination_longitude"
    }
}

struct OwnAccountStepParams: Codable, Equatable {
    /// message | reminder | calendar_event | note | list_item (§4 whitelist).
    var kind: String
    /// Exactly what will happen, in plain language.
    var summary: String
    var toolName: String
    var argumentsJSON: String?

    private enum CodingKeys: String, CodingKey {
        case kind, summary
        case toolName = "tool_name"
        case argumentsJSON = "arguments_json"
    }
}

/// Pure step logic, kept out of the views so it's unit-testable (§6).
enum RoutineEngine {

    static func kind(of step: RoutineStep) -> RoutineStepKind? {
        RoutineStepKind(rawValue: step.kindRaw)
    }

    /// Side-effect steps (send/create something) require an explicit per-step
    /// confirmation; a ride hand-off only opens another app.
    static func requiresConfirmation(_ step: RoutineStep) -> Bool {
        kind(of: step) == .ownAccount
    }

    static func rideParams(_ step: RoutineStep) -> RideStepParams? {
        guard kind(of: step) == .rideHandoff,
              let data = step.paramsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RideStepParams.self, from: data)
    }

    static func ownAccountParams(_ step: RoutineStep) -> OwnAccountStepParams? {
        guard kind(of: step) == .ownAccount,
              let data = step.paramsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OwnAccountStepParams.self, from: data)
    }

    static func encode<T: Encodable>(_ params: T) -> String {
        guard let data = try? JSONEncoder().encode(params) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Ride links for a ride step, from the user's (coarse) pickup point —
    /// always through the DeepLinkRegistry, never built here.
    static func rideLinks(for params: RideStepParams, pickup: RidePoint) -> (uber: HandoffLink, lyft: HandoffLink) {
        let dropoff = RidePoint(
            latitude: params.destinationLatitude,
            longitude: params.destinationLongitude,
            nickname: params.destinationName,
            formattedAddress: nil
        )
        return (
            uber: DeepLinkRegistry.uberRideLink(pickup: pickup, dropoff: dropoff),
            lyft: DeepLinkRegistry.lyftRideLink(pickup: pickup, dropoff: dropoff)
        )
    }

    /// The visible run plan: ordered steps with their confirmation
    /// requirement — what the runner shows before anything executes.
    struct PlannedStep: Equatable {
        var index: Int
        var title: String
        var kind: RoutineStepKind
        var requiresConfirmation: Bool
    }

    static func plan(for routine: Routine) -> [PlannedStep] {
        routine.sortedSteps.compactMap { step in
            guard let kind = kind(of: step) else { return nil }
            return PlannedStep(
                index: step.orderIndex,
                title: step.title,
                kind: kind,
                requiresConfirmation: requiresConfirmation(step)
            )
        }
    }

    /// Case-insensitive containment match for one-utterance triggers
    /// ("run going home" → routine named "Going home").
    static func match(_ query: String, in routines: [Routine]) -> Routine? {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return routines.first { routine in
            let name = routine.name.lowercased()
            return name == normalized || name.contains(normalized) || normalized.contains(name)
        }
    }
}
