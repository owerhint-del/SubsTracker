import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DashboardViewModel()
    @StateObject private var manager = SubscriptionManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header stats
                header

                // Cost breakdown chart
                CostPieChartView(data: viewModel.costByCategory)

                // Recent usage summary
                recentUsageSection
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await manager.refreshAll(context: modelContext)
                        viewModel.loadData(context: modelContext)
                    }
                } label: {
                    if manager.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(manager.isRefreshing)
            }
        }
        .onAppear {
            viewModel.loadData(context: modelContext)
        }
    }

    // MARK: - Header Stats

    private var header: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            StatCard(
                title: "Monthly Total",
                value: formatCurrency(viewModel.totalMonthlyCost),
                icon: "dollarsign.circle",
                color: .blue
            )

            StatCard(
                title: "Annual Total",
                value: formatCurrency(viewModel.totalAnnualCost),
                icon: "calendar",
                color: .purple
            )

            StatCard(
                title: "Subscriptions",
                value: "\(viewModel.subscriptionCount)",
                icon: "list.bullet",
                color: .orange
            )

            StatCard(
                title: "7-Day Tokens",
                value: formatTokenCount(viewModel.recentTotalTokens),
                icon: "cpu",
                color: .green
            )
        }
    }

    // MARK: - Recent Usage

    private var recentUsageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Usage (7 days)")
                .font(.headline)

            if viewModel.recentUsage.isEmpty {
                ContentUnavailableView(
                    "No Recent Usage",
                    systemImage: "chart.bar",
                    description: Text("Refresh to load usage data from connected services")
                )
                .frame(height: 150)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(
                        title: "Total Tokens",
                        value: formatTokenCount(viewModel.recentTotalTokens),
                        icon: "number",
                        color: .cyan
                    )
                    StatCard(
                        title: "Sessions",
                        value: "\(viewModel.recentTotalSessions)",
                        icon: "terminal",
                        color: .mint
                    )
                }
            }

            // Error display
            if let error = manager.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.yellow.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatCurrency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}
