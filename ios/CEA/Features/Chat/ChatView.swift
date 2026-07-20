import SwiftData
import SwiftUI
import UIKit

/// The conversation screen (PRD F2). Messages persist to SwiftData; the
/// agent runs the client-side tool loop and streams events back.
struct ChatView: View {
    @Bindable var session: ChatSession
    /// Home shows floating shortcut widgets on the empty state (§2).
    var showsShortcuts = false
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.openURL) private var openURL

    @State private var input = ""
    @State private var isSending = false
    /// The assistant message currently receiving streamed text (§3.5).
    @State private var streamingMessage: ChatMessage?
    /// Routine opened by the agent's run_routine tool (§3.2).
    @State private var routineToRun: Routine?

    private var profile: AccessibilityProfile { profileStore.profile }
    private var reduceMotion: Bool {
        EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spacing) {
                        if session.messages.isEmpty {
                            emptyState
                        }
                        ForEach(session.sortedMessages) { message in
                            MessageRow(
                                message: message,
                                profile: profile,
                                reduceMotion: reduceMotion,
                                onOpenURL: { open($0) }
                            )
                            .id(message.persistentModelID)
                            .transition(Motion.insertion(reduceMotion: reduceMotion))
                        }
                        if isSending && streamingMessage == nil {
                            // Instant acknowledgment (§3.5): visible the moment
                            // input is received, before the first token.
                            ThinkingIndicator(reduceMotion: reduceMotion)
                        }
                    }
                    .padding()
                    .animation(Motion.spring(reduceMotion: reduceMotion), value: session.messages.count)
                }
                .onChange(of: session.messages.count) {
                    if let last = session.sortedMessages.last {
                        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                            proxy.scrollTo(last.persistentModelID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: streamingMessage?.text) {
                    if let streaming = streamingMessage {
                        proxy.scrollTo(streaming.persistentModelID, anchor: .bottom)
                    }
                }
            }

            Divider()

            InputBar(
                text: $input,
                voiceFirst: profile.voiceFirst,
                highContrast: profile.highContrast,
                reduceMotion: reduceMotion,
                isSending: isSending,
                onSend: send
            )
        }
        .background(Theme.screenBackground)
        // §1 bug 4: TTS is scoped to the visible chat — leaving the screen
        // stops speech immediately instead of reading into the next screen.
        .onDisappear { SpeechService.shared.stop() }
        .sheet(item: $routineToRun) { routine in
            RoutineRunView(routine: routine)
        }
    }

    /// Opens a hand-off URL and counts it toward shortcut personalization.
    private func open(_ url: URL) {
        ShortcutUsageTracker.recordHandoff(url: url, in: context)
        openURL(url)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(Theme.brandGradient(highContrast: profile.highContrast))
                .accessibilityHidden(true)
            Text("Ask for a ride or food nearby.")
                .font(.headline)
            Text(profile.voiceFirst
                 ? "Tap the mic and say, for example, \"Get me a ride to the station.\""
                 : "For example: \"Indian food nearby, step-free.\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsShortcuts {
                // §3.1: the deferred survey appears here — a fresh chat is
                // the natural, low-pressure moment; never mid-task.
                if let survey = SurveyLogic.eligibleSurvey(from: profileStore.pendingSurveys(), profile: profile) {
                    SurveyPromptCard(survey: survey)
                        .padding(.top, 16)
                }
                ShortcutStrip(
                    profile: profile,
                    reduceMotion: reduceMotion,
                    onSeed: { seed in
                        input = seed
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Request started in the message box. Finish it and send."
                        )
                    }
                )
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityElement(children: .contain)
    }

    // MARK: Sending

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        input = ""

        let history = session.sortedMessages
        append(ChatMessage(role: .user, text: text))
        // Reliable silent memory: a dedicated pass extracts durable facts from
        // every message and saves them, so memory doesn't depend on the main
        // agent remembering to call the tool. Runs in parallel; never blocks.
        Task { await MemoryExtractor.extract(from: text, into: profileStore) }
        if session.title == "New chat" {
            session.title = String(text.prefix(40))
        }
        session.updatedAt = .now
        isSending = true

        // Instant acknowledgment (§3.5): haptic + visible indicator + spoken
        // announcement fire the moment input is received — no silent dead air.
        Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
        UIAccessibility.post(notification: .announcement, argument: "Heard you — working on it.")
        SpeechService.shared.beginStreamingTurn(
            spokenResponsesEnabled: profile.spokenResponses || profile.voiceFirst
        )

        Task { @MainActor in
            defer {
                isSending = false
                streamingMessage = nil
            }
            let client = AgentClient(profileStore: profileStore)
            do {
                try await client.send(userText: text, history: history) { event in
                    switch event {
                    case .assistantDelta(let full):
                        if let streaming = streamingMessage {
                            streaming.text = full
                        } else {
                            let message = ChatMessage(role: .assistant, text: full)
                            append(message)
                            streamingMessage = message
                        }
                        SpeechService.shared.ingestStreaming(fullText: full)
                    case .assistantText(let reply):
                        if let streaming = streamingMessage {
                            streaming.text = reply
                            streamingMessage = nil
                        } else {
                            append(ChatMessage(role: .assistant, text: reply))
                        }
                        SpeechService.shared.finishStreamingMessage(finalText: reply)
                    case .card(let card):
                        let json = (try? JSONEncoder().encode(card)).flatMap { String(data: $0, encoding: .utf8) }
                        append(ChatMessage(role: .assistant, text: "", cardJSON: json))
                        // A card usually asks the user to choose — "your turn".
                        Haptics.shared.play(.needsInput, enabled: profile.hapticsEnabled)
                    case .notice(let line):
                        append(ChatMessage(role: .notice, text: line))
                        Haptics.shared.play(.confirmed, enabled: profile.hapticsEnabled)
                    case .startRoutine(let routine):
                        append(ChatMessage(role: .notice, text: "Opening routine: \(routine.name). Every step waits for you."))
                        routineToRun = routine
                        Haptics.shared.play(.needsInput, enabled: profile.hapticsEnabled)
                    }
                }
            } catch {
                // Honest failure state — no pretend answers.
                append(ChatMessage(role: .notice, text: error.localizedDescription))
                Haptics.shared.play(.headsUp, enabled: profile.hapticsEnabled)
            }
            try? context.save()
        }
    }

    private func append(_ message: ChatMessage) {
        message.session = session
        context.insert(message)
        session.updatedAt = .now
    }
}
