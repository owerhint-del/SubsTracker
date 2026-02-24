import Foundation

/// Fetches usage data from the OpenAI API
final class OpenAIUsageService {
    static let shared = OpenAIUsageService()

    private let baseURL = "https://api.openai.com/v1/organization/usage"
    private let session = URLSession.shared

    private init() {}

    // MARK: - Public API

    /// Fetch daily usage from OpenAI for a date range
    func fetchUsage(
        from startDate: Date,
        to endDate: Date = Date()
    ) async throws -> [OpenAIDailyUsage] {
        guard let apiKey = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey),
              !apiKey.isEmpty else {
            throw OpenAIError.noAPIKey
        }

        let startStr = SharedDateFormatter.yyyyMMdd.string(from: startDate)
        let endStr = SharedDateFormatter.yyyyMMdd.string(from: endDate)

        guard var components = URLComponents(string: baseURL) else {
            throw OpenAIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "start_date", value: startStr),
            URLQueryItem(name: "end_date", value: endStr)
        ]

        guard let url = components.url else {
            throw OpenAIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
            return decoded.data
        case 401:
            throw OpenAIError.unauthorized
        case 429:
            throw OpenAIError.rateLimited
        default:
            throw OpenAIError.httpError(httpResponse.statusCode)
        }
    }

    /// Check if an API key is configured
    var hasAPIKey: Bool {
        guard let key = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey) else {
            return false
        }
        return !key.isEmpty
    }
}

// MARK: - Response Models

struct OpenAIUsageResponse: Codable {
    let data: [OpenAIDailyUsage]
}

struct OpenAIDailyUsage: Codable, Identifiable {
    var id: String { date }
    let date: String
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let numRequests: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case numRequests = "num_requests"
        case cost
    }

    var totalTokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    var parsedDate: Date? {
        SharedDateFormatter.yyyyMMdd.date(from: date)
    }
}

// MARK: - Errors

enum OpenAIError: LocalizedError {
    case noAPIKey
    case invalidURL
    case invalidResponse
    case unauthorized
    case rateLimited
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No OpenAI API key configured. Add one in Settings."
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from OpenAI"
        case .unauthorized:
            return "Invalid API key. Please check your OpenAI API key in Settings."
        case .rateLimited:
            return "Rate limited by OpenAI. Please try again later."
        case .httpError(let code):
            return "OpenAI API error (HTTP \(code))"
        }
    }
}
