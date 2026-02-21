import SwiftUI
import Charts

// MARK: - Token Usage Bar Chart

struct TokenUsageChartView: View {
    let data: [ChartDataPoint]
    var title: String = "Token Usage"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if data.isEmpty {
                ContentUnavailableView("No Data", systemImage: "chart.bar")
                    .frame(height: 200)
            } else {
                Chart(data) { point in
                    BarMark(
                        x: .value("Date", point.date),
                        y: .value("Tokens", point.value)
                    )
                    .foregroundStyle(by: .value("Model", point.label))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text(formatTokenCount(intValue))
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Activity Line Chart

struct ActivityChartView: View {
    let data: [ChartDataPoint]
    var title: String = "Daily Activity"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if data.isEmpty {
                ContentUnavailableView("No Data", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 200)
            } else {
                Chart(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Count", point.value)
                    )
                    .foregroundStyle(by: .value("Metric", point.label))

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Count", point.value)
                    )
                    .foregroundStyle(by: .value("Metric", point.label))
                    .opacity(0.1)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Cost Pie Chart

struct CostPieChartView: View {
    let data: [(category: String, cost: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Monthly Cost Breakdown")
                .font(.headline)

            if data.isEmpty {
                ContentUnavailableView("No Subscriptions", systemImage: "chart.pie")
                    .frame(height: 200)
            } else {
                Chart(data, id: \.category) { item in
                    SectorMark(
                        angle: .value("Cost", item.cost),
                        innerRadius: .ratio(0.5),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Category", item.category))
                    .cornerRadius(4)
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Chart Data Point

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let label: String
}

// MARK: - Helpers

func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.0fK", Double(count) / 1_000)
    }
    return "\(count)"
}
