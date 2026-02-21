import SwiftUI
import Charts

struct ClaudeUsageView: View {
    @Bindable var viewModel: UsageViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Error state
                if let error = viewModel.claudeError {
                    errorBanner(error)
                }

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
                    viewModel.loadClaudeData()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            viewModel.loadClaudeData()
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
