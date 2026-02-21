import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DashboardViewModel()
    @StateObject private var manager = SubscriptionManager.shared
    @AppStorage("currencyCode") private var currencyCode = "USD"
    @AppStorage("lastRefreshAt") private var lastRefreshAt: Double = 0
    @AppStorage("monthlyBudget") private var monthlyBudget: Double = 0
    @AppStorage("alertThresholdPercent") private var alertThresholdPercent: Int = 90

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                budgetAlertBanner
                CostPieChartView(data: viewModel.costByCategory)
                upcomingPaymentsSection
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
                        lastRefreshAt = Date().timeIntervalSince1970
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
            // Pass budget settings to ViewModel
            syncBudgetSettings()

            // Load local data only — auto-refresh is owned by ContentView
            viewModel.loadData(context: modelContext)
        }
        .onChange(of: manager.isRefreshing) {
            // Reload local data when a refresh (auto or manual) finishes
            if !manager.isRefreshing {
                syncBudgetSettings()
                viewModel.loadData(context: modelContext)
            }
        }
        .onChange(of: monthlyBudget) { syncBudgetSettings() }
        .onChange(of: alertThresholdPercent) { syncBudgetSettings() }
    }

    // MARK: - Header Stats

    private var header: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                StatCard(
                    title: "Monthly Total",
                    value: CurrencyFormatter.format(viewModel.totalMonthlySpend, code: currencyCode),
                    icon: "dollarsign.circle",
                    color: .blue
                )

                StatCard(
                    title: "Annual (Recurring)",
                    value: CurrencyFormatter.format(viewModel.totalAnnualCost, code: currencyCode),
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
                    title: viewModel.forecastConfidenceIsLow ? "Forecast (early est.)" : "Forecast",
                    value: CurrencyFormatter.format(viewModel.forecastedMonthlySpend, code: currencyCode),
                    icon: "chart.line.uptrend.xyaxis",
                    color: .green
                )
            }

            // API spend breakdown (only shown when there is variable spend)
            if viewModel.variableSpendCurrentMonth > 0 {
                HStack(spacing: 16) {
                    Label {
                        Text("Recurring: \(CurrencyFormatter.format(viewModel.recurringMonthlySpend, code: currencyCode))")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }

                    Label {
                        Text("API spend this month: \(CurrencyFormatter.format(viewModel.variableSpendCurrentMonth, code: currencyCode))")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "bolt")
                            .foregroundStyle(.orange)
                    }

                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Budget Alert Banner

    @ViewBuilder
    private var budgetAlertBanner: some View {
        if viewModel.budgetExceeded, let percent = viewModel.budgetUsedPercent {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Budget alert: \(Int(percent))% of \(CurrencyFormatter.format(monthlyBudget, code: currencyCode))/mo used")
                        .font(.callout)
                        .fontWeight(.medium)

                    Text("Projected \(CurrencyFormatter.format(viewModel.forecastedMonthlySpend, code: currencyCode)) by month end")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Upcoming Payments

    private var upcomingPaymentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming Payments")
                    .font(.headline)
                Spacer()
                if !viewModel.upcomingPayments.isEmpty {
                    Text(CurrencyFormatter.format(viewModel.upcomingTotal, code: currencyCode))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
            }

            if viewModel.upcomingPayments.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("No payments due in the next 30 days")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                // Urgency-grouped display
                if !viewModel.urgentPayments.isEmpty {
                    urgencyGroup(title: "Urgent", color: .red, items: viewModel.urgentPayments)
                }
                if !viewModel.soonPayments.isEmpty {
                    urgencyGroup(title: "This Week", color: .orange, items: viewModel.soonPayments)
                }
                if !viewModel.laterPayments.isEmpty {
                    urgencyGroup(title: "Later", color: .secondary, items: viewModel.laterPayments)
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func urgencyGroup(title: String, color: Color, items: [(subscription: Subscription, daysUntil: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .padding(.top, 4)

            ForEach(items, id: \.subscription.id) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.subscription.displayIcon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.subscription.name)
                            .fontWeight(.medium)
                        Text(item.subscription.billing.displayName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CurrencyFormatter.format(item.subscription.cost, code: currencyCode))
                            .fontWeight(.semibold)

                        Text(daysLabel(item.daysUntil))
                            .font(.caption)
                            .foregroundStyle(item.daysUntil <= 3 ? .red : .secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func daysLabel(_ days: Int) -> String {
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "in \(days) days"
        }
    }

    // MARK: - Helpers

    private func syncBudgetSettings() {
        viewModel.monthlyBudget = monthlyBudget
        viewModel.alertThresholdPercent = Double(alertThresholdPercent)
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
}
