import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DashboardViewModel()
    @StateObject private var manager = SubscriptionManager.shared
    @AppStorage("currencyCode") private var currencyCode = "USD"
    @AppStorage("monthlyBudget") private var monthlyBudget: Double = 0
    @AppStorage("alertThresholdPercent") private var alertThresholdPercent: Int = 90
    @AppStorage("cashReserve") private var cashReserve: Double = 0
    @AppStorage("autoCorrectRenewalDates") private var autoCorrectRenewalDates = true
    @AppStorage("topUpEnabled") private var topUpEnabled = true
    @AppStorage("topUpBufferMode") private var topUpBufferMode = TopUpBufferMode.fixed.rawValue
    @AppStorage("topUpBufferValue") private var topUpBufferValue: Double = 50
    @AppStorage("topUpLeadDays") private var topUpLeadDays: Int = 2

    // Export state
    @State private var showExportSheet = false
    @State private var exportFormat: FinanceExportService.ExportFormat = .csv
    @State private var exportPeriod: FinanceExportService.ExportPeriodType = .currentMonth
    @State private var exportIncludeUsage = true
    @State private var exportCustomStart = Date()
    @State private var exportCustomEnd = Date()
    @State private var exportStatus: ExportStatus = .idle

    // One-time purchase state
    @State private var showAddPurchaseSheet = false
    @State private var newPurchaseName = ""
    @State private var newPurchaseAmount: Double = 0
    @State private var newPurchaseDate = Date()
    @State private var newPurchaseCategory: SubscriptionCategory = .other
    @State private var newPurchaseNotes = ""

    private enum ExportStatus: Equatable {
        case idle
        case exporting
        case success(String)
        case error(String)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                budgetAlertBanner
                fundingPlannerSection
                topUpRecommendationSection
                spendBreakdownSection
                CostPieChartView(data: viewModel.costByCategory)
                upcomingPaymentsSection
                oneTimePurchasesSection
                recentUsageSection
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await manager.manualRefresh(context: modelContext)
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
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    exportStatus = .idle
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
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
        .onChange(of: cashReserve) { syncBudgetSettings() }
        .onChange(of: autoCorrectRenewalDates) { syncBudgetSettings() }
        .onChange(of: topUpEnabled) { syncBudgetSettings() }
        .onChange(of: topUpBufferMode) { syncBudgetSettings() }
        .onChange(of: topUpBufferValue) { syncBudgetSettings() }
        .onChange(of: topUpLeadDays) { syncBudgetSettings() }
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

            refreshStatusRow
        }
    }

    // MARK: - Refresh Status

    private var refreshStatusRow: some View {
        HStack(spacing: 16) {
            if let last = manager.lastRefreshAtDate {
                Label {
                    Text("Refreshed \(last, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if manager.autoRefreshEnabled, let next = manager.nextRefreshDate, next > Date() {
                Label {
                    Text("Next \(next, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(manager.autoRefreshEnabled ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(manager.autoRefreshEnabled ? "Auto" : "Manual")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Spend Breakdown

    @ViewBuilder
    private var spendBreakdownSection: some View {
        let hasMultipleChannels = viewModel.variableSpendCurrentMonth > 0 || viewModel.oneTimeSpendCurrentMonth > 0
        if hasMultipleChannels {
            VStack(alignment: .leading, spacing: 8) {
                Text("Spend Breakdown")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    breakdownItem(
                        icon: "arrow.triangle.2.circlepath",
                        label: "Recurring",
                        value: viewModel.recurringMonthlySpend,
                        color: .blue
                    )
                    if viewModel.variableSpendCurrentMonth > 0 {
                        breakdownItem(
                            icon: "bolt",
                            label: "API Usage",
                            value: viewModel.variableSpendCurrentMonth,
                            color: .orange
                        )
                    }
                    if viewModel.oneTimeSpendCurrentMonth > 0 {
                        breakdownItem(
                            icon: "cart",
                            label: "One-time",
                            value: viewModel.oneTimeSpendCurrentMonth,
                            color: .purple
                        )
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(CurrencyFormatter.format(viewModel.totalMonthlySpend, code: currencyCode))
                            .font(.callout)
                            .fontWeight(.semibold)
                    }
                }
            }
            .padding()
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func breakdownItem(icon: String, label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(CurrencyFormatter.format(value, code: currencyCode))
                    .font(.caption)
                    .fontWeight(.medium)
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

            // Stale date indicator
            if viewModel.staleRenewalCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("\(viewModel.staleRenewalCount) renewal date\(viewModel.staleRenewalCount == 1 ? "" : "s") projected forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func urgencyGroup(title: String, color: Color, items: [(subscription: Subscription, daysUntil: Int, projected: Bool)]) -> some View {
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

    // MARK: - Funding Planner

    @ViewBuilder
    private var fundingPlannerSection: some View {
        if cashReserve > 0 || viewModel.fundingPlannerResult.requiredNext30Days > 0 {
            let result = viewModel.fundingPlannerResult

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "banknote")
                        .foregroundStyle(.teal)
                    Text("Funding Planner")
                        .font(.headline)
                    if result.lowConfidence {
                        Text("(limited data)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Next 30 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    fundingStatRow(
                        title: "Required",
                        value: CurrencyFormatter.format(result.requiredNext30Days, code: currencyCode),
                        icon: "arrow.down.circle",
                        color: .blue
                    )

                    fundingStatRow(
                        title: viewModel.oneTimeSpendCurrentMonth > 0 ? "Effective Reserve" : "Your Reserve",
                        value: CurrencyFormatter.format(
                            OneTimePurchaseEngine.effectiveReserve(
                                cashReserve: cashReserve,
                                purchases: viewModel.purchaseSnapshots,
                                now: Date()
                            ),
                            code: currencyCode
                        ),
                        icon: "wallet.bifold",
                        color: .green
                    )
                }

                if result.shortfall > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shortfall: \(CurrencyFormatter.format(result.shortfall, code: currencyCode))")
                                .font(.callout)
                                .fontWeight(.semibold)
                                .foregroundStyle(.red)

                            if let depletion = result.depletionDate {
                                Text("Reserve runs out \(depletion, style: .relative)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if cashReserve > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Reserve covers the next 30 days")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                // Breakdown: charges vs API
                if result.projectedAPISpend > 0 {
                    HStack(spacing: 16) {
                        Label {
                            Text("Charges: \(CurrencyFormatter.format(result.requiredNext30Days - result.projectedAPISpend, code: currencyCode))")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "creditcard")
                                .foregroundStyle(.secondary)
                        }

                        Label {
                            Text("API (projected): \(CurrencyFormatter.format(result.projectedAPISpend, code: currencyCode))")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "bolt")
                                .foregroundStyle(.orange)
                        }

                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func fundingStatRow(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            Spacer()
        }
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Top-Up Recommendation

    @ViewBuilder
    private var topUpRecommendationSection: some View {
        if topUpEnabled && cashReserve > 0 {
            let rec = viewModel.topUpRecommendation

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(urgencyColor(rec.urgency))
                    Text("Top-Up Recommendation")
                        .font(.headline)
                    if rec.urgency != .none {
                        Text(rec.urgency.rawValue)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(urgencyColor(rec.urgency))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(urgencyColor(rec.urgency).opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }

                if rec.recommendedAmount > 0 {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Top up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(CurrencyFormatter.format(rec.recommendedAmount, code: currencyCode))
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(urgencyColor(rec.urgency))
                        }

                        if let date = rec.recommendedDate {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Before")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(date, style: .date)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                            }
                        }

                        Spacer()
                    }

                    Text(rec.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("No top-up needed — your reserve covers the next 30 days.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func urgencyColor(_ urgency: TopUpUrgency) -> Color {
        switch urgency {
        case .none: return .green
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }

    // MARK: - One-Time Purchases

    private var oneTimePurchasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("One-Time Purchases")
                    .font(.headline)
                Spacer()
                if viewModel.oneTimeSpendCurrentMonth > 0 {
                    Text(CurrencyFormatter.format(viewModel.oneTimeSpendCurrentMonth, code: currencyCode))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.purple)
                }
                Button {
                    resetPurchaseForm()
                    showAddPurchaseSheet = true
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            let cal = Calendar.current
            let now = Date()
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let nextMonthStart = cal.date(byAdding: .month, value: 1, to: monthStart)!
            let currentMonthPurchases = viewModel.oneTimePurchases.filter {
                $0.date >= monthStart && $0.date < nextMonthStart
            }

            if currentMonthPurchases.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "cart")
                        .foregroundStyle(.secondary)
                    Text("No one-time purchases this month")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(currentMonthPurchases, id: \.id) { purchase in
                    HStack(spacing: 12) {
                        Image(systemName: purchase.purchaseCategory.iconSystemName)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(purchase.name)
                                .fontWeight(.medium)
                            Text(purchase.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Text(CurrencyFormatter.format(purchase.amount, code: currencyCode))
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            deletePurchase(purchase)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showAddPurchaseSheet) {
            addPurchaseSheet
        }
    }

    private var addPurchaseSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { showAddPurchaseSheet = false }
                Spacer()
                Text("Add One-Time Purchase")
                    .font(.headline)
                Spacer()
                Button("Save") { savePurchase() }
                    .disabled(newPurchaseName.isEmpty || newPurchaseAmount <= 0)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            Form {
                Section("Details") {
                    TextField("Name (e.g., API Credits)", text: $newPurchaseName)
                    HStack {
                        Text("Amount")
                        TextField("0.00", value: $newPurchaseAmount, format: .currency(code: currencyCode))
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date", selection: $newPurchaseDate, displayedComponents: .date)
                    Picker("Category", selection: $newPurchaseCategory) {
                        ForEach(SubscriptionCategory.allCases) { c in
                            Label(c.rawValue, systemImage: c.iconSystemName).tag(c)
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $newPurchaseNotes)
                        .frame(height: 50)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 400)
    }

    private func savePurchase() {
        let purchase = OneTimePurchase(
            name: newPurchaseName,
            amount: newPurchaseAmount,
            date: newPurchaseDate,
            category: newPurchaseCategory,
            notes: newPurchaseNotes.isEmpty ? nil : newPurchaseNotes
        )
        modelContext.insert(purchase)
        try? modelContext.save()
        viewModel.loadData(context: modelContext)
        showAddPurchaseSheet = false
    }

    private func deletePurchase(_ purchase: OneTimePurchase) {
        modelContext.delete(purchase)
        try? modelContext.save()
        viewModel.loadData(context: modelContext)
    }

    private func resetPurchaseForm() {
        newPurchaseName = ""
        newPurchaseAmount = 0
        newPurchaseDate = Date()
        newPurchaseCategory = .other
        newPurchaseNotes = ""
    }

    // MARK: - Export Sheet

    private var exportSheet: some View {
        VStack(spacing: 16) {
            Text("Export Financial Data")
                .font(.headline)
                .padding(.top)

            Form {
                Picker("Format", selection: $exportFormat) {
                    ForEach(FinanceExportService.ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("Period", selection: $exportPeriod) {
                    ForEach(FinanceExportService.ExportPeriodType.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }

                if exportPeriod == .custom {
                    DatePicker("From", selection: $exportCustomStart, displayedComponents: .date)
                    DatePicker("To", selection: $exportCustomEnd, displayedComponents: .date)
                }

                Toggle("Include usage breakdown", isOn: $exportIncludeUsage)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 250)

            // Status
            switch exportStatus {
            case .idle:
                EmptyView()
            case .exporting:
                ProgressView("Exporting...")
                    .controlSize(.small)
            case .success(let path):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved to \(path)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .error(let msg):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button("Cancel") {
                    showExportSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export") {
                    performExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(exportStatus == .exporting)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 400)
    }

    private func performExport() {
        exportStatus = .exporting
        Task {
            do {
                let url = try await FinanceExportService.export(
                    context: modelContext,
                    format: exportFormat,
                    periodType: exportPeriod,
                    customStart: exportCustomStart,
                    customEnd: exportCustomEnd,
                    includeUsage: exportIncludeUsage,
                    currencyCode: currencyCode,
                    cashReserve: cashReserve
                )
                exportStatus = .success(url.lastPathComponent)
            } catch FinanceExportService.ExportError.cancelled {
                exportStatus = .idle
            } catch {
                exportStatus = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func syncBudgetSettings() {
        viewModel.monthlyBudget = monthlyBudget
        viewModel.alertThresholdPercent = Double(alertThresholdPercent)
        viewModel.cashReserve = cashReserve
        viewModel.autoCorrectRenewalDates = autoCorrectRenewalDates
        viewModel.topUpEnabled = topUpEnabled
        viewModel.topUpBufferMode = TopUpBufferMode(rawValue: topUpBufferMode) ?? .fixed
        viewModel.topUpBufferValue = topUpBufferValue
        viewModel.topUpLeadDays = topUpLeadDays
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
