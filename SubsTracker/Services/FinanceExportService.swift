import Foundation
import AppKit
import SwiftData

/// Service layer for exporting financial data to CSV/JSON files.
/// Bridges SwiftData models to the pure FinanceExportEngine and handles file I/O.
enum FinanceExportService {

    enum ExportFormat: String, CaseIterable, Identifiable {
        case csv = "CSV"
        case json = "JSON"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .json: return "json"
            }
        }

        var contentType: String {
            switch self {
            case .csv: return "text/csv"
            case .json: return "application/json"
            }
        }
    }

    enum ExportPeriodType: String, CaseIterable, Identifiable {
        case currentMonth = "Current Month"
        case last30Days = "Last 30 Days"
        case custom = "Custom Range"

        var id: String { rawValue }
    }

    enum ExportError: LocalizedError, Equatable {
        case cancelled
        case writeFailed(String)
        case noData
        case invalidDateRange

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Export cancelled"
            case .writeFailed(let msg): return "Failed to write file: \(msg)"
            case .noData: return "No data to export"
            case .invalidDateRange: return "Start date must be before end date"
            }
        }
    }

    // MARK: - Data Extraction

    /// Converts SwiftData Subscription models to export-safe structs.
    static func extractSubscriptions(_ subscriptions: [Subscription]) -> [FinanceExportEngine.ExportSubscription] {
        subscriptions.map { sub in
            FinanceExportEngine.ExportSubscription(
                name: sub.name,
                cost: sub.cost,
                billingCycle: sub.billing,
                category: sub.subscriptionCategory,
                renewalDate: sub.renewalDate,
                notes: sub.notes
            )
        }
    }

    /// Converts SwiftData UsageRecord models to export-safe structs.
    /// Excludes records without a cost (flat-rate subs like Claude Code Max).
    static func extractUsageRecords(_ records: [UsageRecord]) -> [FinanceExportEngine.ExportUsageRecord] {
        records.compactMap { record in
            guard let cost = record.totalCost else { return nil }
            return FinanceExportEngine.ExportUsageRecord(
                date: record.date,
                subscriptionName: record.subscription?.name ?? "Unknown",
                cost: cost,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                model: record.model
            )
        }
    }

    // MARK: - Export Execution

    /// Builds the export payload and serializes to string data.
    @MainActor
    static func export(
        context: ModelContext,
        format: ExportFormat,
        periodType: ExportPeriodType,
        customStart: Date? = nil,
        customEnd: Date? = nil,
        includeUsage: Bool,
        currencyCode: String,
        cashReserve: Double
    ) async throws -> URL {
        let now = Date()

        // Determine period
        let period: FinanceExportEngine.ExportPeriod
        switch periodType {
        case .currentMonth:
            period = FinanceExportEngine.currentMonthPeriod(now: now)
        case .last30Days:
            period = FinanceExportEngine.lastNDaysPeriod(days: 30, now: now)
        case .custom:
            guard let start = customStart, let end = customEnd else {
                period = FinanceExportEngine.currentMonthPeriod(now: now)
                break
            }
            guard let customRange = FinanceExportEngine.customPeriod(start: start, end: end) else {
                throw ExportError.invalidDateRange
            }
            period = customRange
        }

        // Fetch data from SwiftData
        let subDescriptor = FetchDescriptor<Subscription>(sortBy: [SortDescriptor(\.name)])
        let subscriptions = (try? context.fetch(subDescriptor)) ?? []

        let usageDescriptor = FetchDescriptor<UsageRecord>(sortBy: [SortDescriptor(\.date)])
        let usageRecords = (try? context.fetch(usageDescriptor)) ?? []

        let exportSubs = extractSubscriptions(subscriptions)
        let exportUsage = extractUsageRecords(usageRecords)

        if exportSubs.isEmpty && exportUsage.isEmpty {
            throw ExportError.noData
        }

        // Build payload
        let payload = FinanceExportEngine.buildPayload(
            subscriptions: exportSubs,
            usageRecords: exportUsage,
            period: period,
            cashReserve: cashReserve,
            currencyCode: currencyCode,
            now: now
        )

        // Generate output
        let data: Data
        let defaultFilename: String
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        switch format {
        case .csv:
            let csv = FinanceExportEngine.generateCSV(from: payload, includeUsage: includeUsage)
            data = Data(csv.utf8)
            defaultFilename = "SubsTracker-Export-\(df.string(from: now)).csv"

        case .json:
            let jsonDict = FinanceExportEngine.generateJSON(from: payload, includeUsage: includeUsage)
            data = try JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted, .sortedKeys])
            defaultFilename = "SubsTracker-Export-\(df.string(from: now)).json"
        }

        // Show save dialog and write
        return try await saveFile(data: data, defaultFilename: defaultFilename, fileExtension: format.fileExtension)
    }

    // MARK: - File Save

    @MainActor
    private static func saveFile(data: Data, defaultFilename: String, fileExtension: String) async throws -> URL {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename
        panel.allowedContentTypes = fileExtension == "csv"
            ? [.commaSeparatedText]
            : [.json]
        panel.canCreateDirectories = true

        let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? NSPanel())

        guard response == .OK, let url = panel.url else {
            throw ExportError.cancelled
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }

        return url
    }
}
