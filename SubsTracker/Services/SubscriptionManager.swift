import Foundation
import SwiftData
import WidgetKit

/// Coordinates data fetching and sync across all services
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    let claudeService = ClaudeCodeLocalService.shared
    let openAIService = OpenAIUsageService.shared
    let notificationService = NotificationService.shared

    @Published var isRefreshing = false
    @Published var lastError: String?

    private init() {}

    // MARK: - Refresh All

    /// Refresh usage data for all API-connected subscriptions
    func refreshAll(context: ModelContext) async {
        isRefreshing = true
        lastError = nil

        // Apply Claude data path from Settings
        let savedPath = UserDefaults.standard.string(forKey: "claudeDataPath") ?? "~/.claude"
        let expandedPath = NSString(string: savedPath).expandingTildeInPath
        claudeService.updateBasePath(expandedPath)

        // Refresh Claude data
        await refreshClaudeUsage(context: context)

        // Refresh OpenAI data if key is available
        if openAIService.hasAPIKey {
            await refreshOpenAIUsage(context: context)
        }

        // Update widget data after refresh
        updateWidgetData(context: context)

        // Schedule notifications based on current data
        await scheduleNotifications(context: context)

        isRefreshing = false
    }

    // MARK: - Notifications

    /// Build snapshots from SwiftData models and pass to NotificationService.
    func scheduleNotifications(context: ModelContext) async {
        let subDescriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.renewalDate)]
        )
        let subscriptions = (try? context.fetch(subDescriptor)) ?? []

        // Compute current month spend for budget check
        let calendar = Calendar.current
        let now = Date()

        // Build lightweight snapshots (safe to pass off MainActor)
        // Project stale renewal dates forward when setting is enabled
        let autoCorrect = UserDefaults.standard.object(forKey: "autoCorrectRenewalDates") as? Bool ?? true
        var snapshots: [SubscriptionSnapshot] = []
        for sub in subscriptions {
            let effectiveDate: Date
            if autoCorrect {
                effectiveDate = RenewalProjectionEngine.projectRenewalDate(
                    from: sub.renewalDate, billingCycle: sub.billing, now: now
                ).projectedDate
            } else {
                effectiveDate = sub.renewalDate
            }
            snapshots.append(SubscriptionSnapshot(
                id: sub.id,
                name: sub.name,
                cost: sub.cost,
                renewalDate: effectiveDate
            ))
        }
        let recurringMonthly = subscriptions.reduce(0.0) { $0 + $1.monthlyCost }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let monthUsageDescriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= monthStart && $0.date < nextMonthStart }
        )
        let currentMonthUsage = (try? context.fetch(monthUsageDescriptor)) ?? []
        let variableSpend = currentMonthUsage.compactMap(\.totalCost).reduce(0, +)
        let totalMonthly = recurringMonthly + variableSpend

        let budget = UserDefaults.standard.double(forKey: "monthlyBudget")
        let threshold = UserDefaults.standard.integer(forKey: "alertThresholdPercent")
        let currency = UserDefaults.standard.string(forKey: "currencyCode") ?? "USD"
        let cashReserve = UserDefaults.standard.double(forKey: "cashReserve")

        // Compute funding planner for shortfall notification
        var shortfall = 0.0
        var depletionDate: Date?
        if cashReserve > 0 {
            let plannerSubs = subscriptions.map { sub in
                PlannerSubscription(
                    name: sub.name,
                    cost: sub.cost,
                    billingCycle: sub.billing,
                    renewalDate: sub.renewalDate
                )
            }
            // Fetch last 30 days usage for API spend projection
            let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!
            let last30Descriptor = FetchDescriptor<UsageRecord>(
                predicate: #Predicate<UsageRecord> { $0.date >= thirtyDaysAgo }
            )
            let last30Usage = (try? context.fetch(last30Descriptor)) ?? []
            let usageCosts = last30Usage.compactMap(\.totalCost)

            // Count actual days with data, not the fixed 30-day window
            let usageDaysOfData: Int
            if let oldest = last30Usage.min(by: { $0.date < $1.date })?.date {
                usageDaysOfData = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: oldest), to: now).day ?? 0)
            } else {
                usageDaysOfData = 0
            }

            let result = FundingPlannerEngine.calculate(
                subscriptions: plannerSubs,
                usageCosts: usageCosts,
                usageDaysOfData: usageDaysOfData,
                cashReserve: cashReserve,
                now: now
            )
            shortfall = result.shortfall
            depletionDate = result.depletionDate
        }

        await notificationService.scheduleNotifications(
            subscriptions: snapshots,
            totalMonthlySpend: totalMonthly,
            monthlyBudget: budget,
            alertThresholdPercent: threshold > 0 ? threshold : 90,
            currencyCode: currency,
            fundingShortfall: shortfall,
            depletionDate: depletionDate
        )
    }

    // MARK: - Widget Data

    /// Build and save a WidgetData snapshot for the widget extension to display.
    func updateWidgetData(context: ModelContext) {
        let subDescriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.renewalDate)]
        )
        let subscriptions = (try? context.fetch(subDescriptor)) ?? []

        let recurringMonthly = subscriptions.reduce(0.0) { $0 + $1.monthlyCost }
        let savedCurrency = UserDefaults.standard.string(forKey: "currencyCode") ?? "USD"

        // Build upcoming renewals sorted by nearest projected date
        let now = Date()
        let autoCorrect = UserDefaults.standard.object(forKey: "autoCorrectRenewalDates") as? Bool ?? true

        // Compute effective (projected) renewal dates for each subscription
        let effectiveDates: [Date] = subscriptions.map { sub in
            if autoCorrect {
                return RenewalProjectionEngine.projectRenewalDate(
                    from: sub.renewalDate, billingCycle: sub.billing, now: now
                ).projectedDate
            } else {
                return sub.renewalDate
            }
        }

        // Build sorted indices of upcoming subscriptions (startOfDay so today's renewals are included)
        let todayStart = Calendar.current.startOfDay(for: now)
        let upcomingIndices = subscriptions.indices
            .filter { effectiveDates[$0] >= todayStart }
            .sorted { effectiveDates[$0] < effectiveDates[$1] }

        var upcoming: [WidgetData.UpcomingRenewal] = []
        for i in upcomingIndices.prefix(3) {
            let sub = subscriptions[i]
            upcoming.append(WidgetData.UpcomingRenewal(
                name: sub.name,
                iconName: sub.displayIcon,
                renewalDate: effectiveDates[i],
                monthlyCost: sub.monthlyCost
            ))
        }

        // Next charge signal
        let nextChargeName: String? = upcomingIndices.first.map { subscriptions[$0].name }
        let nextChargeDaysUntil: Int? = upcomingIndices.first.map { i in
            Calendar.current.dateComponents([.day], from: now, to: effectiveDates[i]).day ?? 0
        }

        // Variable spend for the current month
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let monthUsageDescriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= monthStart && $0.date < nextMonthStart }
        )
        let currentMonthUsage = (try? context.fetch(monthUsageDescriptor)) ?? []
        let variableSpend = currentMonthUsage.compactMap(\.totalCost).reduce(0, +)

        // Forecast: linear extrapolation of variable spend
        let elapsedDays = calendar.dateComponents([.day], from: monthStart, to: now).day ?? 0
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let projectedVariable: Double
        if elapsedDays > 0 {
            projectedVariable = (variableSpend / Double(elapsedDays)) * Double(daysInMonth)
        } else {
            projectedVariable = variableSpend
        }
        let forecastedMonthly = recurringMonthly + projectedVariable

        // Budget percent
        let monthlyBudget = UserDefaults.standard.double(forKey: "monthlyBudget")
        let totalMonthly = recurringMonthly + variableSpend
        let budgetPct: Double? = monthlyBudget > 0 ? (totalMonthly / monthlyBudget) * 100 : nil

        let widgetData = WidgetData(
            totalMonthlyCost: totalMonthly,
            totalAnnualCost: recurringMonthly * 12,
            subscriptionCount: subscriptions.count,
            recentTotalTokens: 0,
            currencyCode: savedCurrency,
            lastUpdated: now,
            upcomingRenewals: Array(upcoming),
            nextChargeName: nextChargeName,
            nextChargeDaysUntil: nextChargeDaysUntil,
            budgetUsedPercent: budgetPct,
            forecastedMonthlySpend: forecastedMonthly
        )

        widgetData.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Claude Usage Sync

    func refreshClaudeUsage(context: ModelContext) async {
        do {
            let dailyUsage = try claudeService.fetchDailyUsage()

            // Find or create Claude subscription
            let claudeSub = findOrCreateSubscription(
                name: "Claude Code (Max)",
                provider: .anthropic,
                cost: 200,
                billingCycle: .monthly,
                category: .aiServices,
                context: context
            )

            // Sync daily usage records
            for daily in dailyUsage {
                guard let date = daily.parsedDate else { continue }

                let dateStart = Calendar.current.startOfDay(for: date)
                guard let dateEnd = Calendar.current.date(byAdding: .day, value: 1, to: dateStart) else { continue }
                let sourceRaw = DataSource.localFile.rawValue

                // Fetch all usage records for this source and date range,
                // then filter in memory to avoid SwiftData optional predicate issues
                let descriptor = FetchDescriptor<UsageRecord>(
                    predicate: #Predicate<UsageRecord> { record in
                        record.source == sourceRaw &&
                        record.date >= dateStart &&
                        record.date < dateEnd
                    }
                )

                let existing = (try? context.fetch(descriptor)) ?? []
                let alreadySynced = existing.contains { $0.subscription?.id == claudeSub.id }
                if !alreadySynced {
                    let record = UsageRecord(
                        date: date,
                        inputTokens: daily.totalTokens,
                        outputTokens: 0,
                        sessionCount: daily.sessionCount,
                        messageCount: daily.messageCount,
                        toolCallCount: daily.toolCallCount,
                        source: .localFile,
                        subscription: claudeSub
                    )
                    context.insert(record)
                }
            }

            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - OpenAI Usage Sync

    func refreshOpenAIUsage(context: ModelContext) async {
        do {
            guard let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) else { return }
            let dailyUsage = try await openAIService.fetchUsage(from: thirtyDaysAgo)

            // Find or create OpenAI subscription
            let openAISub = findOrCreateSubscription(
                name: "OpenAI API",
                provider: .openai,
                cost: 0, // Pay-as-you-go
                billingCycle: .monthly,
                category: .aiServices,
                context: context
            )

            for daily in dailyUsage {
                guard let date = daily.parsedDate else { continue }

                let dateStart = Calendar.current.startOfDay(for: date)
                guard let dateEnd = Calendar.current.date(byAdding: .day, value: 1, to: dateStart) else { continue }
                let sourceRaw = DataSource.api.rawValue

                let descriptor = FetchDescriptor<UsageRecord>(
                    predicate: #Predicate<UsageRecord> { record in
                        record.source == sourceRaw &&
                        record.date >= dateStart &&
                        record.date < dateEnd
                    }
                )

                let existing = (try? context.fetch(descriptor)) ?? []
                let alreadySynced = existing.contains { $0.subscription?.id == openAISub.id }
                if !alreadySynced {
                    let record = UsageRecord(
                        date: date,
                        inputTokens: daily.inputTokens ?? 0,
                        outputTokens: daily.outputTokens ?? 0,
                        totalCost: daily.cost,
                        model: daily.model,
                        source: .api,
                        subscription: openAISub
                    )
                    context.insert(record)
                }
            }

            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func findOrCreateSubscription(
        name: String,
        provider: ServiceProvider,
        cost: Double,
        billingCycle: BillingCycle,
        category: SubscriptionCategory,
        context: ModelContext
    ) -> Subscription {
        let providerRaw = provider.rawValue
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate<Subscription> { sub in
                sub.provider == providerRaw && sub.isAPIConnected == true
            }
        )

        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let subscription = Subscription(
            name: name,
            provider: provider,
            cost: cost,
            billingCycle: billingCycle,
            category: category,
            isAPIConnected: true
        )
        context.insert(subscription)
        return subscription
    }
}
