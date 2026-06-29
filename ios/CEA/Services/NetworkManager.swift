import Foundation

final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    // Change to your machine's IP when running on a physical device
    private let baseURL = URL(string: "http://localhost:8000")!

    private init() {}

    // MARK: - Health

    func ping() async throws -> Bool {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appending(path: "/ping"))
        let body = try JSONDecoder().decode([String: String].self, from: data)
        return body["status"] == "ok"
    }

    // MARK: - AI

    struct AskResponse: Decodable {
        let response: String
    }

    func ask(prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/ai/ask"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["prompt": prompt])

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(AskResponse.self, from: data).response
    }

    // MARK: - Map

    struct Location: Decodable, Identifiable {
        var id: String { label }
        let latitude: Double
        let longitude: Double
        let label: String
    }

    func fetchPins() async throws -> [Location] {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appending(path: "/map/pins"))
        return try JSONDecoder().decode([Location].self, from: data)
    }
}
