import SwiftData
import SwiftUI

/// v1.1 §2 — the redesigned main screen (Claude/ChatGPT-style home):
/// no tab bar; the app opens straight into a fresh chat. Top-left opens a
/// slide-over sidebar with the full chat history; top-right is a small,
/// unobtrusive profile entry point; floating shortcut widgets sit on the
/// empty chat. The composer is ready but never auto-focused, so VoiceOver
/// and voice-first users don't get a surprise keyboard.
///
/// Layering (v1.1 revision, bug 2): the sidebar lives OUTSIDE the
/// NavigationStack, so it slides over the toolbar too; everything behind it
/// blurs and dims, and the panel's trailing edge is rounded.
struct HomeView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    @State private var activeSession: ChatSession?
    @State private var sidebarOpen = false
    @State private var focusMode = false
    @State private var showRoutines = false

    private var profile: AccessibilityProfile { profileStore.profile }
    private var reduceMotion: Bool {
        EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn
    }

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                Group {
                    if let session = activeSession {
                        ChatView(session: session, showsShortcuts: true)
                    } else {
                        // One frame at startup before the session exists.
                        Color.clear
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(isPresented: $showRoutines) {
                    RoutinesView()
                }
            }
            // Everything — toolbar included — sits behind the sidebar,
            // blurred and untouchable while it's open.
            .blur(radius: sidebarOpen ? 8 : 0)
            .allowsHitTesting(!sidebarOpen)
            .accessibilityHidden(sidebarOpen)

            if sidebarOpen {
                // Scrim: tap anywhere outside the panel to close.
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { closeSidebar() }
                    .accessibilityLabel("Close chat list")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)

                ChatSidebar(
                    activeSession: $activeSession,
                    onClose: { closeSidebar() },
                    onNewChat: {
                        startNewChat()
                        closeSidebar()
                    },
                    onOpenRoutines: {
                        closeSidebar()
                        showRoutines = true
                    }
                )
                .frame(width: 300)
                .background {
                    // Rounded trailing edge, full height under the bars.
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 28, topTrailingRadius: 28
                    )
                    .fill(Theme.screenBackground)
                    .ignoresSafeArea()
                    .shadow(color: .black.opacity(0.22), radius: 18, x: 6, y: 0)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .leading))
            }
        }
        .animation(Motion.spring(reduceMotion: reduceMotion), value: sidebarOpen)
        .fullScreenCover(isPresented: $focusMode) {
            if let session = activeSession {
                FocusModeView(session: session, onExit: { focusMode = false })
            }
        }
        .onAppear { ensureFreshSession() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    private var title: String {
        guard let session = activeSession, session.title != "New chat" else { return "CEA" }
        return session.title
    }

    /// Home opens with a fresh chat ready (§2). Reuses an existing blank
    /// session and purges redundant blanks (bug 3) — the list never fills
    /// with "New chat" entries.
    private func ensureFreshSession() {
        if activeSession == nil {
            activeSession = SessionHousekeeping.reusableEmpty(sessions) ?? makeSession()
        }
        purgeRedundantEmpties()
    }

    /// Routes back to an existing blank chat instead of minting duplicates.
    private func startNewChat() {
        if let current = activeSession, current.messages.isEmpty {
            // Already on a fresh chat — nothing to create.
        } else if let existing = SessionHousekeeping.reusableEmpty(sessions) {
            activeSession = existing
        } else {
            activeSession = makeSession()
        }
        purgeRedundantEmpties()
        closeSidebar()
    }

    private func makeSession() -> ChatSession {
        let session = ChatSession()
        context.insert(session)
        try? context.save()
        return session
    }

    private func purgeRedundantEmpties() {
        let redundant = SessionHousekeeping.redundantEmpties(sessions, keeping: activeSession)
        guard !redundant.isEmpty else { return }
        for session in redundant { context.delete(session) }
        try? context.save()
    }

    private func closeSidebar() {
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            sidebarOpen = false
        }
    }
}

/// Slide-over sidebar (§2): the chat history (blank placeholders hidden),
/// swipe-to-delete, new-chat, and Routines — rounded, inset rows for the
/// slick look (bug 2).
struct ChatSidebar: View {
    @Binding var activeSession: ChatSession?
    var onClose: () -> Void
    var onNewChat: () -> Void
    var onOpenRoutines: () -> Void

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    private var profile: AccessibilityProfile { profileStore.profile }
    private var listed: [ChatSession] { SessionHousekeeping.listable(sessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                }
                .accessibilityLabel("New chat")
            }
            .padding(.horizontal)
            .padding(.top, 12)

            List {
                Section {
                    Button(action: onOpenRoutines) {
                        Label("Routines", systemImage: "list.bullet.rectangle")
                            .font(.body.weight(.medium))
                            .frame(minHeight: Theme.minTapTarget - 12)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Saved multi-step flows you run with one tap.")
                }

                Section {
                    if listed.isEmpty {
                        Text("No chats yet — your conversations will show up here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(listed, id: \.persistentModelID) { session in
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
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat list")
    }

    private func delete(at offsets: IndexSet) {
        let visible = listed
        for index in offsets {
            let session = visible[index]
            if session == activeSession { activeSession = nil }
            context.delete(session)
        }
        try? context.save()
        // Never leave home without a chat.
        if activeSession == nil {
            if let empty = SessionHousekeeping.reusableEmpty(sessions) {
                activeSession = empty
            } else {
                let session = ChatSession()
                context.insert(session)
                try? context.save()
                activeSession = session
            }
        }
    }
}
