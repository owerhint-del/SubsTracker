import SwiftUI

struct SubscriptionRowView: View {
    let subscription: Subscription
    @AppStorage("currencyCode") private var currencyCode = "USD"

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: subscription.displayIcon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)

            // Name and category
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text(subscription.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Cost and cycle
            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyFormatter.format(subscription.cost, code: currencyCode))
                    .font(.body)
                    .fontWeight(.semibold)

                Text(subscription.billing.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // API connected indicator
            if subscription.isAPIConnected {
                Image(systemName: "link.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Stat Card (reusable)

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
