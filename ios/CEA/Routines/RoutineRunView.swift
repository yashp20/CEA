import CoreLocation
import SwiftData
import SwiftUI

/// v1.1 §3.2 — runs a routine one visible step at a time. The whole plan is
/// shown before anything executes; steps run strictly in order; every
/// side-effect step (own-account) requires its own explicit Confirm; ride
/// steps stay hand-offs (buttons that open Uber/Lyft with the trip
/// pre-filled). Nothing ever runs implicitly.
struct RoutineRunView: View {
    let routine: Routine

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum StepState: Equatable {
        case pending
        case working
        /// Ride links built and waiting for the user to pick an app.
        case rideReady(uberURL: URL, lyftURL: URL, uberDetail: String)
        case done(String)
        case failed(String)
        case skipped
    }

    @State private var states: [Int: StepState] = [:]

    private var profile: AccessibilityProfile { profileStore.profile }
    private var reduceMotion: Bool {
        EffectiveReduceMotion(system: systemReduceMotion, profile: profile.reduceMotion).isOn
    }
    private var steps: [RoutineStep] { routine.sortedSteps }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    Text("Each step below runs only when you tap it, in order. Steps that send or create something ask you to confirm first.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(Array(steps.enumerated()), id: \.element.persistentModelID) { position, step in
                        stepCard(position: position, step: step)
                    }

                    if steps.isEmpty {
                        Text("This routine has no steps yet. Edit it to add some.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .background(Theme.screenBackground)
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close routine")
                }
            }
        }
    }

    // MARK: Step card

    @ViewBuilder
    private func stepCard(position: Int, step: RoutineStep) -> some View {
        let state = states[step.orderIndex] ?? .pending
        let unlocked = isUnlocked(position: position)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(position + 1).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accent(highContrast: profile.highContrast))
                Text(step.title)
                    .font(.headline)
                Spacer(minLength: 0)
                stateBadge(state)
            }

            if RoutineEngine.requiresConfirmation(step),
               let params = RoutineEngine.ownAccountParams(step) {
                Text("Will do: \(params.summary)")
                    .font(.subheadline)
                Text("Runs through your own connected account (Zapier) after you confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch state {
            case .pending:
                if unlocked { pendingControls(for: step) }
                else {
                    Text("Finish the step above first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .working:
                ProgressView().padding(.vertical, 4)
            case .rideReady(let uberURL, let lyftURL, let detail):
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Theme.spacing) {
                    rideButton("Open Uber", url: uberURL, step: step)
                    rideButton("Open Lyft", url: lyftURL, step: step)
                }
                skipButton(step)
            case .done(let line):
                Label(line, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.positive(for: profile.colorBlindType, highContrast: profile.highContrast))
            case .failed(let line):
                Label(line, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.caution(for: profile.colorBlindType, highContrast: profile.highContrast))
                if unlocked { pendingControls(for: step) }
            case .skipped:
                Label("Skipped.", systemImage: "arrow.right.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .ceaCard(highContrast: profile.highContrast)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(position + 1): \(step.title)")
    }

    @ViewBuilder
    private func pendingControls(for step: RoutineStep) -> some View {
        HStack(spacing: Theme.spacing) {
            Button {
                run(step)
            } label: {
                Text(RoutineEngine.requiresConfirmation(step) ? "Confirm & run" : "Run step")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .frame(minHeight: Theme.minTapTarget)
            }
            .background(Theme.brandGradient(highContrast: profile.highContrast), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
            .foregroundStyle(.white)
            .accessibilityHint(RoutineEngine.requiresConfirmation(step)
                               ? "Runs the action through your Zapier account."
                               : "Prepares ride links. You request the ride in the app that opens.")
            skipButton(step)
        }
    }

    private func skipButton(_ step: RoutineStep) -> some View {
        Button {
            states[step.orderIndex] = .skipped
            Haptics.shared.play(.tap, enabled: profile.hapticsEnabled)
        } label: {
            Text("Skip")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: Theme.minTapTarget)
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
        .foregroundStyle(.primary)
        .accessibilityLabel("Skip this step")
    }

    private func rideButton(_ label: String, url: URL, step: RoutineStep) -> some View {
        Button {
            Haptics.shared.play(.confirmed, enabled: profile.hapticsEnabled)
            openURL(url)
            states[step.orderIndex] = .done("Opened — you confirm the ride there.")
        } label: {
            Text(label)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .frame(minHeight: Theme.minTapTarget)
        }
        .background(Theme.brandGradient(highContrast: profile.highContrast), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4))
        .foregroundStyle(.white)
        .accessibilityLabel("\(label). Opens with your trip pre-filled; you confirm and request there.")
    }

    private func stateBadge(_ state: StepState) -> some View {
        Group {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill")
            case .skipped: Image(systemName: "arrow.right.circle")
            case .failed: Image(systemName: "exclamationmark.triangle")
            default: EmptyView()
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    // MARK: Execution

    private func isUnlocked(position: Int) -> Bool {
        guard position > 0 else { return true }
        return steps[..<position].allSatisfy { step in
            switch states[step.orderIndex] ?? .pending {
            case .done, .skipped: return true
            default: return false
            }
        }
    }

    private func run(_ step: RoutineStep) {
        switch RoutineEngine.kind(of: step) {
        case .rideHandoff:
            runRideStep(step)
        case .ownAccount:
            runOwnAccountStep(step)
        case nil:
            states[step.orderIndex] = .failed("This step type isn't supported.")
        }
    }

    private func runRideStep(_ step: RoutineStep) {
        guard let params = RoutineEngine.rideParams(step) else {
            states[step.orderIndex] = .failed("This step is missing its destination.")
            return
        }
        states[step.orderIndex] = .working
        Task { @MainActor in
            do {
                let location = try await LocationService.shared.currentLocation()
                let pickup = RidePoint(
                    latitude: LocationService.coarse(location.coordinate.latitude),
                    longitude: LocationService.coarse(location.coordinate.longitude),
                    nickname: "Current location",
                    formattedAddress: nil
                )
                let links = RoutineEngine.rideLinks(for: params, pickup: pickup)
                states[step.orderIndex] = .rideReady(
                    uberURL: links.uber.preferredURL(),
                    lyftURL: links.lyft.preferredURL(),
                    uberDetail: "Trip to \(params.destinationName) pre-filled. CEA never books — you confirm in the app."
                )
                Haptics.shared.play(.needsInput, enabled: profile.hapticsEnabled)
            } catch {
                states[step.orderIndex] = .failed(error.localizedDescription)
                Haptics.shared.play(.headsUp, enabled: profile.hapticsEnabled)
            }
        }
    }

    private func runOwnAccountStep(_ step: RoutineStep) {
        guard let params = RoutineEngine.ownAccountParams(step) else {
            states[step.orderIndex] = .failed("This step is missing its details.")
            return
        }
        guard ZapierMCPService.isConfigured else {
            states[step.orderIndex] = .failed("Own-account actions need the Zapier connection, which isn't set up yet.")
            return
        }
        states[step.orderIndex] = .working
        Task { @MainActor in
            do {
                let result = try await ZapierMCPService.shared.callTool(
                    name: params.toolName,
                    argumentsJSON: params.argumentsJSON
                )
                states[step.orderIndex] = .done("Done. \(result)")
                Haptics.shared.play(.confirmed, enabled: profile.hapticsEnabled)
            } catch {
                states[step.orderIndex] = .failed(error.localizedDescription)
                Haptics.shared.play(.headsUp, enabled: profile.hapticsEnabled)
            }
        }
    }
}
