import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class DashboardViewModel {
    var subscriptions: [Subscription] = []
    var recentUsage: [UsageRecord] = []
    var isLoading = false

    // MARK: - Computed Properties

    var totalMonthlyCost: Double {
        subscriptions.reduce(0) { $0 + $1.monthlyCost }
    }

    var totalAnnualCost: Double {
        totalMonthlyCost * 12
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

        // Load last 7 days of usage
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let usageDescriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= sevenDaysAgo },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        recentUsage = (try? context.fetch(usageDescriptor)) ?? []
        isLoading = false
    }
}
