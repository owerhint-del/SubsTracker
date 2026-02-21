import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class DashboardViewModel {
    var subscriptions: [Subscription] = []
    var recentUsage: [UsageRecord] = []
    var currentMonthUsage: [UsageRecord] = []
    var isLoading = false

    // Budget settings — set by the View before loadData()
    var monthlyBudget: Double = 0
    var alertThresholdPercent: Double = 90

    // MARK: - Monthly Spend Engine

    /// Recurring subscriptions normalized to monthly cost
    var recurringMonthlySpend: Double {
        subscriptions.reduce(0) { $0 + $1.monthlyCost }
    }

    /// Variable API spend for the current calendar month (all usage records with a cost)
    var variableSpendCurrentMonth: Double {
        currentMonthUsage.compactMap(\.totalCost).reduce(0, +)
    }

    /// Combined monthly spend: recurring + variable API usage
    var totalMonthlySpend: Double {
        recurringMonthlySpend + variableSpendCurrentMonth
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

    /// Subscriptions sorted by next renewal date (soonest first), limited to next 30 days
    var upcomingPayments: [(subscription: Subscription, daysUntil: Int)] {
        let now = Date()
        let thirtyDaysOut = Calendar.current.date(byAdding: .day, value: 30, to: now)!

        return subscriptions
            .filter { $0.renewalDate >= now && $0.renewalDate <= thirtyDaysOut }
            .sorted { $0.renewalDate < $1.renewalDate }
            .map { sub in
                let days = Calendar.current.dateComponents([.day], from: now, to: sub.renewalDate).day ?? 0
                return (subscription: sub, daysUntil: days)
            }
    }

    /// Total cost of payments due in the next 30 days (per-charge, not normalized)
    var upcomingTotal: Double {
        upcomingPayments.reduce(0) { $0 + $1.subscription.cost }
    }

    // MARK: - Urgency-Grouped Upcoming Payments

    /// Payments due within 3 days (urgent)
    var urgentPayments: [(subscription: Subscription, daysUntil: Int)] {
        upcomingPayments.filter { $0.daysUntil <= 3 }
    }

    /// Payments due in 4–7 days
    var soonPayments: [(subscription: Subscription, daysUntil: Int)] {
        upcomingPayments.filter { $0.daysUntil >= 4 && $0.daysUntil <= 7 }
    }

    /// Payments due in 8–30 days
    var laterPayments: [(subscription: Subscription, daysUntil: Int)] {
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
        subscriptions = (try? context.fetch(subDescriptor)) ?? []

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

        isLoading = false
    }
}
