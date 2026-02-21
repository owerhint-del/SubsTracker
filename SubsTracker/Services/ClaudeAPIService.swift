import Foundation
import Security

/// Fetches real-time Claude usage data via Anthropic's OAuth API.
/// Reads credentials from ~/.claude/.credentials.json or macOS Keychain.
final class ClaudeAPIService {
    static let shared = ClaudeAPIService()

    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers"
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let credentialsPath: String

    private init() {
        credentialsPath = "\(NSHomeDirectory())/.claude/.credentials.json"
    }

    // MARK: - Public API

    /// Fetch current usage data. Returns nil if not logged in.
    func fetchUsage() async -> ClaudeAPIUsageResult {
        // Load credentials
        guard var credentials = loadCredentials() else {
            return .notLoggedIn
        }

        // Refresh token if needed
        if credentials.isExpired {
            do {
                credentials = try await refreshToken(credentials)
            } catch {
                return .error("Token refresh failed: \(error.localizedDescription)")
            }
        }

        // Call usage API
        do {
            let usage = try await callUsageAPI(accessToken: credentials.accessToken)
            return .success(usage)
        } catch let error as ClaudeAPIError {
            if case .authNotSupported = error {
                return .unavailable
            }
            return .error(error.localizedDescription)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Credential Loading

    private func loadCredentials() -> ClaudeCredentials? {
        // Try file first
        if let creds = loadFromFile() { return creds }
        // Fall back to keychain
        return loadFromKeychain()
    }

    private func loadFromFile() -> ClaudeCredentials? {
        let url = URL(fileURLWithPath: credentialsPath)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parseCredentials(from: data)
    }

    private func loadFromKeychain() -> ClaudeCredentials? {
        guard let jsonString = KeychainService.shared.readExternalService("Claude Code-credentials") else {
            return nil
        }
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return parseCredentials(from: data)
    }

    private func parseCredentials(from data: Data) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String,
              let expiresAt = oauth["expiresAt"] as? Double else {
            return nil
        }

        let subscriptionType = oauth["subscriptionType"] as? String

        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: expiresAt,
            subscriptionType: subscriptionType
        )
    }

    // MARK: - Token Refresh

    private func refreshToken(_ credentials: ClaudeCredentials) async throws -> ClaudeCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": clientId,
            "scope": scopes
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw ClaudeAPIError.tokenRefreshFailed(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw ClaudeAPIError.parseError("Invalid token refresh response")
        }

        let newExpiresAtMs = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        let newCredentials = ClaudeCredentials(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            expiresAtMs: newExpiresAtMs,
            subscriptionType: credentials.subscriptionType
        )

        // Save refreshed credentials back to file
        saveCredentials(newCredentials)

        return newCredentials
    }

    private func saveCredentials(_ credentials: ClaudeCredentials) {
        let oauth: [String: Any] = [
            "accessToken": credentials.accessToken,
            "refreshToken": credentials.refreshToken,
            "expiresAt": credentials.expiresAtMs
        ]
        // Preserve subscriptionType if present
        var oauthDict = oauth
        if let sub = credentials.subscriptionType {
            oauthDict["subscriptionType"] = sub
        }

        let root: [String: Any] = ["claudeAiOauth": oauthDict]

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: []) else { return }

        let url = URL(fileURLWithPath: credentialsPath)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Usage API

    private func callUsageAPI(accessToken: String) async throws -> ClaudeAPIUsage {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("SubsTracker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.networkError("Invalid response")
        }

        // Check for auth not supported error
        if httpResponse.statusCode == 400 || httpResponse.statusCode == 403 {
            if let body = String(data: data, encoding: .utf8),
               body.contains("not supported") || body.contains("not_supported") {
                throw ClaudeAPIError.authNotSupported
            }
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.apiError(httpResponse.statusCode, body)
        }

        return try parseUsageResponse(data)
    }

    private func parseUsageResponse(_ data: Data) throws -> ClaudeAPIUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.parseError("Invalid JSON response")
        }

        let fiveHour = parseUtilizationWindow(json["five_hour"])
        let sevenDay = parseUtilizationWindow(json["seven_day"])
        let sevenDaySonnet = parseUtilizationWindow(json["seven_day_sonnet"])
        let sevenDayOpus = parseUtilizationWindow(json["seven_day_opus"])

        var extraUsage: ClaudeExtraUsage?
        if let extra = json["extra_usage"] as? [String: Any] {
            extraUsage = ClaudeExtraUsage(
                isEnabled: extra["is_enabled"] as? Bool ?? false,
                usedCreditsCents: extra["used_credits"] as? Int ?? 0,
                monthlyLimitCents: extra["monthly_limit"] as? Int ?? 0,
                currency: extra["currency"] as? String ?? "USD"
            )
        }

        return ClaudeAPIUsage(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDaySonnet: sevenDaySonnet,
            sevenDayOpus: sevenDayOpus,
            extraUsage: extraUsage
        )
    }

    private func parseUtilizationWindow(_ value: Any?) -> UtilizationWindow? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? Double else {
            return nil
        }

        var resetsAt: Date?
        if let dateString = dict["resets_at"] as? String {
            resetsAt = parseISO8601(dateString)
        }

        return UtilizationWindow(utilization: utilization, resetsAt: resetsAt)
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        // Retry without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Data Types

struct ClaudeCredentials {
    let accessToken: String
    let refreshToken: String
    let expiresAtMs: Double
    let subscriptionType: String?

    var isExpired: Bool {
        // 5-minute buffer before actual expiry
        let bufferMs: Double = 5 * 60 * 1000
        return Date().timeIntervalSince1970 * 1000 >= (expiresAtMs - bufferMs)
    }
}

struct UtilizationWindow {
    let utilization: Double
    let resetsAt: Date?
}

struct ClaudeExtraUsage {
    let isEnabled: Bool
    let usedCreditsCents: Int
    let monthlyLimitCents: Int
    let currency: String

    var usedDollars: Double { Double(usedCreditsCents) / 100.0 }
    var monthlyLimitDollars: Double { Double(monthlyLimitCents) / 100.0 }
    var hasLimit: Bool { monthlyLimitCents > 0 }
}

struct ClaudeAPIUsage {
    let fiveHour: UtilizationWindow?
    let sevenDay: UtilizationWindow?
    let sevenDaySonnet: UtilizationWindow?
    let sevenDayOpus: UtilizationWindow?
    let extraUsage: ClaudeExtraUsage?
}

enum ClaudeAPIUsageResult {
    case success(ClaudeAPIUsage)
    case unavailable       // API returns "auth not supported"
    case notLoggedIn       // No credentials found
    case error(String)     // Other errors

    var usage: ClaudeAPIUsage? {
        if case .success(let usage) = self { return usage }
        return nil
    }

    var isAvailable: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Errors

enum ClaudeAPIError: LocalizedError {
    case authNotSupported
    case tokenRefreshFailed(Int)
    case apiError(Int, String)
    case networkError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .authNotSupported:
            return "OAuth authentication is currently not supported by Anthropic"
        case .tokenRefreshFailed(let code):
            return "Token refresh failed (HTTP \(code))"
        case .apiError(let code, let body):
            return "API error (HTTP \(code)): \(body)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        }
    }
}
