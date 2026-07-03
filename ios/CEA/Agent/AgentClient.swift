import Foundation

/// Talks to the CEA proxy (which holds the Anthropic API key and enforces
/// model + max_tokens) and runs the client-side tool-use loop: Claude plans,
/// tools execute in Swift on device, results go back until a final text turn.
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
    private var proxyURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CEAProxyURL") as? String,
              !raw.isEmpty, !raw.hasPrefix("$("),
              let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// Runs one user turn. `history` is prior chat messages (persisted
    /// transcript); events stream back to the UI as they happen.
    func send(userText: String, history: [ChatMessage], onEvent: @MainActor (AgentEvent) -> Void) async throws {
        guard let proxyURL else { throw AgentError.proxyNotConfigured }

        var messages = Self.apiTranscript(from: history)
        messages.append(APIMessage(role: "user", content: [.text(userText)]))

        let system = SystemPrompt.build(
            profileSummary: profileStore.profile.promptSummary,
            memoryLines: profileStore.memoryPromptLines
        )

        for _ in 0..<maxToolTurns {
            let request = MessagesRequest(
                system: system,
                messages: messages,
                tools: toolbox.definitions,
                maxTokens: 700
            )
            let response = try await post(request, to: proxyURL)

            var toolResults: [APIContentBlock] = []
            for block in response.content {
                switch block {
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onEvent(.assistantText(trimmed)) }
                case .toolUse(let id, let name, let input):
                    let result = await toolbox.execute(name: name, input: input, sink: onEvent)
                    toolResults.append(.toolResult(toolUseID: id, content: result.content, isError: result.isError))
                case .toolResult:
                    continue // never sent by the API
                }
            }

            guard response.stopReason == "tool_use", !toolResults.isEmpty else { return }
            messages.append(APIMessage(role: "assistant", content: response.content))
            messages.append(APIMessage(role: "user", content: toolResults))
        }
    }

    // MARK: Networking

    private func post(_ body: MessagesRequest, to url: URL) async throws -> MessagesResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            throw AgentError.badResponse(apiError?.error?.message ?? "server returned \(http.statusCode)")
        }
        return try JSONDecoder().decode(MessagesResponse.self, from: data)
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
