import SwiftUI

struct Message: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

struct CEAView: View {
    @State private var messages: [Message] = [
        Message(text: "Hi! I'm CEA. How can I help you today?", isUser: false)
    ]
    @State private var input = ""

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

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .navigationTitle("CEA")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messages.append(Message(text: text, isUser: true))
        input = ""

        // Placeholder response — replace with backend call when API key is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            messages.append(Message(text: "Got it! AI responses coming soon.", isUser: false))
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
