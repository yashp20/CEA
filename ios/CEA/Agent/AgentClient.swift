import Foundation

/// Talks to the CEA proxy (which holds the Anthropic API key and enforces
/// model + max_tokens) and runs the client-side tool-use loop: Claude plans,
/// tools execute in Swift on device, results go back until a final text turn.
///
/// v1.1 §3.5 — latency is an accessibility feature: responses stream over
/// SSE, text events fire as sentences arrive (so TTS can start speaking
/// immediately), and the UI shows an instant acknowledgment before the first
/// token. Falls back transparently to a plain JSON response when the proxy
/// doesn't stream.
@MainActor
final class AgentClient {

    enum AgentError: LocalizedError {
        case proxyNotConfigured
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .proxyNotConfigured:
                return "The assistant backend isn't set up on this build yet, so I can't answer. (Developer: set CEAProxyURL in Info.plist to your deployed /proxy URL.)"
            case .badResponse(let message):
                return "I couldn't reach the assistant service: \(message)"
            }
        }
    }

    private let toolbox: AgentToolbox
    private let profileStore: ProfileStore
    private let session: URLSession
    private let maxToolTurns = 8

    init(profileStore: ProfileStore, toolbox: AgentToolbox? = nil, session: URLSession = .shared) {
        self.profileStore = profileStore
        self.toolbox = toolbox ?? AgentToolbox(profileStore: profileStore)
        self.session = session
    }

    // TODO(cea): wire proxy URL — set CEAProxyURL in Info.plist (via
    // Secrets.xcconfig) to the deployed Cloudflare Worker from /proxy.
    private var proxyURL: URL? { ProxyConfig.baseURL }

    /// Runs one user turn. `history` is prior chat messages (persisted
    /// transcript); events stream back to the UI as they happen.
    func send(userText: String, history: [ChatMessage], onEvent: @MainActor (AgentEvent) -> Void) async throws {
        guard let proxyURL else { throw AgentError.proxyNotConfigured }

        var messages = Self.apiTranscript(from: history)
        messages.append(APIMessage(role: "user", content: [.text(userText)]))

        // §3.6: the verbosity dial shapes the prompt AND the output (below).
        let style = ResponseShaper.style(for: profileStore.profile)
        let system = SystemPrompt.build(
            profileSummary: profileStore.profile.promptSummary,
            memoryLines: profileStore.memoryPromptLines,
            identity: profileStore.profile.identitySummary,
            frequentPlaces: profileStore.frequentPlacesPromptLines,
            styleDirectives: ResponseShaper.promptDirectives(for: style)
        )

        for _ in 0..<maxToolTurns {
            let request = MessagesRequest(
                system: system,
                messages: messages,
                tools: toolbox.definitions,
                maxTokens: 700
            )
            let turn = try await streamTurn(request, to: proxyURL, style: style, onEvent: onEvent)

            var toolResults: [APIContentBlock] = []
            for block in turn.content {
                if case .toolUse(let id, let name, let input) = block {
                    let result = await toolbox.execute(name: name, input: input, sink: onEvent)
                    toolResults.append(.toolResult(toolUseID: id, content: result.content, isError: result.isError))
                }
            }

            guard turn.stopReason == "tool_use", !toolResults.isEmpty else { return }
            messages.append(APIMessage(role: "assistant", content: turn.content))
            messages.append(APIMessage(role: "user", content: toolResults))
        }
    }

    // MARK: Streaming

    private struct TurnResult {
        var content: [APIContentBlock]
        var stopReason: String?
    }

    /// One model turn over SSE. Emits `.assistantDelta` as text streams and
    /// `.assistantText` when a text block completes. Tool-use blocks are
    /// accumulated (input arrives as partial JSON) and returned for execution.
    private func streamTurn(
        _ body: MessagesRequest,
        to url: URL,
        style: ResponseStyle,
        onEvent: @MainActor (AgentEvent) -> Void
    ) async throws -> TurnResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.badResponse("no HTTP response")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        // Fallback: proxy answered with a complete JSON body (older proxy or
        // an error payload). Same behavior as the pre-streaming client.
        guard http.statusCode == 200, contentType.contains("text/event-stream") else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            if http.statusCode != 200 {
                let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
                throw AgentError.badResponse(apiError?.error?.message ?? "server returned \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            for block in decoded.content {
                if case .text(let text) = block {
                    let shaped = ResponseShaper.shape(text, style: style)
                    if !shaped.isEmpty {
                        onEvent(.assistantDelta(full: shaped))
                        onEvent(.assistantText(shaped))
                    }
                }
            }
            return TurnResult(content: decoded.content, stopReason: decoded.stopReason)
        }

        // SSE path: accumulate content blocks by index in arrival order.
        var blockOrder: [Int] = []
        var texts: [Int: String] = [:]
        var toolUses: [Int: (id: String, name: String, partialJSON: String)] = [:]
        var stopReason: String?
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8),
                  let event = try? decoder.decode(StreamEvent.self, from: data) else { continue }

            switch event.type {
            case "content_block_start":
                guard let index = event.index, let block = event.contentBlock else { continue }
                blockOrder.append(index)
                switch block.type {
                case "text":
                    texts[index] = block.text ?? ""
                case "tool_use":
                    toolUses[index] = (id: block.id ?? "", name: block.name ?? "", partialJSON: "")
                default:
                    break // unknown block types are ignored
                }

            case "content_block_delta":
                guard let index = event.index, let delta = event.delta else { continue }
                if let text = delta.text, texts[index] != nil {
                    texts[index]! += text
                    let sofar = texts[index]!.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sofar.isEmpty { onEvent(.assistantDelta(full: sofar)) }
                }
                if let partial = delta.partialJSON, toolUses[index] != nil {
                    toolUses[index]!.partialJSON += partial
                }

            case "content_block_stop":
                guard let index = event.index else { continue }
                if let text = texts[index] {
                    // §3.6 mechanical cap: the final text replaces the raw
                    // streamed text in the UI.
                    let shaped = ResponseShaper.shape(text, style: style)
                    if !shaped.isEmpty { onEvent(.assistantText(shaped)) }
                }

            case "message_delta":
                if let reason = event.delta?.stopReason { stopReason = reason }

            case "error":
                throw AgentError.badResponse(event.error?.message ?? "stream error")

            default:
                break // message_start, ping, message_stop
            }
        }

        var content: [APIContentBlock] = []
        for index in blockOrder {
            if let text = texts[index] {
                content.append(.text(text))
            } else if let tool = toolUses[index] {
                let inputData = tool.partialJSON.data(using: .utf8) ?? Data()
                let input = (try? decoder.decode(JSONValue.self, from: inputData)) ?? .object([:])
                content.append(.toolUse(id: tool.id, name: tool.name, input: input))
            }
        }
        return TurnResult(content: content, stopReason: stopReason)
    }

    // MARK: Transcript mapping

    /// Persisted chat → API transcript. Notices are UI-only; cards were
    /// produced via tools, so their narration text already covers them.
    /// Kept to the last 20 turns to bound request size.
    static func apiTranscript(from history: [ChatMessage]) -> [APIMessage] {
        var result: [APIMessage] = []
        for message in history.suffix(20) {
            let role: String
            switch message.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .notice: continue
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // The Messages API requires alternating roles; merge consecutive
            // same-role turns into one message.
            if let last = result.last, last.role == role {
                result[result.count - 1].content.append(.text(text))
            } else {
                result.append(APIMessage(role: role, content: [.text(text)]))
            }
        }
        // First message must be from the user.
        if let first = result.first, first.role != "user" {
            result.removeFirst()
        }
        return result
    }
}

/// Single source for the proxy base URL (used by the agent, the crowdsource
/// layer, and the memory backend — all ride the same Worker).
enum ProxyConfig {
    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CEAProxyURL") as? String,
              !raw.isEmpty, !raw.hasPrefix("$("),
              let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

/// Reliable, silent memory. Runs a dedicated extraction pass on every user
/// message and saves durable facts — independent of whether the main agent
/// remembers to call save_preference (models are unreliable at that while
/// juggling many tools, so we don't depend on it). Fire-and-forget: any
/// failure degrades silently and never disrupts the chat.
enum MemoryExtractor {
    private struct Fact: Decodable { let key: String; let value: String }

    private static let system = """
    You maintain a long-term memory of durable, personal facts about the user. \
    You are given what is already known plus the user's new message, and you \
    output ONLY a JSON array of {"key","value"} objects for facts to add or \
    update: their name; preferences, likes and dislikes; hobbies and interests; \
    routines; their usual or regular orders; the services, providers, accounts, \
    brands, apps and tools they use (bank, phone carrier, stores, delivery \
    apps); people in their life; and places they go.

    Merging with what's already known (important):
    - If the message ADDS to something already known — another hobby, another \
    favourite food, another regular place — output that key with the COMBINED \
    value, keeping the old entries and appending the new one \
    (e.g. "hobbies": "pickleball, badminton"). NEVER drop something already \
    known just because the new message didn't repeat it.
    - Use plural keys for things people can have several of (hobbies, \
    favourite_foods, favourite_stores) so they accumulate naturally.
    - Only if the message clearly CORRECTS or replaces a fact (they switched \
    banks, moved city, changed their usual order) output that key with just \
    the new value.
    - Output only keys you are adding or changing; omit unchanged facts.

    Rules: snake_case keys; short plain-language values. Capture EVERYTHING \
    durable — err toward saving more. Do NOT include one-off requests, \
    questions, or transient intent ("order my regular" is a request, not a \
    fact). Never include health, disability, or medical information. If there \
    is nothing to add or change, output []. Output nothing but the JSON array.
    """

    @MainActor
    static func extract(from userText: String, into profileStore: ProfileStore, session: URLSession = .shared) async {
        guard let url = ProxyConfig.baseURL else { return }
        // Pass what's already known so the model merges (appends another hobby)
        // instead of silently overwriting a key.
        let content = """
        Already known about this user:
        \(profileStore.memoryPromptLines)

        New message from the user:
        \(userText)
        """
        let body = MessagesRequest(
            system: system,
            messages: [APIMessage(role: "user", content: [.text(content)])],
            tools: [],
            maxTokens: 400,
            stream: false
        )
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            let text = decoded.content.compactMap { block -> String? in
                if case .text(let value) = block { return value } else { return nil }
            }.joined()
            for fact in parseFacts(from: text) where !fact.key.isEmpty && !fact.value.isEmpty {
                profileStore.savePreference(key: fact.key, value: fact.value)
            }
        } catch {
            // Best-effort; silent by design.
        }
    }

    /// Pulls the JSON array out of the reply, tolerating code fences or stray
    /// prose around it. Decoded element-by-element so one malformed entry
    /// can't discard the whole batch (models occasionally emit a stray object),
    /// and a list value like ["a","b"] is flattened rather than dropped.
    private static func parseFacts(from text: String) -> [Fact] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return [] }
        guard let data = String(text[start...end]).data(using: .utf8),
              let elements = try? JSONDecoder().decode([JSONValue].self, from: data) else { return [] }
        return elements.compactMap { element in
            guard let key = element["key"]?.stringValue, !key.isEmpty else { return nil }
            let raw = element["value"]
            let value: String?
            if let string = raw?.stringValue {
                value = string
            } else if let list = raw?.arrayValue {
                value = list.compactMap(\.stringValue).joined(separator: ", ")
            } else {
                value = nil
            }
            guard let value, !value.isEmpty else { return nil }
            return Fact(key: key, value: value)
        }
    }
}
