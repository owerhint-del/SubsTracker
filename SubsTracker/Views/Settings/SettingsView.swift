import SwiftUI

struct SettingsView: View {
    @AppStorage("claudeDataPath") private var claudeDataPath = "~/.claude"
    @AppStorage("refreshInterval") private var refreshInterval = 30 // minutes
    @AppStorage("currencyCode") private var currencyCode = "USD"

    @State private var openAIKey = ""
    @State private var showingKey = false
    @State private var saveMessage: String?

    private let currencies = ["USD", "EUR", "GBP", "RUB", "JPY", "CAD", "AUD"]

    var body: some View {
        Form {
            // API Keys
            Section("API Keys") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenAI API Key")
                        .font(.callout)
                        .fontWeight(.medium)

                    HStack {
                        if showingKey {
                            TextField("sk-...", text: $openAIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-...", text: $openAIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showingKey.toggle()
                        } label: {
                            Image(systemName: showingKey ? "eye.slash" : "eye")
                        }

                        Button("Save") {
                            saveOpenAIKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Text("Stored securely in macOS Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let msg = saveMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Anthropic / Claude Code")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("No API key needed — data is read from local files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Claude Code Data Path
            Section("Claude Code") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data Path")
                        .font(.callout)
                        .fontWeight(.medium)

                    HStack {
                        TextField("~/.claude", text: $claudeDataPath)
                            .textFieldStyle(.roundedBorder)

                        Button("Reset") {
                            claudeDataPath = "~/.claude"
                        }
                        .controlSize(.small)
                    }

                    Text("Path to Claude Code's data directory (contains stats-cache.json)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Preferences
            Section("Preferences") {
                Picker("Currency", selection: $currencyCode) {
                    ForEach(currencies, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }

                Picker("Auto-refresh interval", selection: $refreshInterval) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
            }

            // About
            Section("About") {
                HStack {
                    Text("Subs Tracker")
                        .fontWeight(.medium)
                    Spacer()
                    Text("v1.0.0")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Platform")
                    Spacer()
                    Text("macOS")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            openAIKey = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey) ?? ""
        }
    }

    private func saveOpenAIKey() {
        do {
            if openAIKey.isEmpty {
                try KeychainService.shared.delete(key: KeychainService.openAIAPIKey)
                saveMessage = "Key removed"
            } else {
                try KeychainService.shared.save(key: KeychainService.openAIAPIKey, value: openAIKey)
                saveMessage = "Key saved to Keychain"
            }
            // Clear message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                saveMessage = nil
            }
        } catch {
            saveMessage = "Error: \(error.localizedDescription)"
        }
    }
}
