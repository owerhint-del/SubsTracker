import SwiftUI
import Charts

struct OpenAIUsageView: View {
    @Bindable var viewModel: UsageViewModel
    @State private var showingAPIKeySheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !viewModel.hasOpenAIKey {
                    // No API key — show setup prompt
                    noAPIKeyView
                } else {
                    // Error state
                    if let error = viewModel.openAIError {
                        errorBanner(error)
                    }

                    // Loading
                    if viewModel.isLoadingOpenAI {
                        ProgressView("Fetching OpenAI usage...")
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else if viewModel.openAIDailyUsage.isEmpty {
                        ContentUnavailableView(
                            "No Usage Data",
                            systemImage: "chart.bar",
                            description: Text("Click Refresh to fetch usage data from OpenAI")
                        )
                    } else {
                        // Summary
                        summarySection

                        // Token chart
                        tokenChart

                        // Daily breakdown table
                        dailyBreakdown
                    }
                }
            }
            .padding()
        }
        .navigationTitle("OpenAI Usage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.loadOpenAIData() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.hasOpenAIKey || viewModel.isLoadingOpenAI)
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
            if viewModel.hasOpenAIKey {
                Task { await viewModel.loadOpenAIData() }
            }
        }
    }

    // MARK: - No API Key

    private var noAPIKeyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("OpenAI API Key Required")
                .font(.title2)
                .fontWeight(.bold)

            Text("Add your OpenAI API key to fetch usage data automatically. You can find it at platform.openai.com.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Add API Key") {
                showingAPIKeySheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - Summary

    private var summarySection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            StatCard(
                title: "Total Tokens",
                value: formatTokenCount(viewModel.openAITotalTokens),
                icon: "cpu",
                color: .green
            )
            StatCard(
                title: "Total Cost",
                value: String(format: "$%.2f", viewModel.openAITotalCost),
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
    }

    // MARK: - Token Chart

    private var tokenChart: some View {
        let data = viewModel.openAIDailyUsage.compactMap { daily -> ChartDataPoint? in
            guard let date = daily.parsedDate else { return nil }
            return ChartDataPoint(
                date: date,
                value: Double(daily.totalTokens),
                label: daily.model ?? "Unknown"
            )
        }

        return TokenUsageChartView(data: data, title: "Daily Token Usage")
    }

    // MARK: - Daily Breakdown

    private var dailyBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily Breakdown")
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
                        Text(String(format: "$%.4f", cost))
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

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Retry") {
                Task { await viewModel.loadOpenAIData() }
            }
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
