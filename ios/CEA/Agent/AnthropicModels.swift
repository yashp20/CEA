import Foundation

/// Minimal Codable coverage of the Claude Messages API shapes the app uses.
/// The app talks only to the CEA proxy, which holds the API key and enforces
/// model + max_tokens server-side (CLAUDE.md non-negotiable #4).

/// Arbitrary JSON — used for tool input schemas and tool_use inputs.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    // Convenience accessors for tool executors.
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    subscript(key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: Request

struct MessagesRequest: Encodable {
    var system: String
    var messages: [APIMessage]
    var tools: [ToolDefinition]
    /// Requested cap; the proxy clamps this to its own maximum.
    var maxTokens: Int
    /// Streaming is the default (v1.1 §3.5): first tokens reach voice-first
    /// users immediately instead of waiting for the full reply.
    var stream: Bool = true

    enum CodingKeys: String, CodingKey {
        case system, messages, tools, stream
        case maxTokens = "max_tokens"
    }
}

// MARK: Streaming (SSE) events

/// One decoded server-sent event from the Messages streaming API. Only the
/// fields the app consumes; unknown event types are skipped by the client.
struct StreamEvent: Decodable {
    var type: String
    var index: Int?
    var contentBlock: StreamContentBlock?
    var delta: StreamDelta?
    var error: APIErrorResponse.APIError?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, error
        case contentBlock = "content_block"
    }
}

struct StreamContentBlock: Decodable {
    var type: String
    var id: String?
    var name: String?
    var text: String?
}

struct StreamDelta: Decodable {
    var type: String?
    var text: String?
    var partialJSON: String?
    var stopReason: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case partialJSON = "partial_json"
        case stopReason = "stop_reason"
    }
}

struct APIMessage: Codable {
    var role: String // "user" | "assistant"
    var content: [APIContentBlock]
}

/// Content blocks the app sends or receives.
enum APIContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(JSONValue.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: (try? container.decode(String.self, forKey: .content)) ?? "",
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        default:
            // Ignore unknown block types (e.g. thinking) as empty text.
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            if isError { try container.encode(true, forKey: .isError) }
        }
    }
}

struct ToolDefinition: Encodable {
    var name: String
    var description: String
    var inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

// MARK: Response

struct MessagesResponse: Decodable {
    var content: [APIContentBlock]
    var stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

struct APIErrorResponse: Decodable {
    struct APIError: Decodable {
        var type: String?
        var message: String?
    }
    var error: APIError?
}
