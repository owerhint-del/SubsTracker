import Foundation
import SwiftData

@Model
final class OneTimePurchase {
    var id: UUID
    var name: String
    var amount: Double
    var date: Date
    var category: String // SubscriptionCategory raw value
    var notes: String?
    var createdAt: Date

    init(
        name: String,
        amount: Double,
        date: Date = Date(),
        category: SubscriptionCategory = .other,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.date = date
        self.category = category.rawValue
        self.notes = notes
        self.createdAt = Date()
    }

    // MARK: - Computed Properties

    var purchaseCategory: SubscriptionCategory {
        get { SubscriptionCategory(rawValue: category) ?? .other }
        set { category = newValue.rawValue }
    }
}
