import Foundation

/// Pure calculation engine for financial data export.
/// No SwiftData, UserDefaults, or UI dependencies — fully testable.
enum FinanceExportEngine {

    // MARK: - Input Types

    /// Lightweight subscription snapshot for export — no SwiftData dependency.
    struct ExportSubscription {
        let name: String
        let cost: Double
        let billingCycle: BillingCycle
        let category: SubscriptionCategory
        let renewalDate: Date
        let notes: String?
    }

    /// Lightweight usage record snapshot for export.
    struct ExportUsageRecord {
        let date: Date
        let subscriptionName: String
        let cost: Double
        let inputTokens: Int
        let outputTokens: Int
        let model: String?
    }

    /// Date range for export filtering.
    struct ExportPeriod: Equatable {
        let start: Date
        let end: Date
    }

    // MARK: - Output Types

    /// Financial summary computed from raw data.
    struct ExportSummary {
        let recurringMonthlySpend: Double
        let variableSpend: Double
        let totalMonthlySpend: Double
        let fundingRequired30d: Double
        let shortfall: Double
        let depletionDate: Date?
        let subscriptionCount: Int
        let usageRecordCount: Int
    }

    /// Complete export payload — ready to serialize to CSV or JSON.
    struct ExportPayload {
        let summary: ExportSummary
        let subscriptions: [ExportSubscription]
        let usageRecords: [ExportUsageRecord]
        let period: ExportPeriod
        let generatedAt: Date
        let currencyCode: String
    }

    // MARK: - Period Helpers

    /// Returns the start and end of the current calendar month.
    static func currentMonthPeriod(now: Date) -> ExportPeriod {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return ExportPeriod(start: start, end: end)
    }

    /// Returns a normalized custom period. Start is normalized to start-of-day,
    /// end is normalized to start-of-day of the day AFTER the selected end date (end-exclusive).
    /// Returns nil if the resulting range is invalid (start >= end).
    static func customPeriod(start: Date, end: Date) -> ExportPeriod? {
        let calendar = Calendar.current
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: end)!)
        guard normalizedStart < normalizedEnd else { return nil }
        return ExportPeriod(start: normalizedStart, end: normalizedEnd)
    }

    /// Returns a period spanning the last N days from now.
    static func lastNDaysPeriod(days: Int, now: Date) -> ExportPeriod {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return ExportPeriod(start: start, end: now)
    }

    // MARK: - Summary Calculation

    /// Computes the full financial summary from raw data.
    static func computeSummary(
        subscriptions: [ExportSubscription],
        usageRecords: [ExportUsageRecord],
        cashReserve: Double,
        now: Date
    ) -> ExportSummary {
        let recurring = subscriptions.reduce(0.0) { $0 + $1.cost * $1.billingCycle.monthlyCostMultiplier }
        let variable = usageRecords.reduce(0.0) { $0 + $1.cost }
        let total = recurring + variable

        // Use FundingPlannerEngine for projected charges
        let plannerSubs = subscriptions.map {
            PlannerSubscription(name: $0.name, cost: $0.cost, billingCycle: $0.billingCycle, renewalDate: $0.renewalDate)
        }
        let usageCosts = usageRecords.map(\.cost)

        let calendar = Calendar.current
        let daysOfData: Int
        if let oldest = usageRecords.min(by: { $0.date < $1.date })?.date {
            daysOfData = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: oldest), to: now).day ?? 0)
        } else {
            daysOfData = 0
        }

        let result = FundingPlannerEngine.calculate(
            subscriptions: plannerSubs,
            usageCosts: usageCosts,
            usageDaysOfData: daysOfData,
            cashReserve: cashReserve,
            now: now
        )

        return ExportSummary(
            recurringMonthlySpend: recurring,
            variableSpend: variable,
            totalMonthlySpend: total,
            fundingRequired30d: result.requiredNext30Days,
            shortfall: result.shortfall,
            depletionDate: result.depletionDate,
            subscriptionCount: subscriptions.count,
            usageRecordCount: usageRecords.count
        )
    }

    /// Builds the full export payload.
    static func buildPayload(
        subscriptions: [ExportSubscription],
        usageRecords: [ExportUsageRecord],
        period: ExportPeriod,
        cashReserve: Double,
        currencyCode: String,
        now: Date
    ) -> ExportPayload {
        // Filter usage records to period
        let filtered = usageRecords.filter { $0.date >= period.start && $0.date < period.end }

        let summary = computeSummary(
            subscriptions: subscriptions,
            usageRecords: filtered,
            cashReserve: cashReserve,
            now: now
        )

        return ExportPayload(
            summary: summary,
            subscriptions: subscriptions,
            usageRecords: filtered,
            period: period,
            generatedAt: now,
            currencyCode: currencyCode
        )
    }

    // MARK: - CSV Generation

    /// Generates a CSV string from the export payload.
    /// Sections: Summary, Subscriptions, and optionally Usage Records.
    static func generateCSV(from payload: ExportPayload, includeUsage: Bool) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        var lines: [String] = []

        // Metadata
        lines.append("SubsTracker Finance Export")
        lines.append("Generated,\(df.string(from: payload.generatedAt))")
        lines.append("Currency,\(payload.currencyCode)")
        lines.append("Period Start,\(df.string(from: payload.period.start))")
        lines.append("Period End,\(df.string(from: payload.period.end))")
        lines.append("")

        // Summary
        lines.append("SUMMARY")
        lines.append("Metric,Value")
        lines.append("Recurring Monthly Spend,\(formatCSVNumber(payload.summary.recurringMonthlySpend))")
        lines.append("Variable Spend (period),\(formatCSVNumber(payload.summary.variableSpend))")
        lines.append("Total Monthly Spend,\(formatCSVNumber(payload.summary.totalMonthlySpend))")
        lines.append("Funding Required (30d),\(formatCSVNumber(payload.summary.fundingRequired30d))")
        lines.append("Shortfall,\(formatCSVNumber(payload.summary.shortfall))")
        if let depletion = payload.summary.depletionDate {
            lines.append("Depletion Date,\(df.string(from: depletion))")
        }
        lines.append("Subscription Count,\(payload.summary.subscriptionCount)")
        lines.append("Usage Record Count,\(payload.summary.usageRecordCount)")
        lines.append("")

        // Subscriptions
        lines.append("SUBSCRIPTIONS")
        lines.append("Name,Cost,Billing Cycle,Monthly Cost,Category,Renewal Date,Notes")
        for sub in payload.subscriptions {
            let monthlyCost = sub.cost * sub.billingCycle.monthlyCostMultiplier
            let notes = escapeCSV(sub.notes ?? "")
            lines.append("\(escapeCSV(sub.name)),\(formatCSVNumber(sub.cost)),\(sub.billingCycle.displayName),\(formatCSVNumber(monthlyCost)),\(sub.category.rawValue),\(df.string(from: sub.renewalDate)),\(notes)")
        }

        // Usage Records (optional)
        if includeUsage && !payload.usageRecords.isEmpty {
            lines.append("")
            lines.append("USAGE RECORDS")
            lines.append("Date,Subscription,Cost,Input Tokens,Output Tokens,Model")
            for record in payload.usageRecords.sorted(by: { $0.date < $1.date }) {
                lines.append("\(df.string(from: record.date)),\(escapeCSV(record.subscriptionName)),\(formatCSVNumber(record.cost)),\(record.inputTokens),\(record.outputTokens),\(record.model ?? "")")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON Generation

    /// Generates a JSON-serializable dictionary from the export payload.
    static func generateJSON(from payload: ExportPayload, includeUsage: Bool) -> [String: Any] {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]

        var json: [String: Any] = [
            "generated_at": df.string(from: payload.generatedAt),
            "currency": payload.currencyCode,
            "period": [
                "start": df.string(from: payload.period.start),
                "end": df.string(from: payload.period.end)
            ]
        ]

        // Summary
        var summaryDict: [String: Any] = [
            "recurring_monthly_spend": roundToTwoCents(payload.summary.recurringMonthlySpend),
            "variable_spend": roundToTwoCents(payload.summary.variableSpend),
            "total_monthly_spend": roundToTwoCents(payload.summary.totalMonthlySpend),
            "funding_required_30d": roundToTwoCents(payload.summary.fundingRequired30d),
            "shortfall": roundToTwoCents(payload.summary.shortfall),
            "subscription_count": payload.summary.subscriptionCount,
            "usage_record_count": payload.summary.usageRecordCount
        ]
        if let depletion = payload.summary.depletionDate {
            summaryDict["depletion_date"] = df.string(from: depletion)
        }
        json["summary"] = summaryDict

        // Subscriptions
        json["subscriptions"] = payload.subscriptions.map { sub -> [String: Any] in
            var dict: [String: Any] = [
                "name": sub.name,
                "cost": roundToTwoCents(sub.cost),
                "billing_cycle": sub.billingCycle.rawValue,
                "monthly_cost": roundToTwoCents(sub.cost * sub.billingCycle.monthlyCostMultiplier),
                "category": sub.category.rawValue,
                "renewal_date": df.string(from: sub.renewalDate)
            ]
            if let notes = sub.notes, !notes.isEmpty {
                dict["notes"] = notes
            }
            return dict
        }

        // Usage records (optional)
        if includeUsage {
            json["usage_records"] = payload.usageRecords.sorted(by: { $0.date < $1.date }).map { rec -> [String: Any] in
                var dict: [String: Any] = [
                    "date": df.string(from: rec.date),
                    "subscription": rec.subscriptionName,
                    "cost": roundToTwoCents(rec.cost),
                    "input_tokens": rec.inputTokens,
                    "output_tokens": rec.outputTokens
                ]
                if let model = rec.model {
                    dict["model"] = model
                }
                return dict
            }
        }

        return json
    }

    // MARK: - Helpers

    /// Rounds a Double to 2 decimal places for consistent output.
    static func roundToTwoCents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Formats a number for CSV (2 decimal places).
    private static func formatCSVNumber(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Escapes a string for CSV: wraps in quotes if it contains commas, quotes, or newlines.
    static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
