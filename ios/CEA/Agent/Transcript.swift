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
