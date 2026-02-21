import SwiftUI

struct SettingsView: View {
    @AppStorage("claudeDataPath") private var claudeDataPath = "~/.claude"
    @AppStorage("refreshInterval") private var refreshInterval = 30 // minutes
    @AppStorage("currencyCode") private var currencyCode = "USD"
    @AppStorage("monthlyBudget") private var monthlyBudget: Double = 0
    @AppStorage("alertThresholdPercent") private var alertThresholdPercent: Int = 90

    // Notification settings
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("quietHoursEnabled") private var quietHoursEnabled = false
    @AppStorage("quietStartHour") private var quietStartHour = 22
    @AppStorage("quietEndHour") private var quietEndHour = 8

    @State private var openAIKey = ""
    @State private var showingKey = false
    @State private var saveMessage: String?
    @State private var notificationPermission: String = "Checking..."

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

            // Gmail Integration
            Section("Gmail") {
                GmailSettingsSection()
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

            // Budget & Alerts
            Section("Budget & Alerts") {
                HStack {
                    Text("Monthly Budget")
                    Spacer()
                    TextField("0", value: $monthlyBudget, format: .currency(code: currencyCode))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                }

                if monthlyBudget == 0 {
                    Text("Set a budget to enable spend alerts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Alert at", selection: $alertThresholdPercent) {
                    Text("80%").tag(80)
                    Text("90%").tag(90)
                    Text("100%").tag(100)
                }
                .disabled(monthlyBudget <= 0)
            }

            // Notifications
            Section("Notifications") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)

                HStack {
                    Text("System permission")
                    Spacer()
                    Text(notificationPermission)
                        .foregroundStyle(.secondary)
                }

                if notificationsEnabled {
                    Toggle("Quiet hours", isOn: $quietHoursEnabled)

                    if quietHoursEnabled {
                        Picker("From", selection: $quietStartHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(formatHour(hour)).tag(hour)
                            }
                        }

                        Picker("Until", selection: $quietEndHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(formatHour(hour)).tag(hour)
                            }
                        }

                        Text("Notifications during quiet hours will be delivered at \(formatHour(quietEndHour))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            Task {
                let status = await NotificationService.shared.authorizationStatus()
                switch status {
                case .authorized: notificationPermission = "Allowed"
                case .denied: notificationPermission = "Denied"
                case .notDetermined: notificationPermission = "Not requested"
                case .provisional: notificationPermission = "Provisional"
                case .ephemeral: notificationPermission = "Ephemeral"
                @unknown default: notificationPermission = "Unknown"
                }
            }
        }
    }

    private func formatHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return formatter.string(from: date)
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
