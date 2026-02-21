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
