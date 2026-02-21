import Foundation

/// Pure decision logic for notification scheduling — fully testable without UNUserNotificationCenter.
enum NotificationDecisions {

    // MARK: - Budget Alerts

    /// Returns budget threshold levels that should trigger alerts.
    /// - Parameters:
    ///   - spendPercent: current spend as percentage of budget (e.g. 92.0)
    ///   - alertThresholdPercent: user's minimum threshold setting (e.g. 80)
    ///   - sentKeys: set of already-sent dedup keys
    ///   - yearMonth: current year*100+month for dedup key generation
    /// - Returns: Array of (threshold, dedupKey) pairs that should fire
    static func budgetThresholdsToAlert(
        spendPercent: Double,
        alertThresholdPercent: Int,
        sentKeys: Set<String>,
        yearMonth: Int
    ) -> [(threshold: Int, dedupKey: String)] {
        guard spendPercent > 0 else { return [] }

        let thresholds = [80, 90, 100].filter { $0 >= alertThresholdPercent }

        return thresholds.compactMap { threshold in
            guard spendPercent >= Double(threshold) else { return nil }
            let dedupKey = "budget:\(yearMonth):\(threshold)"
            guard !sentKeys.contains(dedupKey) else { return nil }
            return (threshold, dedupKey)
        }
    }

    // MARK: - Renewal Alerts

    /// Returns the most specific renewal alert level to fire, or nil if none.
    /// Iterates closest-first [1, 3, 7]; sends only the most specific unsent level.
    /// If the closest matching level was already sent, returns nil (no less-specific fallback).
    /// - Parameters:
    ///   - daysUntil: days until renewal (must be >= 0)
    ///   - sentKeys: set of already-sent dedup keys
    ///   - subId: subscription UUID string for dedup key
    ///   - dateStr: ISO8601 date string of renewal for dedup key
    /// - Returns: (daysBefore, dedupKey) for the alert to fire, or nil
    static func renewalAlertLevel(
        daysUntil: Int,
        sentKeys: Set<String>,
        subId: String,
        dateStr: String
    ) -> (daysBefore: Int, dedupKey: String)? {
        guard daysUntil >= 0 else { return nil }

        let alertDays = [1, 3, 7]
        for daysBefore in alertDays {
            guard daysUntil <= daysBefore else { continue }

            let dedupKey = "renewal:\(subId):\(dateStr):\(daysBefore)"
            guard !sentKeys.contains(dedupKey) else {
                // Already sent this level — don't send a less-specific one
                return nil
            }

            return (daysBefore, dedupKey)
        }
        return nil
    }

    // MARK: - Quiet Hours

    /// Determines if the given hour falls within quiet hours.
    /// Handles both same-day ranges (e.g. 8→22) and overnight ranges (e.g. 22→8).
    static func isInQuietHours(
        currentHour: Int,
        startHour: Int,
        endHour: Int
    ) -> Bool {
        guard startHour != endHour else { return false }

        if startHour < endHour {
            // Same-day range, e.g. 8..22
            return currentHour >= startHour && currentHour < endHour
        } else {
            // Overnight range, e.g. 22..8 (wraps past midnight)
            return currentHour >= startHour || currentHour < endHour
        }
    }
}
