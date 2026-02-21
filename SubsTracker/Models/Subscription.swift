import Foundation
import SwiftData

@Model
final class Subscription {
    var id: UUID
    var name: String
    var provider: String // ServiceProvider raw value
    var cost: Double
    var billingCycle: String // BillingCycle raw value
    var renewalDate: Date
    var category: String // SubscriptionCategory raw value
    var notes: String?
    var iconName: String?
    var isAPIConnected: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \UsageRecord.subscription)
    var usageRecords: [UsageRecord]?

    init(
        name: String,
        provider: ServiceProvider = .manual,
        cost: Double = 0,
        billingCycle: BillingCycle = .monthly,
        renewalDate: Date = Date(),
        category: SubscriptionCategory = .other,
        notes: String? = nil,
        iconName: String? = nil,
        isAPIConnected: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.provider = provider.rawValue
        self.cost = cost
        self.billingCycle = billingCycle.rawValue
        self.renewalDate = renewalDate
        self.category = category.rawValue
        self.notes = notes
        self.iconName = iconName
        self.isAPIConnected = isAPIConnected
        self.createdAt = Date()
    }

    // MARK: - Computed Properties

    var serviceProvider: ServiceProvider {
        get { ServiceProvider(rawValue: provider) ?? .manual }
        set { provider = newValue.rawValue }
    }

    var billing: BillingCycle {
        get { BillingCycle(rawValue: billingCycle) ?? .monthly }
        set { billingCycle = newValue.rawValue }
    }

    var subscriptionCategory: SubscriptionCategory {
        get { SubscriptionCategory(rawValue: category) ?? .other }
        set { category = newValue.rawValue }
    }

    /// Monthly cost normalized from any billing cycle
    var monthlyCost: Double {
        cost * billing.monthlyCostMultiplier
    }

    var displayIcon: String {
        iconName ?? serviceProvider.iconSystemName
    }
}
