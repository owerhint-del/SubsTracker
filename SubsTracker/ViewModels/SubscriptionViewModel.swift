import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SubscriptionViewModel {
    var subscriptions: [Subscription] = []
    var selectedSubscription: Subscription?
    var showingAddSheet = false
    var searchText = ""

    // MARK: - Filtered/Grouped

    var filteredSubscriptions: [Subscription] {
        if searchText.isEmpty {
            return subscriptions
        }
        return subscriptions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var groupedSubscriptions: [(category: String, items: [Subscription])] {
        let grouped = Dictionary(grouping: filteredSubscriptions) { $0.category }
        return grouped.map { (category: $0.key, items: $0.value) }
            .sorted { $0.category < $1.category }
    }

    // MARK: - CRUD

    func loadSubscriptions(context: ModelContext) {
        let descriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.name)]
        )
        subscriptions = (try? context.fetch(descriptor)) ?? []
    }

    func addSubscription(
        name: String,
        provider: ServiceProvider,
        cost: Double,
        billingCycle: BillingCycle,
        renewalDate: Date,
        category: SubscriptionCategory,
        notes: String?,
        context: ModelContext
    ) {
        let sub = Subscription(
            name: name,
            provider: provider,
            cost: cost,
            billingCycle: billingCycle,
            renewalDate: renewalDate,
            category: category,
            notes: notes
        )
        context.insert(sub)
        try? context.save()
        loadSubscriptions(context: context)
    }

    func deleteSubscription(_ subscription: Subscription, context: ModelContext) {
        context.delete(subscription)
        try? context.save()
        if selectedSubscription?.id == subscription.id {
            selectedSubscription = nil
        }
        loadSubscriptions(context: context)
    }
}
