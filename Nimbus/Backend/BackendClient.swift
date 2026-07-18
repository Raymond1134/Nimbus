// BackendClient.swift — Nimbus
// Calls the Python FastAPI backend (backend/main.py).
//
// Configure the server address by adding  BACKEND_BASE_URL = http://<host>:8000
// to your Secrets.xcconfig (never commit that file — it is gitignored).

import Foundation

// MARK: - Error

enum BackendError: LocalizedError {
    case httpError(Int, String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "Backend HTTP \(code): \(body.prefix(200))"
        case .decodingFailed(let detail):
            return "Decoding failed: \(detail)"
        }
    }
}

// MARK: - Client

enum BackendClient {

    // MARK: - URL

    /// Resolved from `BACKEND_BASE_URL` in Info.plist (set via Secrets.xcconfig).
    /// Falls back to localhost:8000 for simulator testing.
    static var baseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String
                  ?? "http://localhost:8000"
        return URL(string: raw.trimmingCharacters(in: .whitespaces))
               ?? URL(string: "http://localhost:8000")!
    }

    // MARK: - /voice_command  (transcript + frame → intent + grounding in one call)

    /// Sends transcript and the latest drone camera frame to the backend.
    /// Returns a combined intent + grounding response.
    ///
    /// The backend (backend/main.py) calls the mock/real FreeSolo intent parser
    /// then Gemini Flash for visual grounding — all in one HTTP round-trip.
    static func processVoiceCommand(
        transcript: String,
        imageData: Data,
        mimeType: String = "image/jpeg"
    ) async throws -> BackendVoiceCommandResponse {

        let url = baseURL.appendingPathComponent("voice_command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()

        // transcript field
        body.appendFormField(name: "transcript", value: transcript, boundary: boundary)

        // image field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(imageData)
        body.append("\r\n")

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code    = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyStr = String(data: data, encoding: .utf8) ?? "(no body)"
            throw BackendError.httpError(code, bodyStr)
        }

        do {
            return try JSONDecoder().decode(BackendVoiceCommandResponse.self, from: data)
        } catch {
            throw BackendError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - /health

    static func checkHealth() async -> Bool {
        let url = baseURL.appendingPathComponent("health")
        guard let (_, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
