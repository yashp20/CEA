import SwiftData
import SwiftUI

@main
struct CEAApp: App {
    private let container: ModelContainer
    @State private var profileStore: ProfileStore

    init() {
        do {
            let container = try ModelContainer(
                for: AccessibilityProfile.self, PreferenceMemory.self, ChatSession.self, ChatMessage.self,
                ShortcutUsage.self, Routine.self, RoutineStep.self
            )
            self.container = container
            self._profileStore = State(initialValue: ProfileStore(context: container.mainContext))
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(profileStore)
        }
        .modelContainer(container)
    }
}
