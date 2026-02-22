import Foundation

/// Pure calculation engine for projecting stale renewal dates forward.
/// No SwiftData, UserDefaults, or UI dependencies — fully testable.
enum RenewalProjectionEngine {

    /// Maximum number of cycle advances before aborting (infinite-loop guard).
    static let maxCycles = 1000

    // MARK: - Output Type

    /// Result of projecting a single renewal date.
    struct ProjectionResult {
        /// The projected next renewal date (>= now).
        let projectedDate: Date
        /// True if the original renewalDate was in the past.
        let wasStale: Bool
        /// Number of billing cycles advanced to reach projectedDate.
        let cyclesAdvanced: Int
    }

    // MARK: - Core Projection

    /// Project a renewal date forward by billing cycle until it is on or after `now`.
    /// If the date is already in the future (>= now), returns it unchanged with wasStale = false.
    static func projectRenewalDate(
        from renewalDate: Date,
        billingCycle: BillingCycle,
        now: Date
    ) -> ProjectionResult {
        let calendar = Calendar.current
        let startOfRenewal = calendar.startOfDay(for: renewalDate)
        let startOfNow = calendar.startOfDay(for: now)

        guard startOfRenewal < startOfNow else {
            return ProjectionResult(projectedDate: startOfRenewal, wasStale: false, cyclesAdvanced: 0)
        }

        var date = startOfRenewal
        var cycles = 0

        while date < startOfNow && cycles < maxCycles {
            switch billingCycle {
            case .weekly:
                date = calendar.date(byAdding: .day, value: 7, to: date)!
            case .monthly:
                date = calendar.date(byAdding: .month, value: 1, to: date)!
            case .annual:
                date = calendar.date(byAdding: .year, value: 1, to: date)!
            }
            cycles += 1
        }

        return ProjectionResult(projectedDate: date, wasStale: true, cyclesAdvanced: cycles)
    }

    // MARK: - Batch Projection

    /// Projects all subscriptions and returns the count of stale ones.
    static func staleCount(
        renewalDates: [(date: Date, billingCycle: BillingCycle)],
        now: Date
    ) -> Int {
        renewalDates.reduce(0) { count, entry in
            let result = projectRenewalDate(from: entry.date, billingCycle: entry.billingCycle, now: now)
            return count + (result.wasStale ? 1 : 0)
        }
    }
}
