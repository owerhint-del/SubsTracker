import Foundation

/// Lightweight summary written by the main app and read by the widget.
/// Stored in shared UserDefaults (App Group suite).
struct WidgetData: Codable {
    let totalMonthlyCost: Double
    let totalAnnualCost: Double
    let subscriptionCount: Int
    let recentTotalTokens: Int
    let currencyCode: String
    let lastUpdated: Date
    let upcomingRenewals: [UpcomingRenewal]

    struct UpcomingRenewal: Codable {
        let name: String
        let iconName: String
        let renewalDate: Date
        let monthlyCost: Double
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "widgetData"

    /// Save to shared UserDefaults for widget consumption.
    func save() {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName) else { return }
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }

    /// Load from shared UserDefaults. Returns placeholder if nothing stored yet.
    static func load() -> WidgetData {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName),
              let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(WidgetData.self, from: data)
        else {
            return .placeholder
        }
        return decoded
    }

    /// Default placeholder shown before the main app writes real data.
    static let placeholder = WidgetData(
        totalMonthlyCost: 0,
        totalAnnualCost: 0,
        subscriptionCount: 0,
        recentTotalTokens: 0,
        currencyCode: "USD",
        lastUpdated: Date(),
        upcomingRenewals: []
    )
}
