import CoreLocation
import Foundation
import MapKit

/// Events the agent surfaces to the UI while a turn runs.
enum AgentEvent {
    /// Streaming update (v1.1 §3.5): the full text of the in-flight assistant
    /// message so far. The UI renders it live; TTS speaks completed sentences.
    case assistantDelta(full: String)
    /// The finalized text of an assistant message (post style shaping).
    case assistantText(String)
    case card(CardPayload)
    /// Visible confirmation lines (e.g. "Saved: …") — rendered distinctly.
    case notice(String)
    /// Open a routine's run screen (v1.1 §3.2, one-utterance trigger). Every
    /// step stays visible and user-executed — the agent only opens the door.
    case startRoutine(Routine)
}

/// Executes tool calls in Swift on device (CLAUDE.md agent loop §2).
/// The model plans; the device acts.
@MainActor
final class AgentToolbox {
    private let profileStore: ProfileStore
    private let places: PlacesSearching
    private let location: LocationService

    init(profileStore: ProfileStore,
         places: PlacesSearching = PlacesServiceFactory.make(),
         location: LocationService = .shared) {
        self.profileStore = profileStore
        self.places = places
        self.location = location
    }

    // MARK: Definitions sent with every request

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "geocode",
                description: "Resolve a place name or address to coordinates, or get the user's current location. Returns name, latitude, longitude, and address.",
                inputSchema: schema(
                    properties: [
                        "query": prop("string", "Place name or address to resolve. Use \"current location\" for the user's location."),
                    ],
                    required: ["query"]
                )
            ),
            ToolDefinition(
                name: "search_places",
                description: "Search real venue data near the user. Returns up to 10 candidates with name, distance, rating, open-now, wheelchair-accessible-entrance (null when unknown — say so), phone, website. Rank and present at most 3.",
                inputSchema: schema(
                    properties: [
                        "query": prop("string", "What to search for, e.g. 'indian restaurant'."),
                        "latitude": prop("number", "Search center latitude. Omit to use the user's current location."),
                        "longitude": prop("number", "Search center longitude. Omit to use the user's current location."),
                    ],
                    required: ["query"]
                )
            ),
            ToolDefinition(
                name: "build_handoff_link",
                description: "Build hand-off links. kind=ride returns Uber and Lyft links with pickup/destination pre-filled. kind=food returns a DoorDash page link plus Apple Maps directions, phone, and website fallbacks. Use the returned URLs verbatim in a render_card handoff card.",
                inputSchema: schema(
                    properties: [
                        "kind": propEnum("Which hand-off to build.", values: ["ride", "food"]),
                        "pickup_latitude": prop("number", "Ride: pickup latitude."),
                        "pickup_longitude": prop("number", "Ride: pickup longitude."),
                        "pickup_name": prop("string", "Ride: short pickup label."),
                        "destination_latitude": prop("number", "Ride: destination latitude."),
                        "destination_longitude": prop("number", "Ride: destination longitude."),
                        "destination_name": prop("string", "Ride: short destination label."),
                        "restaurant_name": prop("string", "Food: restaurant name."),
                        "latitude": prop("number", "Food: venue latitude for directions."),
                        "longitude": prop("number", "Food: venue longitude for directions."),
                        "phone": prop("string", "Food: venue phone if known from search results."),
                        "website": prop("string", "Food: venue website if known from search results."),
                    ],
                    required: ["kind"]
                )
            ),
            ToolDefinition(
                name: "save_preference",
                description: "Store one small user preference (favorite cuisine, frequent destination, ride preference) with a visible confirmation. Key is a short snake_case label. Never store sensitive or health data.",
                inputSchema: schema(
                    properties: [
                        "key": prop("string", "Short snake_case key, e.g. 'favorite_cuisine'."),
                        "value": prop("string", "The remembered value, plain language."),
                    ],
                    required: ["key", "value"]
                )
            ),
            ToolDefinition(
                name: "run_routine",
                description: "Open one of the user's saved routines (multi-step flows like 'Going home') by name when they ask to run it. The routine's steps are shown to the user and they run/confirm each step themselves — nothing executes automatically.",
                inputSchema: schema(
                    properties: [
                        "name": prop("string", "The routine name the user said, e.g. 'going home'."),
                    ],
                    required: ["name"]
                )
            ),
            ToolDefinition(
                name: "own_account_action",
                description: "Own-account tasks ONLY, through the user's connected Zapier: create a reminder or calendar event, save a note, add to a personal list, or send a message the user explicitly asked to send. NEVER rides, food, payments, orders, bookings, or anything on a marketplace — those use build_handoff_link. Call without tool_name first to discover the available tools. Every action shows a confirmation card and runs only after the user taps Confirm; never claim it happened.",
                inputSchema: schema(
                    properties: [
                        "kind": propEnum("Type of own-account task.", values: ["message", "reminder", "calendar_event", "note", "list_item"]),
                        "summary": prop("string", "One plain sentence describing exactly what will happen, e.g. 'Text Maya: on my way, ETA 15 minutes.'"),
                        "tool_name": prop("string", "The Zapier MCP tool to run. Omit on the first call to get the tool list."),
                        "arguments": .object([
                            "type": .string("object"),
                            "description": .string("Arguments matching the chosen tool's input schema."),
                        ]),
                    ],
                    required: ["kind"],
                    additionalProperties: true
                )
            ),
            ToolDefinition(
                name: "render_card",
                description: "Render a structured card in the chat UI. type is one of: top_three (venue list, fields: title, options[{name, summary, rating, distance_text, open_now, wheelchair_accessible, address, phone, website, latitude, longitude}]), ride_confirm (fields: summary, pickup_name, destination_name, pickup_latitude, pickup_longitude, destination_latitude, destination_longitude, note), handoff (fields: title, actions[{label, url, detail}], fallbacks[{label, url, detail}]). Options beyond 3 are dropped.",
                inputSchema: schema(
                    properties: [
                        "type": propEnum("Card type.", values: ["top_three", "ride_confirm", "handoff"]),
                    ],
                    required: ["type"],
                    additionalProperties: true
                )
            ),
        ]
    }

    // MARK: Execution

    func execute(name: String, input: JSONValue, sink: (AgentEvent) -> Void) async -> (content: String, isError: Bool) {
        do {
            switch name {
            case "geocode":
                return (try await geocode(input), false)
            case "search_places":
                return (try await searchPlaces(input), false)
            case "build_handoff_link":
                return (try await buildHandoffLink(input), false)
            case "save_preference":
                return (savePreference(input, sink: sink), false)
            case "own_account_action":
                return await ownAccountAction(input, sink: sink)
            case "run_routine":
                return runRoutine(input, sink: sink)
            case "render_card":
                return renderCard(input, sink: sink)
            default:
                return ("Unknown tool: \(name)", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    // MARK: geocode

    private func geocode(_ input: JSONValue) async throws -> String {
        let query = input["query"]?.stringValue ?? ""
        if query.isEmpty || query.lowercased().contains("current location") {
            let loc = try await location.currentLocation()
            return encodeJSON([
                "name": .string("Current location"),
                "latitude": .number(LocationService.coarse(loc.coordinate.latitude)),
                "longitude": .number(LocationService.coarse(loc.coordinate.longitude)),
            ])
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let loc = try? await location.currentLocation() {
            request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            return "No result found for \"\(query)\". Ask the user to rephrase or give an address."
        }
        let coordinate = item.placemark.coordinate
        return encodeJSON([
            "name": .string(item.name ?? query),
            "latitude": .number(coordinate.latitude),
            "longitude": .number(coordinate.longitude),
            "address": .string(item.placemark.title ?? ""),
        ])
    }

    // MARK: search_places

    private func searchPlaces(_ input: JSONValue) async throws -> String {
        let query = input["query"]?.stringValue ?? ""
        let center: CLLocationCoordinate2D
        if let lat = input["latitude"]?.doubleValue, let lng = input["longitude"]?.doubleValue {
            center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        } else {
            let loc = try await location.currentLocation()
            center = CLLocationCoordinate2D(
                latitude: LocationService.coarse(loc.coordinate.latitude),
                longitude: LocationService.coarse(loc.coordinate.longitude)
            )
        }
        let results = try await places.search(query: query, near: center)
        if results.isEmpty {
            return "No venues found for \"\(query)\" nearby. Data source: \(places.sourceDescription)."
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(results)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return "Data source: \(places.sourceDescription).\nResults: \(json)"
    }

    // MARK: build_handoff_link

    private func buildHandoffLink(_ input: JSONValue) async throws -> String {
        switch input["kind"]?.stringValue {
        case "ride":
            guard let pLat = input["pickup_latitude"]?.doubleValue,
                  let pLng = input["pickup_longitude"]?.doubleValue,
                  let dLat = input["destination_latitude"]?.doubleValue,
                  let dLng = input["destination_longitude"]?.doubleValue else {
                return "Missing pickup/destination coordinates. Geocode both first."
            }
            let pickup = RidePoint(latitude: pLat, longitude: pLng,
                                   nickname: input["pickup_name"]?.stringValue, formattedAddress: nil)
            let dropoff = RidePoint(latitude: dLat, longitude: dLng,
                                    nickname: input["destination_name"]?.stringValue, formattedAddress: nil)
            let uber = DeepLinkRegistry.uberRideLink(pickup: pickup, dropoff: dropoff)
            let lyft = DeepLinkRegistry.lyftRideLink(pickup: pickup, dropoff: dropoff)
            return encodeJSON([
                "uber": .object([
                    "url": .string(uber.preferredURL().absoluteString),
                    "installed": .bool(DeepLinkRegistry.isAppInstalled(.uber)),
                    "detail": .string(uber.detail),
                ]),
                "lyft": .object([
                    "url": .string(lyft.preferredURL().absoluteString),
                    "installed": .bool(DeepLinkRegistry.isAppInstalled(.lyft)),
                    "detail": .string(lyft.detail),
                ]),
                "note": .string("Ride-type availability (including wheelchair-accessible types) is chosen inside the ride app; do not promise availability."),
            ])
        case "food":
            let name = input["restaurant_name"]?.stringValue ?? "the restaurant"
            // Store slugs come from the registry demo set (Chicago); venues
            // outside it honestly get a DoorDash search link instead.
            let doordash = DeepLinkRegistry.doordashStoreLink(
                storeSlugAndID: DeepLinkRegistry.doordashSlug(matching: name),
                restaurantName: name
            )
            var payload: [String: JSONValue] = [
                "doordash": .object([
                    "url": .string(doordash.webURL.absoluteString),
                    "detail": .string(doordash.detail),
                ]),
            ]
            if let lat = input["latitude"]?.doubleValue, let lng = input["longitude"]?.doubleValue {
                payload["directions"] = .object([
                    "url": .string(DeepLinkRegistry.appleMapsDirections(latitude: lat, longitude: lng, name: name).absoluteString),
                    "detail": .string("Walking directions in Apple Maps."),
                ])
            }
            if let phone = input["phone"]?.stringValue, let tel = DeepLinkRegistry.phoneCall(number: phone) {
                payload["call"] = .object([
                    "url": .string(tel.absoluteString),
                    "detail": .string("Call \(name) directly."),
                ])
            }
            if let site = input["website"]?.stringValue, URL(string: site) != nil {
                payload["website"] = .object([
                    "url": .string(site),
                    "detail": .string("Open the restaurant's website."),
                ])
            }
            return encodeJSON(payload)
        default:
            return "Unknown hand-off kind. Use \"ride\" or \"food\"."
        }
    }

    // MARK: save_preference

    private func savePreference(_ input: JSONValue, sink: (AgentEvent) -> Void) -> String {
        guard let key = input["key"]?.stringValue, let value = input["value"]?.stringValue,
              !key.isEmpty, !value.isEmpty else {
            return "Missing key or value."
        }
        let confirmation = profileStore.savePreference(key: key.replacingOccurrences(of: " ", with: "_"), value: value)
        sink(.notice(confirmation))
        return "Preference stored and confirmation shown to the user: \(confirmation)"
    }

    // MARK: run_routine (v1.1 §3.2)

    private func runRoutine(_ input: JSONValue, sink: (AgentEvent) -> Void) -> (String, Bool) {
        let query = input["name"]?.stringValue ?? ""
        let routines = profileStore.allRoutines()
        guard !routines.isEmpty else {
            return ("The user has no saved routines yet. Tell them they can create one from the sidebar under Routines.", false)
        }
        guard let match = RoutineEngine.match(query, in: routines) else {
            let names = routines.map(\.name).joined(separator: ", ")
            return ("No routine matches \"\(query)\". Available routines: \(names). Ask which one they meant.", false)
        }
        sink(.startRoutine(match))
        return ("Routine \"\(match.name)\" opened for the user with every step visible. They run and confirm each step themselves — do not claim any step ran.", false)
    }

    // MARK: own_account_action (v1.1 §4)

    /// Own-account tasks via the user's Zapier MCP server. Strictly scoped
    /// (kind whitelist; marketplace stays on hand-off). The tool itself never
    /// executes anything — it renders a confirmation card, and the side
    /// effect runs only when the user taps Confirm in that card.
    private func ownAccountAction(_ input: JSONValue, sink: (AgentEvent) -> Void) async -> (String, Bool) {
        guard ZapierMCPService.isConfigured else {
            // TODO(cea): wire Zapier MCP endpoint (CEA_ZAPIER_MCP_URL).
            return ("Own-account actions aren't connected on this build. Tell the user honestly that reminders, calendar events, notes, and messages need the Zapier connection, which isn't set up yet.", false)
        }
        let allowedKinds = ["message", "reminder", "calendar_event", "note", "list_item"]
        guard let kind = input["kind"]?.stringValue, allowedKinds.contains(kind) else {
            return ("kind must be one of \(allowedKinds.joined(separator: ", ")). Rides, food, payments, and marketplace transactions are never own-account actions — use build_handoff_link.", true)
        }
        guard let toolName = input["tool_name"]?.stringValue, !toolName.isEmpty else {
            // Discovery pass: real tool list from the user's server, never guessed.
            do {
                let tools = try await ZapierMCPService.shared.listTools()
                guard !tools.isEmpty else {
                    return ("The user's Zapier server exposes no tools yet. Say so honestly and suggest connecting apps at zapier.com.", false)
                }
                let listing = tools.map { "- \($0.name): \($0.description) (input schema: \($0.schemaJSON))" }
                    .joined(separator: "\n")
                return ("Pick ONE tool and call own_account_action again with tool_name, arguments, and summary. Available tools:\n\(listing)", false)
            } catch {
                return (error.localizedDescription, true)
            }
        }
        guard let summary = input["summary"]?.stringValue, !summary.isEmpty else {
            return ("Provide summary: one plain sentence describing exactly what will happen.", true)
        }
        let argumentsJSON = input["arguments"].flatMap { value -> String? in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let card = OwnAccountConfirmCard(
            summary: summary, kind: kind, toolName: toolName,
            argumentsJSON: argumentsJSON, completed: nil
        )
        sink(.card(.ownAccountConfirm(card)))
        return ("Confirmation card shown. The action runs ONLY if the user taps Confirm — do not claim it happened. Briefly tell the user to review the card.", false)
    }

    // MARK: render_card

    private func renderCard(_ input: JSONValue, sink: (AgentEvent) -> Void) -> (String, Bool) {
        do {
            let data = try JSONEncoder().encode(input)
            let card = try JSONDecoder().decode(CardPayload.self, from: data)
            sink(.card(card))
            return ("Card rendered.", false)
        } catch {
            return ("Invalid card payload: \(error.localizedDescription)", true)
        }
    }

    // MARK: Schema helpers

    private func schema(properties: [String: JSONValue], required: [String], additionalProperties: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ]
        if !additionalProperties {
            object["additionalProperties"] = .bool(false)
        }
        return .object(object)
    }

    private func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private func propEnum(_ description: String, values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map { .string($0) }),
        ])
    }

    private func encodeJSON(_ object: [String: JSONValue]) -> String {
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
