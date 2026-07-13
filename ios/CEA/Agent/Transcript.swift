import Foundation
import SwiftData

/// Persisted chat history (PRD F2). One ChatSession per conversation in the
/// Chats list; messages persist locally in SwiftData only.
@Model
final class ChatSession {
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

    init(title: String = "New chat") {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

/// Keeps the chat list honest (v1.1 revision, bug 3): blank "New chat"
/// sessions are placeholders, not history — they're reused instead of
/// multiplied, hidden from the list, and purged at launch.
enum SessionHousekeeping {
    /// Sessions worth listing: ones the user actually wrote in.
    static func listable(_ sessions: [ChatSession]) -> [ChatSession] {
        sessions.filter { !$0.messages.isEmpty }
    }

    /// An existing blank session to route back to instead of creating another.
    static func reusableEmpty(_ sessions: [ChatSession]) -> ChatSession? {
        sessions.first { $0.messages.isEmpty }
    }

    /// All redundant blanks (empty sessions other than the one in use).
    static func redundantEmpties(_ sessions: [ChatSession], keeping keep: ChatSession?) -> [ChatSession] {
        sessions.filter { $0.messages.isEmpty && $0 !== keep }
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
    /// System-generated confirmation lines (e.g. "Saved: …") rendered
    /// distinctly and excluded from the LLM transcript.
    case notice
}

@Model
final class ChatMessage {
    var roleRaw: String
    var text: String
    /// JSON-encoded CardPayload when the agent rendered a structured card.
    var cardJSON: String?
    var createdAt: Date
    var session: ChatSession?

    init(role: MessageRole, text: String, cardJSON: String? = nil, createdAt: Date = .now) {
        self.roleRaw = role.rawValue
        self.text = text
        self.cardJSON = cardJSON
        self.createdAt = createdAt
    }

    var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .assistant }

    var card: CardPayload? {
        guard let cardJSON, let data = cardJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CardPayload.self, from: data)
    }
}
