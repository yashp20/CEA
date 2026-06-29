import SwiftUI

struct ContentView: View {
    @StateObject private var network = NetworkManager.shared
    @State private var status: String = "Tap to ping the server"

    var body: some View {
        VStack(spacing: 24) {
            Text("CEA")
                .font(.largeTitle.bold())

            Text(status)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Ping Backend") {
                Task { await ping() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func ping() async {
        status = "Pinging…"
        do {
            let ok = try await network.ping()
            status = ok ? "Connected" : "Unexpected response"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
