import Foundation

enum GrammarClient {
    private static let baseURL = URL(string: "http://127.0.0.1:\(ServerManager.port)")!

    static func isHealthy(token: String) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.setValue(token, forHTTPHeaderField: "X-Grammar-Token")
        request.timeoutInterval = 1
        let response = try? await URLSession.shared.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func correct(_ text: String, token: String, settings: ModelSettings) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("correct"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Grammar-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "text": text,
            "settings": settings.request,
            "limits": ["time_limit": settings.timeLimit, "max_chars": settings.maxSelection],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = Double(settings.timeLimit) + 5
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GrammarError(message: body.isEmpty ? "grammar server error" : body)
        }
        return body
    }
}

struct GrammarError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
