import SwiftUI
import Charts

struct OpenAIUsageView: View {
    @Bindable var viewModel: UsageViewModel
    var polling: UsagePollingCoordinator
    @AppStorage("currencyCode") private var currencyCode = "USD"
    @State private var showingAPIKeySheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Live status indicator
                pollingStatusRow

                // Codex CLI errors
                if let error = viewModel.codexError {
                    errorBanner(error) {
                        Task { await viewModel.loadCodexData() }
                    }
                }

                // Codex CLI utilization (rate limits from most recent session)
                codexUtilizationSection

                // Codex CLI loading or content
                if viewModel.isLoadingCodex {
                    ProgressView("Loading Codex CLI data...")
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    // Codex summary stats
                    codexSummarySection

                    // Model breakdown
                    codexModelBreakdownSection

                    // Daily token chart (Codex)
                    codexDailyTokenChart

                    // Daily activity chart (Codex)
                    codexDailyActivityChart
                }

                // API Usage section (needs API key)
                apiUsageSection
            }
            .padding()
        }
        .navigationTitle("OpenAI Usage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem {
                Button {
                    showingAPIKeySheet = true
                } label: {
                    Label("API Key", systemImage: "key")
                }
            }
        }
        .sheet(isPresented: $showingAPIKeySheet) {
            APIKeyEntrySheet()
        }
        .onAppear {
            refreshAll()
            polling.registerConsumer()
        }
        .onDisappear {
            polling.unregisterConsumer()
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
        Task {
            await viewModel.loadCodexData()
        }
        if viewModel.hasOpenAIKey {
            Task { await viewModel.loadOpenAIData() }
        }
    }

    // MARK: - Codex Utilization

    @ViewBuilder
    private var codexUtilizationSection: some View {
        if let limits = viewModel.codexRateLimits {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.green)
                    Text("Codex CLI")
                        .font(.headline)
                    Spacer()
                }

                UtilizationBarView(
                    title: "Session",
                    utilization: limits.sessionUtilization,
                    resetsAt: limits.sessionResetsAt,
                    icon: "clock"
                )

                UtilizationBarView(
                    title: "Weekly",
                    utilization: limits.weeklyUtilization,
                    resetsAt: limits.weeklyResetsAt,
                    icon: "calendar"
                )

                if limits.hasCredits, let balance = limits.creditBalance {
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text("Credits: \(balance)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Codex Summary

    @ViewBuilder
    private var codexSummarySection: some View {
        if let summary = viewModel.codexSummary, summary.totalSessions > 0 {
            VStack(alignment: .leading, spacing: 12) {
                Text("Codex CLI — Summary")
                    .font(.headline)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(
                        title: "Sessions",
                        value: "\(summary.totalSessions)",
                        icon: "terminal",
                        color: .green
                    )
                    StatCard(
                        title: "Messages",
                        value: formatTokenCount(summary.totalMessages),
                        icon: "message",
                        color: .purple
                    )
                    StatCard(
                        title: "Total Tokens",
                        value: formatTokenCount(viewModel.codexTotalTokens),
                        icon: "cpu",
                        color: .blue
                    )
                    StatCard(
                        title: "Reasoning",
                        value: formatTokenCount(viewModel.codexTotalReasoningTokens),
                        icon: "brain",
                        color: .orange
                    )
                }
            }
        }
    }

    // MARK: - Codex Model Breakdown

    @ViewBuilder
    private var codexModelBreakdownSection: some View {
        if !viewModel.codexModelNames.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model Usage")
                    .font(.headline)

                ForEach(viewModel.codexModelNames, id: \.self) { modelName in
                    if let usage = viewModel.codexModelUsage[modelName] {
                        codexModelRow(name: modelName, usage: usage)
                    }
                }
            }
            .padding()
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func codexModelRow(name: String, usage: CodexModelUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.displayCodexModelName(name))
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
                    Text("Cached").font(.caption).foregroundStyle(.secondary)
                    Text(formatTokenCount(usage.cachedInputTokens))
                        .font(.callout)
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading) {
                    Text("Reasoning").font(.caption).foregroundStyle(.secondary)
                    Text(formatTokenCount(usage.reasoningTokens))
                        .font(.callout)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Codex Charts

    private var codexDailyTokenChart: some View {
        let data = viewModel.codexDailyUsage.flatMap { daily -> [ChartDataPoint] in
            guard let date = daily.parsedDate else { return [] }
            return daily.tokensByModel.map { model, tokens in
                ChartDataPoint(
                    date: date,
                    value: Double(tokens),
                    label: viewModel.displayCodexModelName(model)
                )
            }
        }

        return TokenUsageChartView(data: data, title: "Codex — Daily Token Usage")
    }

    private var codexDailyActivityChart: some View {
        let messageData = viewModel.codexDailyUsage.compactMap { daily -> ChartDataPoint? in
            guard let date = daily.parsedDate else { return nil }
            return ChartDataPoint(date: date, value: Double(daily.messageCount), label: "Messages")
        }

        let sessionData = viewModel.codexDailyUsage.compactMap { daily -> ChartDataPoint? in
            guard let date = daily.parsedDate else { return nil }
            return ChartDataPoint(date: date, value: Double(daily.sessionCount), label: "Sessions")
        }

        return ActivityChartView(data: sessionData + messageData, title: "Codex — Daily Activity")
    }

    // MARK: - API Usage Section

    @ViewBuilder
    private var apiUsageSection: some View {
        Divider()
            .padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(.blue)
                Text("API Usage")
                    .font(.headline)
                Spacer()
                if !viewModel.hasOpenAIKey {
                    Button("Add API Key") {
                        showingAPIKeySheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !viewModel.hasOpenAIKey {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Add your OpenAI API key to see API cost data from platform.openai.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // API error
                if let error = viewModel.openAIError {
                    errorBanner(error) {
                        Task { await viewModel.loadOpenAIData() }
                    }
                }

                if viewModel.isLoadingOpenAI {
                    ProgressView("Fetching API usage...")
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else if viewModel.openAIDailyUsage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("No API usage data found. Click Refresh to fetch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // API summary
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        StatCard(
                            title: "API Tokens",
                            value: formatTokenCount(viewModel.openAITotalTokens),
                            icon: "cpu",
                            color: .green
                        )
                        StatCard(
                            title: "API Cost",
                            value: CurrencyFormatter.format(viewModel.openAITotalCost, code: currencyCode),
                            icon: "dollarsign.circle",
                            color: .blue
                        )
                        StatCard(
                            title: "Days Tracked",
                            value: "\(viewModel.openAIDailyUsage.count)",
                            icon: "calendar",
                            color: .orange
                        )
                    }

                    // API token chart
                    apiTokenChart

                    // Daily breakdown
                    apiDailyBreakdown
                }
            }
        }
    }

    // MARK: - API Charts

    private var apiTokenChart: some View {
        let data = viewModel.openAIDailyUsage.compactMap { daily -> ChartDataPoint? in
            guard let date = daily.parsedDate else { return nil }
            return ChartDataPoint(
                date: date,
                value: Double(daily.totalTokens),
                label: daily.model ?? "Unknown"
            )
        }

        return TokenUsageChartView(data: data, title: "API — Daily Token Usage")
    }

    private var apiDailyBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API — Daily Breakdown")
                .font(.headline)

            ForEach(viewModel.openAIDailyUsage.prefix(14)) { daily in
                HStack {
                    Text(daily.date)
                        .font(.callout)
                        .frame(width: 100, alignment: .leading)

                    Text(daily.model ?? "—")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)

                    Spacer()

                    Text("\(formatTokenCount(daily.totalTokens)) tokens")
                        .font(.callout)

                    if let cost = daily.cost {
                        Text(CurrencyFormatter.format(cost, code: currencyCode))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Retry") { retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding()
        .background(.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - API Key Entry Sheet

struct APIKeyEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("OpenAI API Key")
                    .font(.headline)
                Spacer()
                Button("Save") { saveKey() }
                    .disabled(apiKey.isEmpty)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Enter your OpenAI API key")
                    .font(.callout)

                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Text("Your key is stored securely in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .frame(width: 400, height: 220)
        .onAppear {
            apiKey = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey) ?? ""
        }
    }

    private func saveKey() {
        do {
            if apiKey.isEmpty {
                try KeychainService.shared.delete(key: KeychainService.openAIAPIKey)
            } else {
                try KeychainService.shared.save(key: KeychainService.openAIAPIKey, value: apiKey)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
