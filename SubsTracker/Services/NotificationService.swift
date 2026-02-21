import Foundation
import UserNotifications

/// Manages local notifications for budget alerts and upcoming renewals.
/// Handles permission requests, deduplication, and quiet hours scheduling.
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    // UserDefaults key for the set of already-sent notification keys
    private let sentKeysKey = "notificationSentKeys"

    // In-memory cache to avoid non-atomic UserDefaults read-modify-write races
    private var cachedSentKeys: Set<String>?

    // Key used by @AppStorage in SettingsView — must use the same registration default
    private let enabledKey = "notificationsEnabled"

    private init() {
        // Register the same default as @AppStorage("notificationsEnabled") in SettingsView.
        // This ensures defaults.bool(forKey:) returns true on fresh install.
        defaults.register(defaults: [enabledKey: true])
    }

    /// Whether notifications are enabled in user settings.
    var isEnabled: Bool {
        defaults.bool(forKey: enabledKey)
    }

    // MARK: - Permission Handling

    /// Request notification permission. Safe to call multiple times — no-ops if already determined.
    func requestPermissionIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Current authorization status for display in Settings.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Schedule Notifications

    /// Main entry point: evaluate current state and schedule any needed notifications.
    /// Called after refreshAll() and on app startup. Non-blocking.
    func scheduleNotifications(
        subscriptions: [SubscriptionSnapshot],
        totalMonthlySpend: Double,
        monthlyBudget: Double,
        alertThresholdPercent: Int,
        currencyCode: String
    ) async {
        // Check if notifications are enabled in settings
        guard isEnabled else {
            // Remove all pending notifications and reset dedup keys
            // so re-enabling sends fresh alerts instead of being blocked by stale keys
            center.removeAllPendingNotificationRequests()
            clearSentKeys()
            return
        }

        // Check system permission
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        // Schedule budget alerts
        scheduleBudgetAlert(
            totalMonthlySpend: totalMonthlySpend,
            monthlyBudget: monthlyBudget,
            alertThresholdPercent: alertThresholdPercent,
            currencyCode: currencyCode
        )

        // Schedule renewal alerts
        for sub in subscriptions {
            scheduleRenewalAlerts(for: sub, currencyCode: currencyCode)
        }

        // Single atomic flush of all dedup keys written during this cycle
        flushSentKeys()
    }

    // MARK: - Budget Alerts

    private func scheduleBudgetAlert(
        totalMonthlySpend: Double,
        monthlyBudget: Double,
        alertThresholdPercent: Int,
        currencyCode: String
    ) {
        guard monthlyBudget > 0 else { return }

        let percent = (totalMonthlySpend / monthlyBudget) * 100
        let calendar = Calendar.current
        let now = Date()
        let yearMonth = calendar.component(.year, from: now) * 100 + calendar.component(.month, from: now)

        // Alert at the configured threshold and above (80% → alerts at 80, 90, 100)
        let thresholds = [80, 90, 100].filter { $0 >= alertThresholdPercent }

        for threshold in thresholds {
            guard percent >= Double(threshold) else { continue }

            let dedupKey = "budget:\(yearMonth):\(threshold)"
            guard !hasSentKey(dedupKey) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Budget Alert"
            content.body = "You've used \(Int(percent))% of your \(CurrencyFormatter.format(monthlyBudget, code: currencyCode))/mo budget."
            content.sound = .default

            let trigger = makeTrigger()
            let request = UNNotificationRequest(
                identifier: dedupKey,
                content: content,
                trigger: trigger
            )

            center.add(request)
            markSent(dedupKey)
        }
    }

    // MARK: - Renewal Alerts

    private func scheduleRenewalAlerts(for sub: SubscriptionSnapshot, currencyCode: String) {
        let calendar = Calendar.current
        let now = Date()

        guard sub.renewalDate > now else { return }

        let daysUntil = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: sub.renewalDate)).day ?? 0

        // Date string for dedup key (ties to the specific renewal date)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateStr = dateFormatter.string(from: sub.renewalDate)

        // Find the most specific (closest) unsent alert level.
        // Iterate from closest to farthest; send only one per evaluation.
        let alertDays = [1, 3, 7]
        for daysBefore in alertDays {
            guard daysUntil <= daysBefore else { continue }

            let dedupKey = "renewal:\(sub.id):\(dateStr):\(daysBefore)"
            guard !hasSentKey(dedupKey) else {
                // Already sent this level — don't send a less-specific one
                break
            }

            let content = UNMutableNotificationContent()
            content.title = "Upcoming Renewal"

            let costStr = CurrencyFormatter.format(sub.cost, code: currencyCode)
            switch daysBefore {
            case 1:
                content.body = "\(sub.name) (\(costStr)) renews tomorrow."
            case 3:
                content.body = "\(sub.name) (\(costStr)) renews in \(daysUntil) days."
            case 7:
                content.body = "\(sub.name) (\(costStr)) renews in \(daysUntil) days."
            default:
                content.body = "\(sub.name) (\(costStr)) renews in \(daysUntil) days."
            }
            content.sound = .default

            let trigger = makeTrigger()
            let request = UNNotificationRequest(
                identifier: dedupKey,
                content: content,
                trigger: trigger
            )

            center.add(request)
            markSent(dedupKey)
            break // Only send the most specific alert
        }
    }

    // MARK: - Quiet Hours

    /// Build a trigger that respects quiet hours.
    /// If current time is in quiet hours, delays delivery to the quiet end hour.
    /// Returns nil for immediate delivery (outside quiet hours).
    private func makeTrigger() -> UNNotificationTrigger? {
        guard defaults.bool(forKey: "quietHoursEnabled") else { return nil }

        let startHour = defaults.integer(forKey: "quietStartHour")
        let endHour = defaults.integer(forKey: "quietEndHour")
        guard startHour != endHour else { return nil }

        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)

        let isInQuietHours: Bool
        if startHour < endHour {
            // Same-day range, e.g. 8..22
            isInQuietHours = currentHour >= startHour && currentHour < endHour
        } else {
            // Overnight range, e.g. 22..8 (wraps past midnight)
            isInQuietHours = currentHour >= startHour || currentHour < endHour
        }

        guard isInQuietHours else { return nil }

        // Schedule for the end of quiet hours
        var deliveryComponents = calendar.dateComponents([.year, .month, .day], from: now)
        deliveryComponents.hour = endHour
        deliveryComponents.minute = 0

        // If end hour is earlier than current (overnight), push to tomorrow
        if endHour < currentHour {
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
                deliveryComponents = calendar.dateComponents([.year, .month, .day], from: tomorrow)
                deliveryComponents.hour = endHour
                deliveryComponents.minute = 0
            }
        }

        return UNCalendarNotificationTrigger(dateMatching: deliveryComponents, repeats: false)
    }

    // MARK: - Dedup Key Management

    private func loadSentKeys() -> Set<String> {
        if let cached = cachedSentKeys { return cached }
        let keys = Set(defaults.stringArray(forKey: sentKeysKey) ?? [])
        cachedSentKeys = keys
        return keys
    }

    private func hasSentKey(_ key: String) -> Bool {
        loadSentKeys().contains(key)
    }

    private func markSent(_ key: String) {
        cachedSentKeys = loadSentKeys().union([key])
    }

    /// Flush the in-memory sent keys to UserDefaults. Call once after scheduling.
    private func flushSentKeys() {
        guard let keys = cachedSentKeys else { return }
        defaults.set(Array(keys), forKey: sentKeysKey)
    }

    /// Clear all sent keys (used when notifications are toggled off).
    private func clearSentKeys() {
        cachedSentKeys = []
        defaults.removeObject(forKey: sentKeysKey)
    }

    /// Prune old dedup keys that are no longer relevant.
    /// Called periodically (e.g. on app launch) to prevent unbounded growth.
    func pruneOldKeys() {
        let calendar = Calendar.current
        let now = Date()
        let currentYearMonth = calendar.component(.year, from: now) * 100 + calendar.component(.month, from: now)

        var keys = loadSentKeys()
        keys = keys.filter { key in
            if key.hasPrefix("budget:") {
                // Keep only current month's budget keys
                let parts = key.split(separator: ":")
                guard parts.count >= 3, let ym = Int(parts[1]) else { return false }
                return ym == currentYearMonth
            }
            if key.hasPrefix("renewal:") {
                // Keep only keys for future or recent dates
                let parts = key.split(separator: ":")
                guard parts.count >= 4 else { return false }
                let dateStr = String(parts[2])
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                guard let renewalDate = formatter.date(from: dateStr) else { return false }
                // Keep if renewal date is in the future or within last 7 days
                let daysAgo = calendar.dateComponents([.day], from: renewalDate, to: now).day ?? 0
                return daysAgo < 7
            }
            return false
        }
        cachedSentKeys = keys
        defaults.set(Array(keys), forKey: sentKeysKey)
    }
}

// MARK: - Subscription Snapshot

/// Lightweight value type passed to NotificationService to avoid SwiftData threading issues.
/// Created on @MainActor, consumed off it.
struct SubscriptionSnapshot {
    let id: UUID
    let name: String
    let cost: Double
    let renewalDate: Date
}
