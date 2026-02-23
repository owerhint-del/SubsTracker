import SwiftUI
import SwiftData

struct GmailSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var oauth = GmailOAuthService.shared
    @State private var scanVM = GmailScanViewModel()
    @State private var subscriptionVM = SubscriptionViewModel()

    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var credentialsSaveMessage: String?

    var body: some View {
        // Google API Credentials
        VStack(alignment: .leading, spacing: 8) {
            Text("Google API Credentials")
                .font(.callout)
                .fontWeight(.medium)

            Text("Use your own Google Cloud OAuth credentials")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Client ID", text: $clientId)
                .textFieldStyle(.roundedBorder)

            SecureField("Client Secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save Credentials") {
                    saveCredentials()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(clientId.isEmpty || clientSecret.isEmpty)

                if let msg = credentialsSaveMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Link("Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/")!)
                Link("Enable Gmail API", destination: URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!)
                Link("OAuth Credentials Page", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
            }
            .font(.caption)

            Text("Enable Gmail API, create a Desktop OAuth client, then paste Client ID and Secret above")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Connection Status
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection")
                .font(.callout)
                .fontWeight(.medium)

            if oauth.isConnected, let email = oauth.connectedEmail {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(email)
                        .font(.callout)
                    Spacer()
                    Button("Disconnect") {
                        oauth.disconnect()
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Button {
                        Task { await oauth.authenticate() }
                    } label: {
                        HStack(spacing: 4) {
                            if oauth.isAuthenticating {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(oauth.isAuthenticating ? "Connecting..." : "Connect Gmail")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!hasCredentials || oauth.isAuthenticating)
                }

                if !hasCredentials {
                    Text("Save Google API credentials first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = oauth.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        // Scan
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscription Scan")
                .font(.callout)
                .fontWeight(.medium)

            HStack {
                Button {
                    Task { await scanVM.startScan(context: modelContext) }
                } label: {
                    HStack(spacing: 4) {
                        if scanVM.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(scanVM.isScanning ? "Scanning..." : "Scan for Subscriptions")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canScan)
            }

            if scanVM.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scanVM.currentProgress.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if scanVM.currentProgress.total > 0 {
                        ProgressView(value: scanVM.currentProgress.fraction)
                            .progressViewStyle(.linear)
                    }
                }
            }

            if let error = scanVM.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(error.contains("No subscriptions") ? Color.secondary : Color.red)
            }

            if let lastDate = scanVM.lastScanDateFormatted {
                Text("Last scan: \(lastDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !canScan && oauth.isConnected {
                Text("OpenAI API key required — configure in API Keys section above")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $scanVM.showingReview) {
            GmailScanReviewView(
                scanVM: $scanVM,
                subscriptionVM: subscriptionVM
            )
        }
        .onAppear {
            loadCredentials()
            subscriptionVM.loadSubscriptions(context: modelContext)
        }
    }

    // MARK: - Helpers

    private var hasCredentials: Bool {
        KeychainService.shared.retrieve(key: KeychainService.gmailClientId) != nil &&
        KeychainService.shared.retrieve(key: KeychainService.gmailClientSecret) != nil
    }

    private var hasOpenAIKey: Bool {
        let key = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey)
        return key != nil && !key!.isEmpty
    }

    private var canScan: Bool {
        oauth.isConnected && hasOpenAIKey && !scanVM.isScanning
    }

    private func loadCredentials() {
        clientId = KeychainService.shared.retrieve(key: KeychainService.gmailClientId) ?? ""
        clientSecret = KeychainService.shared.retrieve(key: KeychainService.gmailClientSecret) ?? ""
    }

    private func saveCredentials() {
        do {
            try KeychainService.shared.save(key: KeychainService.gmailClientId, value: clientId)
            try KeychainService.shared.save(key: KeychainService.gmailClientSecret, value: clientSecret)
            credentialsSaveMessage = "Saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                credentialsSaveMessage = nil
            }
        } catch {
            credentialsSaveMessage = "Error: \(error.localizedDescription)"
        }
    }
}
