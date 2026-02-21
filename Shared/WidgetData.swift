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

    // P1: Financial signals
    let nextChargeName: String?
    let nextChargeDaysUntil: Int?
    let budgetUsedPercent: Double?
    let forecastedMonthlySpend: Double

    struct UpcomingRenewal: Codable {
        let name: String
        let iconName: String
        let renewalDate: Date
        let monthlyCost: Double
    }

    // Backward-compatible decoder: provides defaults for new fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalMonthlyCost = try container.decode(Double.self, forKey: .totalMonthlyCost)
        totalAnnualCost = try container.decode(Double.self, forKey: .totalAnnualCost)
        subscriptionCount = try container.decode(Int.self, forKey: .subscriptionCount)
        recentTotalTokens = try container.decode(Int.self, forKey: .recentTotalTokens)
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        upcomingRenewals = try container.decode([UpcomingRenewal].self, forKey: .upcomingRenewals)
        nextChargeName = try container.decodeIfPresent(String.self, forKey: .nextChargeName)
        nextChargeDaysUntil = try container.decodeIfPresent(Int.self, forKey: .nextChargeDaysUntil)
        budgetUsedPercent = try container.decodeIfPresent(Double.self, forKey: .budgetUsedPercent)
        forecastedMonthlySpend = try container.decodeIfPresent(Double.self, forKey: .forecastedMonthlySpend) ?? 0
    }

    init(
        totalMonthlyCost: Double,
        totalAnnualCost: Double,
        subscriptionCount: Int,
        recentTotalTokens: Int,
        currencyCode: String,
        lastUpdated: Date,
        upcomingRenewals: [UpcomingRenewal],
        nextChargeName: String? = nil,
        nextChargeDaysUntil: Int? = nil,
        budgetUsedPercent: Double? = nil,
        forecastedMonthlySpend: Double = 0
    ) {
        self.totalMonthlyCost = totalMonthlyCost
        self.totalAnnualCost = totalAnnualCost
        self.subscriptionCount = subscriptionCount
        self.recentTotalTokens = recentTotalTokens
        self.currencyCode = currencyCode
        self.lastUpdated = lastUpdated
        self.upcomingRenewals = upcomingRenewals
        self.nextChargeName = nextChargeName
        self.nextChargeDaysUntil = nextChargeDaysUntil
        self.budgetUsedPercent = budgetUsedPercent
        self.forecastedMonthlySpend = forecastedMonthlySpend
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
        upcomingRenewals: [],
        nextChargeName: nil,
        nextChargeDaysUntil: nil,
        budgetUsedPercent: nil,
        forecastedMonthlySpend: 0
    )
}
