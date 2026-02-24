import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class DashboardViewModel {
    var subscriptions: [Subscription] = []
    var recentUsage: [UsageRecord] = []
    var currentMonthUsage: [UsageRecord] = []
    var last30DaysUsage: [UsageRecord] = []
    var oneTimePurchases: [OneTimePurchase] = []
    var isLoading = false

    // Budget settings — set by the View before loadData()
    var monthlyBudget: Double = 0
    var alertThresholdPercent: Double = 90

    // Funding Planner settings — set by the View before loadData()
    var cashReserve: Double = 0

    // Renewal projection setting — set by the View before loadData()
    var autoCorrectRenewalDates: Bool = true

    // Top-up recommendation settings — set by the View before loadData()
    var topUpEnabled: Bool = true
    var topUpBufferMode: TopUpBufferMode = .fixed
    var topUpBufferValue: Double = 50
    var topUpLeadDays: Int = 2

    // MARK: - Monthly Spend Engine

    /// Recurring subscriptions normalized to monthly cost
    var recurringMonthlySpend: Double {
        subscriptions.reduce(0) { $0 + $1.monthlyCost }
    }

    /// Variable API spend for the current calendar month (all usage records with a cost)
    var variableSpendCurrentMonth: Double {
        currentMonthUsage.compactMap(\.totalCost).reduce(0, +)
    }

    /// One-time purchase snapshots for engine calculations
    var purchaseSnapshots: [OneTimePurchaseEngine.PurchaseSnapshot] {
        oneTimePurchases.map {
            OneTimePurchaseEngine.PurchaseSnapshot(
                name: $0.name, amount: $0.amount, date: $0.date, category: $0.purchaseCategory
            )
        }
    }

    /// One-time spend for the current calendar month
    var oneTimeSpendCurrentMonth: Double {
        OneTimePurchaseEngine.currentMonthTotal(purchaseSnapshots, now: Date())
    }

    /// Combined monthly spend: recurring + variable API usage + one-time purchases
    var totalMonthlySpend: Double {
        recurringMonthlySpend + variableSpendCurrentMonth + oneTimeSpendCurrentMonth
    }

    var totalAnnualCost: Double {
        recurringMonthlySpend * 12
    }

    var subscriptionCount: Int {
        subscriptions.count
    }

    var costByCategory: [(category: String, cost: Double)] {
        var grouped: [String: Double] = [:]
        for sub in subscriptions {
            grouped[sub.category, default: 0] += sub.monthlyCost
        }
        return grouped.map { (category: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
    }

    // MARK: - Upcoming Payments

    /// Subscriptions sorted by next renewal date (soonest first), limited to next 30 days.
    /// When autoCorrectRenewalDates is enabled, stale dates are projected forward by billing cycle.
    var upcomingPayments: [(subscription: Subscription, daysUntil: Int, projected: Bool)] {
        let calendar = Calendar.current
        let now = Date()
        let thirtyDaysOut = calendar.date(byAdding: .day, value: 30, to: now)!

        return subscriptions.compactMap { sub -> (subscription: Subscription, daysUntil: Int, projected: Bool)? in
            let effectiveDate: Date
            let wasProjected: Bool

            if autoCorrectRenewalDates {
                let projection = RenewalProjectionEngine.projectRenewalDate(
                    from: sub.renewalDate, billingCycle: sub.billing, now: now
                )
                effectiveDate = projection.projectedDate
                wasProjected = projection.wasStale
            } else {
                effectiveDate = calendar.startOfDay(for: sub.renewalDate)
                wasProjected = false
            }

            guard effectiveDate >= calendar.startOfDay(for: now) && effectiveDate <= thirtyDaysOut else { return nil }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: effectiveDate).day ?? 0
            return (subscription: sub, daysUntil: days, projected: wasProjected)
        }
        .sorted { $0.daysUntil < $1.daysUntil }
    }

    /// Number of subscriptions with stale renewal dates that were projected forward.
    var staleRenewalCount: Int {
        guard autoCorrectRenewalDates else { return 0 }
        return RenewalProjectionEngine.staleCount(
            renewalDates: subscriptions.map { (date: $0.renewalDate, billingCycle: $0.billing) },
            now: Date()
        )
    }

    /// Total cost of payments due in the next 30 days (per-charge, not normalized)
    var upcomingTotal: Double {
        upcomingPayments.reduce(0) { $0 + $1.subscription.cost }
    }

    // MARK: - Urgency-Grouped Upcoming Payments

    /// Payments due within 3 days (urgent)
    var urgentPayments: [(subscription: Subscription, daysUntil: Int, projected: Bool)] {
        upcomingPayments.filter { $0.daysUntil <= 3 }
    }

    /// Payments due in 4–7 days
    var soonPayments: [(subscription: Subscription, daysUntil: Int, projected: Bool)] {
        upcomingPayments.filter { $0.daysUntil >= 4 && $0.daysUntil <= 7 }
    }

    /// Payments due in 8–30 days
    var laterPayments: [(subscription: Subscription, daysUntil: Int, projected: Bool)] {
        upcomingPayments.filter { $0.daysUntil >= 8 }
    }

    // MARK: - Forecast Engine

    /// Days elapsed since the start of the current month
    var elapsedDaysInMonth: Int {
        let calendar = Calendar.current
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        return calendar.dateComponents([.day], from: monthStart, to: now).day ?? 0
    }

    /// Projected variable spend for the full month (linear extrapolation)
    var projectedVariableSpend: Double {
        let elapsed = elapsedDaysInMonth
        guard elapsed > 0 else { return variableSpendCurrentMonth }
        let calendar = Calendar.current
        let now = Date()
        let range = calendar.range(of: .day, in: .month, for: now)!
        let daysInMonth = range.count
        return (variableSpendCurrentMonth / Double(elapsed)) * Double(daysInMonth)
    }

    /// Forecasted total monthly spend: recurring + projected variable
    var forecastedMonthlySpend: Double {
        recurringMonthlySpend + projectedVariableSpend
    }

    /// True when the month is too young for a reliable forecast (< 5 days)
    var forecastConfidenceIsLow: Bool {
        elapsedDaysInMonth < 5
    }

    // MARK: - Budget Alert

    /// Percentage of monthly budget used (nil when budget is disabled / 0)
    var budgetUsedPercent: Double? {
        guard monthlyBudget > 0 else { return nil }
        return (totalMonthlySpend / monthlyBudget) * 100
    }

    /// True when current spend has crossed the alert threshold
    var budgetExceeded: Bool {
        guard let percent = budgetUsedPercent else { return false }
        return percent >= alertThresholdPercent
    }

    // MARK: - Funding Planner

    /// Full funding planner result, computed from current data.
    var fundingPlannerResult: FundingPlannerResult {
        let plannerSubs = subscriptions.map { sub in
            PlannerSubscription(
                name: sub.name,
                cost: sub.cost,
                billingCycle: sub.billing,
                renewalDate: sub.renewalDate
            )
        }

        let usageCosts = last30DaysUsage.compactMap(\.totalCost)

        let calendar = Calendar.current
        let now = Date()
        // Count actual days with data, not the fixed 30-day window
        let daysOfData: Int
        if let oldest = last30DaysUsage.min(by: { $0.date < $1.date })?.date {
            daysOfData = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: oldest), to: now).day ?? 0)
        } else {
            daysOfData = 0
        }

        // Deduct recent one-time purchases from effective reserve
        let effectiveReserve = OneTimePurchaseEngine.effectiveReserve(
            cashReserve: cashReserve,
            purchases: purchaseSnapshots,
            now: now
        )

        return FundingPlannerEngine.calculate(
            subscriptions: plannerSubs,
            usageCosts: usageCosts,
            usageDaysOfData: daysOfData,
            cashReserve: effectiveReserve,
            now: now
        )
    }

    // MARK: - Top-Up Recommendation

    /// Top-up recommendation computed from funding planner result.
    var topUpRecommendation: TopUpRecommendation {
        guard topUpEnabled else {
            return TopUpRecommendation(
                recommendedAmount: 0,
                recommendedDate: nil,
                urgency: .none,
                reason: "Top-up recommendations are disabled."
            )
        }

        return TopUpRecommendationEngine.calculate(
            plannerResult: fundingPlannerResult,
            cashReserve: OneTimePurchaseEngine.effectiveReserve(
                cashReserve: cashReserve,
                purchases: purchaseSnapshots,
                now: Date()
            ),
            bufferMode: topUpBufferMode,
            bufferValue: topUpBufferValue,
            leadDays: topUpLeadDays,
            now: Date()
        )
    }

    // MARK: - Usage Stats

    var recentTotalTokens: Int {
        recentUsage.reduce(0) { $0 + $1.totalTokens }
    }

    var recentTotalSessions: Int {
        recentUsage.compactMap(\.sessionCount).reduce(0, +)
    }

    // MARK: - Data Loading

    func loadData(context: ModelContext) {
        isLoading = true
        let subDescriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.name)]
        )
        // Only use active subscriptions for financial calculations and dashboard display
        subscriptions = ((try? context.fetch(subDescriptor)) ?? []).filter { $0.isActive }

        // Load last 7 days of usage for the stats section
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let usageDescriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= sevenDaysAgo },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        recentUsage = (try? context.fetch(usageDescriptor)) ?? []

        // Load current calendar month usage for variable spend calculation [monthStart, nextMonthStart)
        let calendar = Calendar.current
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let monthUsageDescriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= monthStart && $0.date < nextMonthStart }
        )
        currentMonthUsage = (try? context.fetch(monthUsageDescriptor)) ?? []

        // Load last 30 days of usage for Funding Planner API spend projection
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!
        let last30Descriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= thirtyDaysAgo }
        )
        last30DaysUsage = (try? context.fetch(last30Descriptor)) ?? []

        // Load all one-time purchases (filtering is done by the engine)
        let purchaseDescriptor = FetchDescriptor<OneTimePurchase>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        oneTimePurchases = (try? context.fetch(purchaseDescriptor)) ?? []

        isLoading = false
    }
}
