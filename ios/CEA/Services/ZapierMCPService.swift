import Foundation

/// v1.1 §4 — the own-account task layer: a minimal MCP (Model Context
/// Protocol) client over Streamable HTTP, pointed at the user's personal
/// Zapier MCP server endpoint.
///
/// Scope is STRICT and enforced at every layer (tool description, kind
/// whitelist, docs): own-account tasks only — calendar events, reminders,
/// notes, personal lists, and messages the user explicitly asked to send.
/// NEVER marketplace transactions; rides/food/payments stay on the deep-link
/// hand-off path (CLAUDE.md non-negotiable #1).
///
/// Credential model: the user connects their own apps inside Zapier; CEA
/// only ever sees this one endpoint URL and never stores third-party
/// credentials (non-negotiable #2, as amended for v1.1).
///
/// Cost note: every `tools/call` consumes one Zapier task from the user's
/// quota and one network round trip (typically 1–3 s). Never call it
/// speculatively — only after the user explicitly confirmed the action.
final class ZapierMCPService {
    static let shared = ZapierMCPService()

    // TODO(cea): wire Zapier MCP endpoint — set CEA_ZAPIER_MCP_URL in
    // ios/Secrets.xcconfig (from mcp.zapier.com after connecting your apps).
    // TODO(cea): embedded connection flow — Zapier's embed SDK would let
    // users connect apps without leaving CEA; needs a Zapier partner account.
    static var endpointURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CEAZapierMCPURL") as? String,
              !raw.isEmpty, !raw.hasPrefix("$("),
              let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    static var isConfigured: Bool { endpointURL != nil }

    enum MCPError: LocalizedError {
        case notConfigured
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Own-account actions aren't connected yet. (Developer: set CEA_ZAPIER_MCP_URL in Secrets.xcconfig.)"
            case .badResponse(let message):
                return "The action service answered unexpectedly: \(message)"
            }
        }
    }

    private let session: URLSession
    private var initialized = false
    private var sessionID: String?
    private var nextRequestID = 1

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calls one MCP tool and returns its text content. Only ever invoked
    /// after an explicit user confirmation tap (confirm-before-side-effect).
    func callTool(name: String, argumentsJSON: String?) async throws -> String {
        try await initializeIfNeeded()
        var arguments: Any = [String: Any]()
        if let argumentsJSON, let data = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            arguments = parsed
        }
        let result = try await rpc(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        // MCP tool result: { content: [{type:"text", text}], isError? }
        if let isError = result["isError"] as? Bool, isError {
            throw MCPError.badResponse(Self.textContent(of: result) ?? "tool reported an error")
        }
        return Self.textContent(of: result) ?? "Done."
    }

    /// Lists available tools with their input schemas — surfaced to the agent
    /// (and routine editor) so actions reflect what the user's Zapier account
    /// actually offers, never guessed.
    func listTools() async throws -> [(name: String, description: String, schemaJSON: String)] {
        try await initializeIfNeeded()
        let result = try await rpc(method: "tools/list", params: [:])
        let tools = result["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let schema = tool["inputSchema"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            return (
                name: name,
                description: tool["description"] as? String ?? "",
                schemaJSON: schema.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            )
        }
    }

    // MARK: JSON-RPC over Streamable HTTP

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        _ = try await rpc(method: "initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "CEA", "version": "1.1"],
        ])
        initialized = true
        // Fire-and-forget per spec; failures here don't block tool calls.
        try? await notify(method: "notifications/initialized")
    }

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = Self.endpointURL else { throw MCPError.notConfigured }
        let id = nextRequestID
        nextRequestID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]

        let (data, contentType, mcpSession) = try await post(body, to: url)
        if let mcpSession { sessionID = mcpSession }

        let payload: [String: Any]?
        if contentType.contains("text/event-stream") {
            payload = Self.firstJSONObject(inSSE: data)
        } else {
            payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let payload else { throw MCPError.badResponse("empty reply") }
        if let error = payload["error"] as? [String: Any] {
            throw MCPError.badResponse(error["message"] as? String ?? "unknown MCP error")
        }
        return payload["result"] as? [String: Any] ?? [:]
    }

    private func notify(method: String) async throws {
        guard let url = Self.endpointURL else { return }
        _ = try await post(["jsonrpc": "2.0", "method": method], to: url)
    }

    private func post(_ body: [String: Any], to url: URL) async throws -> (Data, String, String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.badResponse("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw MCPError.badResponse("HTTP \(http.statusCode)")
        }
        return (
            data,
            http.value(forHTTPHeaderField: "Content-Type") ?? "",
            http.value(forHTTPHeaderField: "Mcp-Session-Id")
        )
    }

    /// First JSON object in an SSE body (`data: {...}` lines).
    private static func firstJSONObject(inSSE data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["result"] != nil || object["error"] != nil {
                return object
            }
        }
        return nil
    }

    private static func textContent(of result: [String: Any]) -> String? {
        let content = result["content"] as? [[String: Any]] ?? []
        let texts = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}
