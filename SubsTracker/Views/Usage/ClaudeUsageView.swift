import SwiftUI
import Charts

struct ClaudeUsageView: View {
    @Bindable var viewModel: UsageViewModel
    var polling: UsagePollingCoordinator
    @AppStorage("currencyCode") private var currencyCode = "USD"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Live status indicator
                pollingStatusRow

                // Error state
                if let error = viewModel.claudeError {
                    errorBanner(error)
                }

                // Real-time utilization (from API)
                utilizationSection

                // Loading
                if viewModel.isLoadingClaude {
                    ProgressView("Loading Claude Code data...")
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    // Summary stats
                    summarySection

                    // Model breakdown
                    modelBreakdownSection

                    // Daily token chart
                    dailyTokenChart

                    // Daily activity chart
                    dailyActivityChart
                }
            }
            .padding()
        }
        .navigationTitle("Claude Code Usage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            refreshAll()
            polling.startPolling { await pollingRefresh() }
        }
        .onDisappear {
            polling.stopPolling()
        }
    }

    private var pollingStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(polling.isLive ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(polling.statusLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func refreshAll() {
        viewModel.loadClaudeData()
        Task {
            await viewModel.loadClaudeAPIData()
        }
    }

    /// Called by the polling coordinator on each tick.
    /// Returns true on success, false on error.
    private func pollingRefresh() async -> Bool {
        viewModel.loadClaudeData()
        await viewModel.loadClaudeAPIData()
        return viewModel.claudeError == nil && viewModel.claudeAPIStatusMessage == nil
    }

    // MARK: - Utilization

    @ViewBuilder
    private var utilizationSection: some View {
        if viewModel.isLoadingClaudeAPI {
            ProgressView("Loading live usage data...")
                .frame(maxWidth: .infinity, minHeight: 60)
                .padding()
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let usage = viewModel.claudeAPIUsage {
            VStack(alignment: .leading, spacing: 16) {
                // Plan badge
                if let plan = viewModel.claudeAPIResult,
                   case .success = plan {
                    planBadge
                }

                // Session (5-hour) utilization
                if let fiveHour = usage.fiveHour {
                    UtilizationBarView(
                        title: "Session",
                        utilization: fiveHour.utilization,
                        resetsAt: fiveHour.resetsAt,
                        icon: "clock"
                    )
                }

                // Weekly (7-day) utilization
                if let sevenDay = usage.sevenDay {
                    UtilizationBarView(
                        title: "Weekly",
                        utilization: sevenDay.utilization,
                        resetsAt: sevenDay.resetsAt,
                        icon: "calendar"
                    )
                }

                // Sonnet weekly (if present)
                if let sonnet = usage.sevenDaySonnet, sonnet.utilization > 0 {
                    UtilizationBarView(
                        title: "Sonnet Weekly",
                        utilization: sonnet.utilization,
                        resetsAt: sonnet.resetsAt,
                        icon: "sparkles"
                    )
                }

                // Opus weekly (if present)
                if let opus = usage.sevenDayOpus, opus.utilization > 0 {
                    UtilizationBarView(
                        title: "Opus Weekly",
                        utilization: opus.utilization,
                        resetsAt: opus.resetsAt,
                        icon: "star"
                    )
                }

                // Extra usage credits
                if let extra = usage.extraUsage, extra.isEnabled {
                    extraUsageRow(extra)
                }
            }
            .padding()
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let statusMessage = viewModel.claudeAPIStatusMessage {
            // API unavailable — show info text
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var planBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.blue)
            Text("Live Usage")
                .font(.headline)
            Spacer()
        }
    }

    private func extraUsageRow(_ extra: ClaudeExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "creditcard")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text("Extra Usage")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if extra.hasLimit {
                    Text("\(CurrencyFormatter.format(extra.usedDollars, code: currencyCode)) / \(CurrencyFormatter.format(extra.monthlyLimitDollars, code: currencyCode))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else {
                    Text(CurrencyFormatter.format(extra.usedDollars, code: currencyCode))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }

            if extra.hasLimit {
                ProgressView(value: extra.usedDollars, total: extra.monthlyLimitDollars)
                    .tint(.blue)
            }
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)

            if let summary = viewModel.claudeSummary {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(
                        title: "Total Sessions",
                        value: "\(summary.totalSessions)",
                        icon: "terminal",
                        color: .blue
                    )
                    StatCard(
                        title: "Total Messages",
                        value: formatTokenCount(summary.totalMessages),
                        icon: "message",
                        color: .purple
                    )
                    StatCard(
                        title: "Output Tokens",
                        value: formatTokenCount(viewModel.claudeTotalTokens),
                        icon: "cpu",
                        color: .green
                    )
                    StatCard(
                        title: "Cached Tokens",
                        value: formatTokenCount(viewModel.claudeTotalCachedTokens),
                        icon: "arrow.triangle.2.circlepath",
                        color: .orange
                    )
                }
            }
        }
    }

    // MARK: - Model Breakdown

    private var modelBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model Usage")
                .font(.headline)

            ForEach(viewModel.claudeModelNames, id: \.self) { modelName in
                if let usage = viewModel.claudeModelUsage[modelName] {
                    modelRow(name: modelName, usage: usage)
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func modelRow(name: String, usage: ClaudeModelUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.displayModelName(name))
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Input").font(.caption).foregroundStyle(.secondary)
                    Text(formatTokenCount(usage.inputTokens))
                        .font(.callout)
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading) {
                    Text("Output").font(.caption).foregroundStyle(.secondary)
                    Text(formatTokenCount(usage.outputTokens))
                        .font(.callout)
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading) {
                    Text("Cache Read").font(.caption).foregroundStyle(.secondary)
                    Text(formatTokenCount(usage.cacheReadInputTokens))
                        .font(.callout)
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading) {
                    Text("Cache Write").font(.caption).foregroundStyle(.secondary)
                    Text(formatTokenCount(usage.cacheCreationInputTokens))
                        .font(.callout)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Charts

    private var dailyTokenChart: some View {
        let data = viewModel.claudeDailyUsage.flatMap { daily -> [ChartDataPoint] in
            guard let date = daily.parsedDate else { return [] }
            return daily.tokensByModel.map { model, tokens in
                ChartDataPoint(
                    date: date,
                    value: Double(tokens),
                    label: viewModel.displayModelName(model)
                )
            }
        }

        return TokenUsageChartView(data: data, title: "Daily Token Usage by Model")
    }

    private var dailyActivityChart: some View {
        let messageData = viewModel.claudeDailyUsage.compactMap { daily -> ChartDataPoint? in
            guard let date = daily.parsedDate else { return nil }
            return ChartDataPoint(date: date, value: Double(daily.messageCount), label: "Messages")
        }

        let sessionData = viewModel.claudeDailyUsage.compactMap { daily -> ChartDataPoint? in
            guard let date = daily.parsedDate else { return nil }
            return ChartDataPoint(date: date, value: Double(daily.sessionCount), label: "Sessions")
        }

        return ActivityChartView(data: sessionData + messageData, title: "Daily Activity")
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Retry") {
                viewModel.loadClaudeData()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
