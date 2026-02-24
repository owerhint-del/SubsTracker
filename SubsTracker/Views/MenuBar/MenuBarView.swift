import SwiftUI

/// Dropdown content for the MenuBarExtra.
struct MenuBarView: View {
    @Bindable var usageVM: UsageViewModel
    var coordinator: UsagePollingCoordinator
    @AppStorage("currencyCode") private var currencyCode = "USD"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Usage data
            usageSection

            Divider()
                .padding(.vertical, 4)

            // Status
            statusSection

            Divider()
                .padding(.vertical, 4)

            // Actions
            actionsSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 260)
    }

    // MARK: - Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Claude
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                Text(MenuBarLabelEngine.claudeDetailLine(
                    utilization: usageVM.claudeAPIUsage?.fiveHour?.utilization,
                    extraDollars: claudeExtraDollars,
                    currencyCode: currencyCode
                ))
                .font(.callout)
            }

            // OpenAI / Codex
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(.green)
                    .frame(width: 16)
                Text(MenuBarLabelEngine.openAIDetailLine(
                    cost: usageVM.hasOpenAIKey ? usageVM.openAITotalCost : nil,
                    codexUtilization: usageVM.codexRateLimits?.sessionUtilization,
                    currencyCode: currencyCode
                ))
                .font(.callout)
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.isLive ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(coordinator.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let time = lastRefreshTimeString {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 6)
                    Text("Last refresh: \(time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                Task { await coordinator.refreshNow() }
            } label: {
                Label("Refresh Now", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .disabled(coordinator.isRefreshing)

            Button {
                openMainWindow()
            } label: {
                Label("Open Dashboard", systemImage: "chart.pie")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button {
                openUsage()
            } label: {
                Label("Open Usage", systemImage: "chart.bar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit SubsTracker", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private var claudeExtraDollars: Double? {
        guard let extra = usageVM.claudeAPIUsage?.extraUsage,
              extra.isEnabled, extra.usedDollars > 0 else { return nil }
        return extra.usedDollars
    }

    private var lastRefreshTimeString: String? {
        // Use the most recent loading timestamp from the coordinator
        guard !coordinator.isRefreshing else { return "Refreshing..." }
        return nil
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func openUsage() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .menuBarNavigateToUsage, object: nil)
    }

    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
