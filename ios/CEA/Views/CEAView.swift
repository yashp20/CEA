import SwiftUI

struct Message: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

struct CEAView: View {
    @State private var messages: [Message] = [
        Message(text: "Hi! I'm CEA. How can I assist you today?", isUser: false)
    ]
    @State private var input = ""
    @State private var isSending = false

    // Simulator talks to the backend on your Mac via localhost.
    private let backendURL = URL(string: "http://localhost:8000/ai/ask")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) {
                        proxy.scrollTo(messages.last?.id)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    TextField("Send to CEA", text: $input)
                        .padding(10)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))
                        .disabled(isSending)
                        .onSubmit { Task { await send() } }

                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                    }
                    .disabled(isSending || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .navigationTitle("CEA")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @MainActor
    private func send() async {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSending else { return }

        messages.append(Message(text: text, isUser: true))
        input = ""
        isSending = true
        defer { isSending = false }

        do {
            let reply = try await fetchReply(for: text)
            messages.append(Message(text: reply, isUser: false))
        } catch {
            messages.append(Message(text: "__ \(error.localizedDescription)", isUser: false))
        }
    }

    private func fetchReply(for prompt: String) async throws -> String {
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["prompt": prompt])

        let (data, response) = try await URLSession.shared.data(for: request)

        // Surface backend errors (e.g. missing API key) instead of a decode failure.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.detail
            throw CEAError.backend(detail ?? "Server error \(http.statusCode)")
        }

        return try JSONDecoder().decode(AskResponse.self, from: data).response
    }
}

private struct AskResponse: Decodable {
    let response: String
}

private struct ErrorResponse: Decodable {
    let detail: String
}

private enum CEAError: LocalizedError {
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .backend(let message): return message
        }
    }
}

private struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isUser ? Color.blue : Color(.systemGray5))
                .foregroundStyle(message.isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: 280, alignment: message.isUser ? .trailing : .leading)
            if !message.isUser { Spacer() }
        }
    }
}

#Preview {
    CEAView()
}
