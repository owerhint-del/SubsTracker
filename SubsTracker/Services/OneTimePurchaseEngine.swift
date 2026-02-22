import Foundation

/// Pure calculation engine for one-time purchases and API top-ups.
/// No SwiftData, UserDefaults, or UI dependencies — fully testable.
enum OneTimePurchaseEngine {

    // MARK: - Input Type

    /// Lightweight purchase snapshot — no SwiftData dependency.
    struct PurchaseSnapshot {
        let name: String
        let amount: Double
        let date: Date
        let category: SubscriptionCategory
    }

    // MARK: - Aggregation Result

    struct PurchaseAggregate {
        let totalAmount: Double
        let count: Int
        let byCategory: [(category: SubscriptionCategory, amount: Double)]
    }

    // MARK: - Period Filtering

    /// Filters purchases to those within [start, end).
    static func filterByPeriod(
        _ purchases: [PurchaseSnapshot],
        start: Date,
        end: Date
    ) -> [PurchaseSnapshot] {
        purchases.filter { $0.date >= start && $0.date < end }
    }

    /// Filters purchases to the current calendar month.
    static func currentMonthPurchases(
        _ purchases: [PurchaseSnapshot],
        now: Date
    ) -> [PurchaseSnapshot] {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        return filterByPeriod(purchases, start: monthStart, end: nextMonth)
    }

    /// Filters purchases to the last N days.
    static func lastNDaysPurchases(
        _ purchases: [PurchaseSnapshot],
        days: Int,
        now: Date
    ) -> [PurchaseSnapshot] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return filterByPeriod(purchases, start: start, end: now)
    }

    // MARK: - Aggregation

    /// Computes total and per-category breakdown for a set of purchases.
    static func aggregate(_ purchases: [PurchaseSnapshot]) -> PurchaseAggregate {
        let total = purchases.reduce(0.0) { $0 + $1.amount }
        var grouped: [SubscriptionCategory: Double] = [:]
        for p in purchases {
            grouped[p.category, default: 0] += p.amount
        }
        let byCategory = grouped
            .map { (category: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }

        return PurchaseAggregate(
            totalAmount: total,
            count: purchases.count,
            byCategory: byCategory
        )
    }

    /// Computes the current month one-time spend total.
    static func currentMonthTotal(
        _ purchases: [PurchaseSnapshot],
        now: Date
    ) -> Double {
        currentMonthPurchases(purchases, now: now).reduce(0.0) { $0 + $1.amount }
    }

    // MARK: - Funding Planner Integration

    /// Computes the effective cash reserve after subtracting one-time purchases
    /// made in the last N days (default 30, matching the planner horizon).
    static func effectiveReserve(
        cashReserve: Double,
        purchases: [PurchaseSnapshot],
        days: Int = 30,
        now: Date
    ) -> Double {
        let recentTotal = lastNDaysPurchases(purchases, days: days, now: now)
            .reduce(0.0) { $0 + $1.amount }
        return max(0, cashReserve - recentTotal)
    }
}
