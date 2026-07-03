import SwiftData
import SwiftUI

/// The Chats list surface (per the CEA Figma: previous errands like
/// "Uber Eats Order", "Best route to Starbucks"), plus a prominent new-chat
/// entry point.
struct ChatsListView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    @State private var path = NavigationPath()

    private var profile: AccessibilityProfile { profileStore.profile }
    private var reduceMotion: Bool {
        EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink(value: session.persistentModelID) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(2)
                                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .accessibilityLabel("\(session.title), \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Theme.screenBackground)
            .navigationTitle("Chats")
            .navigationDestination(for: PersistentIdentifier.self) { id in
                if let session = context.model(for: id) as? ChatSession {
                    ChatView(session: session)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: newChat) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Theme.brandGradient(highContrast: profile.highContrast))
                .accessibilityHidden(true)
            Text("One conversation instead of eight apps.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("CEA finds rides and food for you, then hands off to the real app. You always confirm the final step.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: newChat) {
                Label("Start a chat", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .frame(minHeight: Theme.minTapTarget)
            }
            .background(Theme.brandGradient(highContrast: profile.highContrast), in: Capsule())
            .foregroundStyle(.white)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func newChat() {
        let session = ChatSession()
        context.insert(session)
        try? context.save()
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            path.append(session.persistentModelID)
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(sessions[index])
        }
        try? context.save()
    }
}
