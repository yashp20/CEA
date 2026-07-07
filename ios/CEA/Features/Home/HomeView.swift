import SwiftData
import SwiftUI

/// v1.1 §2 — the redesigned main screen (Claude/ChatGPT-style home):
/// no tab bar; the app opens straight into a fresh chat. Top-left opens a
/// slide-over sidebar with the full chat history; top-right is a small,
/// unobtrusive profile entry point; floating shortcut widgets sit on the
/// empty chat. The composer is ready but never auto-focused, so VoiceOver
/// and voice-first users don't get a surprise keyboard.
struct HomeView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    @State private var activeSession: ChatSession?
    @State private var sidebarOpen = false
    @State private var focusMode = false

    private var profile: AccessibilityProfile { profileStore.profile }
    private var reduceMotion: Bool {
        EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                Group {
                    if let session = activeSession {
                        ChatView(session: session, showsShortcuts: true)
                    } else {
                        // One frame at startup before the session exists.
                        Color.clear
                    }
                }
                .accessibilityHidden(sidebarOpen)

                if sidebarOpen {
                    // Scrim: tap anywhere outside the panel to close.
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { closeSidebar() }
                        .accessibilityLabel("Close chat list")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)

                    ChatSidebar(
                        activeSession: $activeSession,
                        onClose: { closeSidebar() }
                    )
                    .frame(width: 300)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }
            }
            .animation(Motion.spring(reduceMotion: reduceMotion), value: sidebarOpen)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
                        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                            sidebarOpen.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel(sidebarOpen ? "Close chat list" : "Open chat list")
                    .accessibilityHint("All your previous chats")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: startNewChat) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // §3.4: one tap collapses everything to the next step.
                    Button {
                        Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
                        focusMode = true
                    } label: {
                        Image(systemName: "rectangle.compress.vertical")
                    }
                    .disabled(activeSession == nil)
                    .accessibilityLabel("Focus mode")
                    .accessibilityHint("Shows just the next step, one button, big text.")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Small, transparent profile entry point (§2): icon only,
                    // no background — unobtrusive but 44pt and labeled.
                    NavigationLink {
                        ProfileView()
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(Theme.brandGradient(highContrast: profile.highContrast))
                    }
                    .accessibilityLabel("Profile and settings")
                }
            }
        }
        .fullScreenCover(isPresented: $focusMode) {
            if let session = activeSession {
                FocusModeView(session: session, onExit: { focusMode = false })
            }
        }
        .onAppear { ensureFreshSession() }
    }

    private var title: String {
        guard let session = activeSession, session.title != "New chat" else { return "CEA" }
        return session.title
    }

    /// Home opens with a fresh chat ready (§2). Reuses an existing empty
    /// session rather than piling up blanks.
    private func ensureFreshSession() {
        guard activeSession == nil else { return }
        if let empty = sessions.first(where: { $0.messages.isEmpty }) {
            activeSession = empty
        } else {
            startNewChat()
        }
    }

    private func startNewChat() {
        if let current = activeSession, current.messages.isEmpty {
            activeSession = current // already fresh; don't create blanks
            closeSidebar()
            return
        }
        let session = ChatSession()
        context.insert(session)
        try? context.save()
        activeSession = session
        closeSidebar()
    }

    private func closeSidebar() {
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            sidebarOpen = false
        }
    }
}

/// Slide-over sidebar (§2): the full chat history, swipe-to-delete, and a
/// new-chat entry — what the old Chats tab provided, one tap from home.
struct ChatSidebar: View {
    @Binding var activeSession: ChatSession?
    var onClose: () -> Void

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    private var profile: AccessibilityProfile { profileStore.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    let session = ChatSession()
                    context.insert(session)
                    try? context.save()
                    activeSession = session
                    onClose()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                }
                .accessibilityLabel("New chat")
            }
            .padding(.horizontal)
            .padding(.top, 12)

            if sessions.isEmpty {
                Text("No chats yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List {
                    ForEach(sessions) { session in
                        Button {
                            activeSession = session
                            onClose()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .font(.body.weight(session == activeSession ? .semibold : .regular))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityLabel("\(session.title), \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))\(session == activeSession ? ", current chat" : "")")
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.screenBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat list")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            if session == activeSession { activeSession = nil }
            context.delete(session)
        }
        try? context.save()
        // Never leave home without a chat.
        if activeSession == nil {
            let session = ChatSession()
            context.insert(session)
            try? context.save()
            activeSession = session
        }
    }
}
