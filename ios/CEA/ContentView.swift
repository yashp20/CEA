import SwiftUI

struct ContentView: View {
    @State private var status = "Not connected"

    var body: some View {
        VStack(spacing: 20) {
            Text("CEA")
                .font(.largeTitle.bold())
            Text(status)
                .foregroundStyle(.secondary)
            Button("Connect to Backend") {
                Task { await ping() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func ping() async {
        status = "Connecting…"
        do {
            let url = URL(string: "http://localhost:8000/ping")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let body = try JSONDecoder().decode([String: String].self, from: data)
            status = body["status"] == "ok" ? "Connected" : "Unexpected response"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
