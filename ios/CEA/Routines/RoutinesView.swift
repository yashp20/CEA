import MapKit
import SwiftData
import SwiftUI

/// v1.1 §3.2 — routines list: create, edit, run. Reached from the home
/// sidebar; the agent can also open a routine by name (run_routine tool).
struct RoutinesView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context
    @Query(sort: \Routine.createdAt) private var routines: [Routine]

    @State private var running: Routine?

    private var profile: AccessibilityProfile { profileStore.profile }

    var body: some View {
        List {
            if routines.isEmpty {
                Section {
                    Text("A routine is a saved set of steps you run with one tap or one sentence — like \"Going home\": ride hand-off, text your ETA, set a reminder. Every step stays visible and you confirm anything that sends or creates something.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(routines) { routine in
                Section {
                    NavigationLink {
                        RoutineEditorView(routine: routine)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routine.name)
                                .font(.body.weight(.medium))
                            Text("\(routine.steps.count) step\(routine.steps.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel("\(routine.name), \(routine.steps.count) steps. Opens the editor.")

                    Button {
                        Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
                        running = routine
                    } label: {
                        Label("Run \(routine.name)", systemImage: "play.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                    .frame(minHeight: Theme.minTapTarget - 12)
                    .accessibilityHint("Shows every step; you run each one yourself.")
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(routines[index]) }
                try? context.save()
            }
        }
        .navigationTitle("Routines")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let routine = Routine(name: "New routine")
                    context.insert(routine)
                    try? context.save()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New routine")
            }
        }
        .sheet(item: $running) { routine in
            RoutineRunView(routine: routine)
        }
    }
}

/// Edit a routine: rename, add/remove/reorder steps. Steps are added through
/// honest pickers — destinations are really geocoded, own-account tools come
/// from the user's actual Zapier server.
struct RoutineEditorView: View {
    @Bindable var routine: Routine
    @Environment(\.modelContext) private var context

    @State private var addingRide = false
    @State private var addingOwnAccount = false

    var body: some View {
        List {
            Section("Name") {
                TextField("Routine name", text: $routine.name)
                    .accessibilityLabel("Routine name")
            }

            Section {
                let steps = routine.sortedSteps
                if steps.isEmpty {
                    Text("No steps yet — add one below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(steps, id: \.persistentModelID) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.body)
                        Text(RoutineEngine.kind(of: step)?.displayName ?? step.kindRaw)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if RoutineEngine.requiresConfirmation(step) {
                            Text("Asks you to confirm before it runs.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { offsets in
                    let steps = routine.sortedSteps
                    for index in offsets { context.delete(steps[index]) }
                    reindex()
                }
                .onMove { source, destination in
                    var steps = routine.sortedSteps
                    steps.move(fromOffsets: source, toOffset: destination)
                    for (index, step) in steps.enumerated() { step.orderIndex = index }
                    try? context.save()
                }
            } header: {
                Text("Steps (run in this order)")
            }

            Section("Add a step") {
                Button {
                    addingRide = true
                } label: {
                    Label("Ride hand-off to a place", systemImage: "car")
                }
                Button {
                    addingOwnAccount = true
                } label: {
                    Label("Own-account action (message, reminder…)", systemImage: "checklist")
                }
            }
        }
        .navigationTitle(routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onDisappear { try? context.save() }
        .sheet(isPresented: $addingRide) {
            AddRideStepSheet { title, params in
                append(kind: .rideHandoff, title: title, paramsJSON: RoutineEngine.encode(params))
            }
        }
        .sheet(isPresented: $addingOwnAccount) {
            AddOwnAccountStepSheet { title, params in
                append(kind: .ownAccount, title: title, paramsJSON: RoutineEngine.encode(params))
            }
        }
    }

    private func append(kind: RoutineStepKind, title: String, paramsJSON: String) {
        let step = RoutineStep(
            orderIndex: (routine.sortedSteps.last?.orderIndex ?? -1) + 1,
            kindRaw: kind.rawValue,
            title: title,
            paramsJSON: paramsJSON
        )
        step.routine = routine
        context.insert(step)
        try? context.save()
    }

    private func reindex() {
        for (index, step) in routine.sortedSteps.enumerated() { step.orderIndex = index }
        try? context.save()
    }
}

/// Destination picker for a ride step — really geocoded via MKLocalSearch;
/// saving is only possible once a real place was found.
private struct AddRideStepSheet: View {
    var onSave: (String, RideStepParams) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var found: RideStepParams?
    @State private var foundAddress: String?
    @State private var searching = false
    @State private var errorLine: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Where to?") {
                    TextField("Place or address", text: $query)
                        .onSubmit(search)
                    Button(searching ? "Searching…" : "Find place") { search() }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let found {
                    Section("Found") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(found.destinationName).font(.body.weight(.medium))
                            if let foundAddress {
                                Text(foundAddress).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let errorLine {
                    Section {
                        Label(errorLine, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ride hand-off step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add step") {
                        if let found {
                            onSave("Ride to \(found.destinationName)", found)
                            dismiss()
                        }
                    }
                    .disabled(found == nil)
                }
            }
        }
    }

    private func search() {
        searching = true
        errorLine = nil
        Task { @MainActor in
            defer { searching = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard let item = response.mapItems.first else {
                    errorLine = "No place found for \"\(query)\". Try an address."
                    found = nil
                    return
                }
                found = RideStepParams(
                    destinationName: item.name ?? query,
                    destinationLatitude: item.placemark.coordinate.latitude,
                    destinationLongitude: item.placemark.coordinate.longitude
                )
                foundAddress = item.placemark.title
            } catch {
                errorLine = "Search failed: \(error.localizedDescription)"
                found = nil
            }
        }
    }
}

/// Own-account step editor. Tools are loaded from the user's real Zapier
/// server; without the connection this is honestly disabled.
private struct AddOwnAccountStepSheet: View {
    var onSave: (String, OwnAccountStepParams) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "message"
    @State private var summary = ""
    @State private var tools: [(name: String, description: String, schemaJSON: String)] = []
    @State private var selectedTool = ""
    @State private var argumentsJSON = ""
    @State private var loadError: String?
    @State private var loading = false

    private let kinds = ["message", "reminder", "calendar_event", "note", "list_item"]

    var body: some View {
        NavigationStack {
            Form {
                if !ZapierMCPService.isConfigured {
                    Section {
                        Label("Own-account steps need the Zapier connection, which isn't set up on this build yet.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("What kind of task?") {
                        Picker("Kind", selection: $kind) {
                            ForEach(kinds, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                        }
                    }
                    Section {
                        TextField("e.g. Text Maya: on my way, ETA 15 minutes", text: $summary, axis: .vertical)
                            .lineLimit(2...4)
                    } header: {
                        Text("What will happen (shown before it runs)")
                    }
                    Section {
                        if tools.isEmpty {
                            Button(loading ? "Loading…" : "Load tools from your Zapier") { loadTools() }
                                .disabled(loading)
                            if let loadError {
                                Text(loadError).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("Tool", selection: $selectedTool) {
                                ForEach(tools, id: \.name) { tool in
                                    Text(tool.name).tag(tool.name)
                                }
                            }
                        }
                    } header: {
                        Text("Zapier tool")
                    }
                    Section {
                        TextField("{\"message\": \"…\"}", text: $argumentsJSON, axis: .vertical)
                            .font(.caption.monospaced())
                            .lineLimit(3...6)
                    } header: {
                        Text("Arguments (JSON, optional)")
                    }
                }
            }
            .navigationTitle("Own-account step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add step") {
                        let params = OwnAccountStepParams(
                            kind: kind,
                            summary: summary,
                            toolName: selectedTool,
                            argumentsJSON: argumentsJSON.isEmpty ? nil : argumentsJSON
                        )
                        onSave(summary, params)
                        dismiss()
                    }
                    .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty || selectedTool.isEmpty)
                }
            }
        }
    }

    private func loadTools() {
        loading = true
        loadError = nil
        Task { @MainActor in
            defer { loading = false }
            do {
                tools = try await ZapierMCPService.shared.listTools()
                selectedTool = tools.first?.name ?? ""
                if tools.isEmpty { loadError = "Your Zapier server exposes no tools yet." }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
