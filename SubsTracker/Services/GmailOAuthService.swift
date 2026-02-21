import Foundation
import Network
import AppKit

// MARK: - Errors

enum GmailOAuthError: LocalizedError {
    case noCredentials
    case authFailed(String)
    case invalidResponse
    case tokenRefreshFailed
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Gmail client ID or secret not configured"
        case .authFailed(let msg):
            return "Authentication failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from Google"
        case .tokenRefreshFailed:
            return "Failed to refresh access token — try reconnecting"
        case .apiError(let code, let msg):
            return "Gmail API error (\(code)): \(msg)"
        }
    }
}

// MARK: - Gmail OAuth Service

@MainActor
@Observable
final class GmailOAuthService {
    static let shared = GmailOAuthService()

    var isConnected: Bool = false
    var connectedEmail: String?
    var isAuthenticating: Bool = false
    var errorMessage: String?

    private let baseURL = "https://gmail.googleapis.com/gmail/v1"
    private var oauthListener: NWListener?

    private init() {
        importCredentialsFromTGAssist()
        loadConnectionState()
    }

    // MARK: - Import from TGAssist

    /// Auto-import Google OAuth credentials from TGAssist's Keychain if we don't have our own yet
    private func importCredentialsFromTGAssist() {
        let keychain = KeychainService.shared
        let tgAssistService = "com.tgassist.app"

        // Only import if SubsTracker doesn't already have credentials
        if keychain.retrieve(key: KeychainService.gmailClientId) == nil {
            if let clientId = keychain.readExternalService(tgAssistService, account: "gmail_client_id") {
                try? keychain.save(key: KeychainService.gmailClientId, value: clientId)
            }
        }
        if keychain.retrieve(key: KeychainService.gmailClientSecret) == nil {
            if let clientSecret = keychain.readExternalService(tgAssistService, account: "gmail_client_secret") {
                try? keychain.save(key: KeychainService.gmailClientSecret, value: clientSecret)
            }
        }
    }

    // MARK: - Connection State

    private func loadConnectionState() {
        let hasToken = KeychainService.shared.retrieve(key: KeychainService.gmailAccessToken) != nil
        let hasRefresh = KeychainService.shared.retrieve(key: KeychainService.gmailRefreshToken) != nil
        connectedEmail = KeychainService.shared.retrieve(key: KeychainService.gmailUserEmail)
        isConnected = hasToken && hasRefresh && connectedEmail != nil
    }

    // MARK: - OAuth Flow

    func authenticate() async {
        guard let clientId = KeychainService.shared.retrieve(key: KeychainService.gmailClientId),
              let clientSecret = KeychainService.shared.retrieve(key: KeychainService.gmailClientSecret),
              !clientId.isEmpty, !clientSecret.isEmpty else {
            errorMessage = GmailOAuthError.noCredentials.localizedDescription
            return
        }

        isAuthenticating = true
        errorMessage = nil

        do {
            // Start loopback listener, open browser, wait for callback
            let (code, redirectURI) = try await startLoopbackAndGetCode(clientId: clientId)

            // Exchange code for tokens
            let tokenData = try await exchangeCodeForTokens(
                code: code, clientId: clientId, clientSecret: clientSecret, redirectURI: redirectURI
            )

            guard let accessToken = tokenData["access_token"] as? String else {
                throw GmailOAuthError.authFailed("No access token in response")
            }
            let refreshToken = tokenData["refresh_token"] as? String

            // Verify gmail.readonly scope was granted (Google granular consent can exclude it)
            let grantedScopes = (tokenData["scope"] as? String) ?? ""
            if !grantedScopes.contains("gmail.readonly") {
                throw GmailOAuthError.authFailed("Gmail read access was not granted. Please reconnect and make sure to check ALL permissions on Google's consent screen.")
            }

            // Verify refresh token was returned (required for long-lived access)
            guard let refreshToken else {
                throw GmailOAuthError.authFailed("Google did not return a refresh token. Go to myaccount.google.com/permissions, remove SubsTracker, then reconnect.")
            }

            // Save tokens
            try KeychainService.shared.save(key: KeychainService.gmailAccessToken, value: accessToken)
            try KeychainService.shared.save(key: KeychainService.gmailRefreshToken, value: refreshToken)

            // Fetch user email
            let profile = try await fetchUserProfile(accessToken: accessToken)
            let email = profile["email"] as? String ?? "unknown@gmail.com"
            try KeychainService.shared.save(key: KeychainService.gmailUserEmail, value: email)

            connectedEmail = email
            isConnected = true
            isAuthenticating = false
        } catch {
            isAuthenticating = false
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        try? KeychainService.shared.delete(key: KeychainService.gmailAccessToken)
        try? KeychainService.shared.delete(key: KeychainService.gmailRefreshToken)
        try? KeychainService.shared.delete(key: KeychainService.gmailUserEmail)
        isConnected = false
        connectedEmail = nil
        errorMessage = nil
    }

    // MARK: - Loopback OAuth

    private func startLoopbackAndGetCode(clientId: String) async throws -> (code: String, redirectURI: String) {
        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "gmail.oauth.loopback")
            var resumed = false

            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params)
                listener.newConnectionLimit = 1
                self.oauthListener = listener

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else {
                            if !resumed {
                                resumed = true
                                continuation.resume(throwing: GmailOAuthError.authFailed("Failed to get listener port"))
                            }
                            return
                        }
                        let redirectURI = "http://127.0.0.1:\(port)"

                        let scopes = [
                            "https://www.googleapis.com/auth/gmail.readonly",
                            "https://www.googleapis.com/auth/userinfo.email"
                        ].joined(separator: " ")

                        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                        components.queryItems = [
                            URLQueryItem(name: "client_id", value: clientId),
                            URLQueryItem(name: "redirect_uri", value: redirectURI),
                            URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "scope", value: scopes),
                            URLQueryItem(name: "access_type", value: "offline"),
                            URLQueryItem(name: "prompt", value: "consent"),
                        ]

                        if let authURL = components.url {
                            DispatchQueue.main.async {
                                NSWorkspace.shared.open(authURL)
                            }
                        }

                    case .failed(let error):
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: GmailOAuthError.authFailed("Listener failed: \(error)"))
                        }
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                        defer {
                            self?.oauthListener?.cancel()
                            self?.oauthListener = nil
                        }

                        guard let data = data, let requestString = String(data: data, encoding: .utf8) else {
                            if !resumed {
                                resumed = true
                                continuation.resume(throwing: GmailOAuthError.authFailed("No data from callback"))
                            }
                            return
                        }

                        // Parse GET /?code=XXX&scope=... HTTP/1.1
                        guard let firstLine = requestString.components(separatedBy: "\r\n").first,
                              let urlPart = firstLine.split(separator: " ").dropFirst().first,
                              let comps = URLComponents(string: "http://localhost\(urlPart)"),
                              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {

                            let errorMsg = URLComponents(string: "http://localhost\(requestString.split(separator: " ").dropFirst().first ?? "")")?
                                .queryItems?.first(where: { $0.name == "error" })?.value ?? "No auth code"

                            let errorHTML = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Authorization failed</h2><p>\(errorMsg)</p><p>You can close this tab.</p></body></html>"
                            connection.send(content: errorHTML.data(using: .utf8), completion: .contentProcessed({ _ in
                                connection.cancel()
                            }))
                            if !resumed {
                                resumed = true
                                continuation.resume(throwing: GmailOAuthError.authFailed(errorMsg))
                            }
                            return
                        }

                        let port = listener.port?.rawValue ?? 0
                        let redirectURI = "http://127.0.0.1:\(port)"

                        let successHTML = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Authorization successful!</h2><p>You can close this tab and return to SubsTracker.</p></body></html>"
                        connection.send(content: successHTML.data(using: .utf8), completion: .contentProcessed({ _ in
                            connection.cancel()
                        }))

                        if !resumed {
                            resumed = true
                            continuation.resume(returning: (code, redirectURI))
                        }
                    }
                }

                listener.start(queue: queue)
            } catch {
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: GmailOAuthError.authFailed("Failed to start listener: \(error)"))
                }
            }
        }
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, clientId: String, clientSecret: String, redirectURI: String) async throws -> [String: Any] {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "code=\(code)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "redirect_uri=\(redirectURI)",
            "grant_type=authorization_code"
        ].joined(separator: "&")
        request.httpBody = bodyParams.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw GmailOAuthError.authFailed("Token exchange failed: \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailOAuthError.invalidResponse
        }
        return json
    }

    // MARK: - User Profile

    private func fetchUserProfile(accessToken: String) async throws -> [String: Any] {
        let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GmailOAuthError.authFailed("Failed to fetch user profile")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailOAuthError.invalidResponse
        }
        return json
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = KeychainService.shared.retrieve(key: KeychainService.gmailRefreshToken) else {
            throw GmailOAuthError.tokenRefreshFailed
        }
        guard let clientId = KeychainService.shared.retrieve(key: KeychainService.gmailClientId),
              let clientSecret = KeychainService.shared.retrieve(key: KeychainService.gmailClientSecret) else {
            throw GmailOAuthError.noCredentials
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        request.httpBody = bodyParams.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GmailOAuthError.tokenRefreshFailed
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw GmailOAuthError.tokenRefreshFailed
        }

        try KeychainService.shared.save(key: KeychainService.gmailAccessToken, value: newToken)
        return newToken
    }

    // MARK: - Authenticated Gmail API Request

    func authenticatedRequest(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        let token: String
        if let existing = KeychainService.shared.retrieve(key: KeychainService.gmailAccessToken) {
            token = existing
        } else {
            token = try await refreshAccessToken()
        }

        return try await makeRequest(path: path, queryItems: queryItems, token: token)
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem], token: String, retried: Bool = false) async throws -> Data {
        var components = URLComponents(string: baseURL + "/users/me" + path)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw GmailOAuthError.apiError(statusCode: 0, message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailOAuthError.invalidResponse
        }

        // Token expired — refresh and retry once
        if http.statusCode == 401 && !retried {
            let newToken = try await refreshAccessToken()
            return try await makeRequest(path: path, queryItems: queryItems, token: newToken, retried: true)
        }

        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw GmailOAuthError.apiError(statusCode: http.statusCode, message: errorBody)
        }

        return data
    }
}
