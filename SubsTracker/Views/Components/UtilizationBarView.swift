import SwiftUI

/// Reusable progress bar showing utilization percentage with reset timer
struct UtilizationBarView: View {
    let title: String
    let utilization: Double
    let resetsAt: Date?
    var icon: String = "gauge"

    private var barColor: Color {
        if utilization >= 80 { return .red }
        if utilization >= 50 { return .orange }
        return .green
    }

    private var resetText: String? {
        guard let resetsAt else { return nil }
        let now = Date()
        guard resetsAt > now else { return "Resetting..." }

        let interval = resetsAt.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            if remainingHours > 0 {
                return "Resets in \(days)d \(remainingHours)h"
            }
            return "Resets in \(days)d"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(barColor)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(barColor)
            }

            ProgressView(value: min(utilization, 100), total: 100)
                .tint(barColor)

            if let resetText {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
