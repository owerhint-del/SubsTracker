import SwiftUI
import WidgetKit

// MARK: - Entry View (routes to correct size)

struct SubsTrackerWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: SubsTrackerEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(data: entry.data)
        case .systemMedium:
            MediumWidgetView(data: entry.data)
        default:
            SmallWidgetView(data: entry.data)
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(data.subscriptionCount) subs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(CurrencyFormatter.format(data.totalMonthlyCost, code: data.currencyCode))
                .font(.title)
                .fontWeight(.bold)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text("per month")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) {
            Color(.windowBackgroundColor)
        }
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let data: WidgetData

    var body: some View {
        HStack(spacing: 16) {
            // Left: cost summary
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Monthly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "dollarsign.circle.fill")
                        .foregroundStyle(.blue)
                }

                Text(CurrencyFormatter.format(data.totalMonthlyCost, code: data.currencyCode))
                    .font(.title2)
                    .fontWeight(.bold)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Annual")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(CurrencyFormatter.format(data.totalAnnualCost, code: data.currencyCode))
                            .font(.caption)
                            .fontWeight(.semibold)
                    }

                    VStack(alignment: .leading) {
                        Text("Subs")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(data.subscriptionCount)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
            }

            Divider()

            // Right: upcoming renewals
            VStack(alignment: .leading, spacing: 4) {
                Text("Upcoming")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if data.upcomingRenewals.isEmpty {
                    Spacer()
                    Text("No upcoming renewals")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                } else {
                    ForEach(data.upcomingRenewals.prefix(3), id: \.name) { renewal in
                        HStack(spacing: 6) {
                            Image(systemName: renewal.iconName)
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .frame(width: 14)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(renewal.name)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(renewal.renewalDate, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(CurrencyFormatter.format(renewal.monthlyCost, code: data.currencyCode))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(for: .widget) {
            Color(.windowBackgroundColor)
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    SubsTrackerWidget()
} timeline: {
    SubsTrackerEntry(date: .now, data: WidgetData(
        totalMonthlyCost: 247.50,
        totalAnnualCost: 2970,
        subscriptionCount: 5,
        recentTotalTokens: 1_500_000,
        currencyCode: "USD",
        lastUpdated: .now,
        upcomingRenewals: []
    ))
}

#Preview("Medium", as: .systemMedium) {
    SubsTrackerWidget()
} timeline: {
    SubsTrackerEntry(date: .now, data: WidgetData(
        totalMonthlyCost: 247.50,
        totalAnnualCost: 2970,
        subscriptionCount: 5,
        recentTotalTokens: 1_500_000,
        currencyCode: "EUR",
        lastUpdated: .now,
        upcomingRenewals: [
            .init(name: "Claude Code", iconName: "brain.head.profile", renewalDate: .now.addingTimeInterval(86400 * 3), monthlyCost: 200),
            .init(name: "OpenAI API", iconName: "cpu", renewalDate: .now.addingTimeInterval(86400 * 7), monthlyCost: 20),
            .init(name: "GitHub Pro", iconName: "hammer", renewalDate: .now.addingTimeInterval(86400 * 12), monthlyCost: 4),
        ]
    ))
}
