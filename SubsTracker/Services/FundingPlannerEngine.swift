import Foundation

// MARK: - Input / Output Types

/// Lightweight subscription data for the planner — no SwiftData dependency.
struct PlannerSubscription {
    let name: String
    let cost: Double
    let billingCycle: BillingCycle
    let renewalDate: Date
}

/// A single projected charge within the planning horizon.
struct FundingCharge: Equatable {
    let name: String
    let amount: Double
    let date: Date

    static func == (lhs: FundingCharge, rhs: FundingCharge) -> Bool {
        lhs.name == rhs.name && lhs.amount == rhs.amount
            && Calendar.current.isDate(lhs.date, inSameDayAs: rhs.date)
    }
}

/// Complete output of the funding planner calculation.
struct FundingPlannerResult {
    let projectedCharges: [FundingCharge]
    let projectedAPISpend: Double
    let requiredNext30Days: Double
    let shortfall: Double
    let depletionDate: Date?
    let lowConfidence: Bool
}

// MARK: - Engine

/// Pure calculation engine for the Funding Planner.
/// All functions are deterministic — no I/O, no UserDefaults, no SwiftData.
enum FundingPlannerEngine {

    /// Default planning horizon in days.
    static let horizonDays = 30

    // MARK: - Renewal Projection

    /// Advance a renewal date forward by billing cycle until it is on or after `after`.
    static func nextRenewalDate(
        from renewalDate: Date,
        billingCycle: BillingCycle,
        after: Date
    ) -> Date {
        let calendar = Calendar.current
        var date = calendar.startOfDay(for: renewalDate)
        let target = calendar.startOfDay(for: after)

        while date < target {
            switch billingCycle {
            case .weekly:
                date = calendar.date(byAdding: .day, value: 7, to: date)!
            case .monthly:
                date = calendar.date(byAdding: .month, value: 1, to: date)!
            case .annual:
                date = calendar.date(byAdding: .year, value: 1, to: date)!
            }
        }
        return date
    }

    /// Collect all charge dates for a subscription within [from, from + days).
    static func projectedCharges(
        for subscription: PlannerSubscription,
        from: Date,
        days: Int = horizonDays
    ) -> [FundingCharge] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }

        var charges: [FundingCharge] = []
        var date = nextRenewalDate(
            from: subscription.renewalDate,
            billingCycle: subscription.billingCycle,
            after: start
        )

        while date < end {
            charges.append(FundingCharge(
                name: subscription.name,
                amount: subscription.cost,
                date: date
            ))
            // Advance to the next cycle
            switch subscription.billingCycle {
            case .weekly:
                date = calendar.date(byAdding: .day, value: 7, to: date)!
            case .monthly:
                date = calendar.date(byAdding: .month, value: 1, to: date)!
            case .annual:
                date = calendar.date(byAdding: .year, value: 1, to: date)!
            }
        }
        return charges
    }

    /// Collect all charges for multiple subscriptions, sorted by date.
    static func allProjectedCharges(
        subscriptions: [PlannerSubscription],
        from: Date,
        days: Int = horizonDays
    ) -> [FundingCharge] {
        subscriptions
            .flatMap { projectedCharges(for: $0, from: from, days: days) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - API Spend Projection

    /// Project API spend over the planning horizon from historical cost data.
    /// - Parameters:
    ///   - costs: Array of daily cost values from usage records (last 30 days, non-nil costs only)
    ///   - daysOfData: Number of calendar days the cost data spans
    ///   - horizonDays: Days to project forward
    /// - Returns: Projected total API spend, and whether confidence is low (< 5 days of data)
    static func projectedAPISpend(
        costs: [Double],
        daysOfData: Int,
        horizonDays: Int = horizonDays
    ) -> (total: Double, lowConfidence: Bool) {
        let totalCost = costs.reduce(0, +)
        guard daysOfData > 0, totalCost > 0 else { return (0, true) }
        let dailyRate = totalCost / Double(daysOfData)
        return (dailyRate * Double(horizonDays), daysOfData < 5)
    }

    // MARK: - Depletion Walk

    /// Walk day-by-day through the planning horizon, subtracting charges and daily API spend.
    /// Returns the first date where the running balance drops below zero, or nil if reserve holds.
    static func depletionDate(
        charges: [FundingCharge],
        dailyAPIRate: Double,
        reserve: Double,
        from: Date,
        days: Int = horizonDays
    ) -> Date? {
        guard reserve > 0 || dailyAPIRate > 0 || !charges.isEmpty else { return nil }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from)
        var balance = reserve

        // Pre-group charges by day offset for O(1) lookup
        var chargesByDay: [Int: Double] = [:]
        for charge in charges {
            let dayOffset = calendar.dateComponents([.day], from: start, to: charge.date).day ?? 0
            if dayOffset >= 0 && dayOffset < days {
                chargesByDay[dayOffset, default: 0] += charge.amount
            }
        }

        for day in 0..<days {
            // Subtract daily API burn
            balance -= dailyAPIRate
            // Subtract any charges due today
            if let dayCharges = chargesByDay[day] {
                balance -= dayCharges
            }
            if balance < 0 {
                return calendar.date(byAdding: .day, value: day, to: start)
            }
        }
        return nil
    }

    // MARK: - Full Calculation

    /// Run the complete funding planner calculation.
    static func calculate(
        subscriptions: [PlannerSubscription],
        usageCosts: [Double],
        usageDaysOfData: Int,
        cashReserve: Double,
        now: Date
    ) -> FundingPlannerResult {
        let charges = allProjectedCharges(subscriptions: subscriptions, from: now)
        let chargesTotal = charges.reduce(0.0) { $0 + $1.amount }

        let (apiSpend, apiLowConfidence) = projectedAPISpend(
            costs: usageCosts,
            daysOfData: usageDaysOfData
        )

        let required = chargesTotal + apiSpend
        let shortfall = max(0, required - cashReserve)

        let dailyAPIRate = usageDaysOfData > 0
            ? usageCosts.reduce(0, +) / Double(usageDaysOfData)
            : 0

        let depletion = depletionDate(
            charges: charges,
            dailyAPIRate: dailyAPIRate,
            reserve: cashReserve,
            from: now
        )

        return FundingPlannerResult(
            projectedCharges: charges,
            projectedAPISpend: apiSpend,
            requiredNext30Days: required,
            shortfall: shortfall,
            depletionDate: depletion,
            lowConfidence: apiLowConfidence
        )
    }
}
