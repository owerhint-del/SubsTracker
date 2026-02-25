import Foundation

/// Pure calculation engine for Gmail scan quality telemetry.
/// No file I/O, SwiftData, or UI dependencies — fully testable.
enum ScanQualityEngine {

    // MARK: - Log Entry (one per candidate per scan)

    struct ScanQualityEntry: Codable {
        let scanId: String
        let timestamp: Date
        let serviceName: String
        let predictedChargeType: String
        let predictedStatus: String
        let aiConfidence: Double
        let lifecycleConfidence: Double?
        let hasCancelSignalSubject: Bool
        let hasCancelSignalSnippet: Bool
        let hasCancelSignalBody: Bool
        let hasBillingSignal: Bool
        let wasExistingSubscription: Bool
        // Outcome fields (filled after user/auto action)
        var outcome: String?
        var resultingStatus: String?
        var wasReactivation: Bool?
    }

    // MARK: - Weekly Metrics

    struct WeeklyQualityMetrics {
        let periodStart: Date
        let periodEnd: Date
        let totalCandidates: Int
        let cancelPredictions: Int
        let cancelSelected: Int
        let cancelIgnored: Int
        let reactivations: Int
        let unknownStatusCount: Int
        let unknownTypeCount: Int
        let bodyOnlyCancelCount: Int

        var cancelPrecisionProxy: Double {
            guard cancelSelected + cancelIgnored > 0 else { return 1.0 }
            return Double(cancelSelected) / Double(cancelSelected + cancelIgnored)
        }

        var falsePositiveProxy: Double {
            guard totalCandidates > 0 else { return 0 }
            return Double(cancelIgnored) / Double(totalCandidates)
        }

        var unknownRate: Double {
            guard totalCandidates > 0 else { return 0 }
            return Double(unknownStatusCount + unknownTypeCount) / Double(totalCandidates)
        }
    }

    // MARK: - Alerts

    enum AlertType: String, Codable {
        case precisionDrop = "precision_drop"
        case falsePositiveSpike = "false_positive_spike"
        case unknownSpike = "unknown_spike"
    }

    struct QualityAlert: Codable {
        let type: AlertType
        let message: String
        let metric: Double
        let threshold: Double
    }

    // MARK: - Thresholds

    static let cancelPrecisionThreshold = 0.90
    static let falsePositiveThreshold = 0.10
    static let unknownRateThreshold = 0.30

    // MARK: - Weekly Aggregation

    static func computeWeeklyMetrics(entries: [ScanQualityEntry], weekOf: Date) -> WeeklyQualityMetrics {
        let calendar = Calendar.current
        let weekStart = calendar.startOfDay(for: weekOf)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

        let filtered = entries.filter { $0.timestamp >= weekStart && $0.timestamp < weekEnd }

        let cancelPredictions = filtered.filter { $0.predictedStatus == SubscriptionStatus.canceled.rawValue }
        let cancelSelected = cancelPredictions.filter { $0.outcome == "selected" || $0.outcome == "auto_applied" }
        let cancelIgnored = cancelPredictions.filter { $0.outcome == "ignored" || $0.outcome == "auto_skipped" }

        let reactivations = filtered.filter { $0.wasReactivation == true }.count
        // Unknown type: charge type classification failed entirely
        let unknownType = filtered.filter { $0.predictedChargeType == ChargeType.unknown.rawValue }.count
        // Unknown status: charge type is known-recurring but lifecycle has no confidence data
        // (mutually exclusive with unknownType — no double-count)
        let unknownStatus = filtered.filter {
            $0.predictedChargeType != ChargeType.unknown.rawValue
            && $0.predictedChargeType == ChargeType.recurringSubscription.rawValue
            && $0.lifecycleConfidence == nil
        }.count

        // Body-only cancel: has body signal but no subject or snippet signal
        let bodyOnlyCancel = filtered.filter {
            $0.hasCancelSignalBody && !$0.hasCancelSignalSubject && !$0.hasCancelSignalSnippet
        }.count

        return WeeklyQualityMetrics(
            periodStart: weekStart,
            periodEnd: weekEnd,
            totalCandidates: filtered.count,
            cancelPredictions: cancelPredictions.count,
            cancelSelected: cancelSelected.count,
            cancelIgnored: cancelIgnored.count,
            reactivations: reactivations,
            unknownStatusCount: unknownStatus,
            unknownTypeCount: unknownType,
            bodyOnlyCancelCount: bodyOnlyCancel
        )
    }

    // MARK: - Alert Checks

    static func checkAlerts(metrics: WeeklyQualityMetrics) -> [QualityAlert] {
        var alerts: [QualityAlert] = []

        // Only check cancel precision if there were cancel predictions with outcomes
        if metrics.cancelSelected + metrics.cancelIgnored > 0 {
            if metrics.cancelPrecisionProxy < cancelPrecisionThreshold {
                alerts.append(QualityAlert(
                    type: .precisionDrop,
                    message: String(format: "Cancel precision proxy %.2f < threshold %.2f", metrics.cancelPrecisionProxy, cancelPrecisionThreshold),
                    metric: metrics.cancelPrecisionProxy,
                    threshold: cancelPrecisionThreshold
                ))
            }
        }

        if metrics.totalCandidates > 0 && metrics.falsePositiveProxy > falsePositiveThreshold {
            alerts.append(QualityAlert(
                type: .falsePositiveSpike,
                message: String(format: "False positive proxy %.2f > threshold %.2f", metrics.falsePositiveProxy, falsePositiveThreshold),
                metric: metrics.falsePositiveProxy,
                threshold: falsePositiveThreshold
            ))
        }

        if metrics.totalCandidates > 0 && metrics.unknownRate > unknownRateThreshold {
            alerts.append(QualityAlert(
                type: .unknownSpike,
                message: String(format: "Unknown rate %.2f > threshold %.2f", metrics.unknownRate, unknownRateThreshold),
                metric: metrics.unknownRate,
                threshold: unknownRateThreshold
            ))
        }

        return alerts
    }

    // MARK: - Report Generation (PII-free)

    static func generateReport(entries: [ScanQualityEntry], from: Date, to: Date) -> [String: Any] {
        let filtered = entries.filter { $0.timestamp >= from && $0.timestamp < to }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]

        // Group by scanId to build scan-level summary
        let scanGroups = Dictionary(grouping: filtered) { $0.scanId }
        let scans: [[String: Any]] = scanGroups.map { (scanId, group) in
            let earliest = group.min(by: { $0.timestamp < $1.timestamp })!.timestamp
            return [
                "scan_id": scanId,
                "timestamp": df.string(from: earliest),
                "candidate_count": group.count
            ]
        }.sorted { ($0["timestamp"] as? String ?? "") < ($1["timestamp"] as? String ?? "") }

        // Compute weekly metrics for the period
        let calendar = Calendar.current
        var allMetrics: [WeeklyQualityMetrics] = []
        var weekStart = calendar.startOfDay(for: from)
        while weekStart < to {
            let metrics = computeWeeklyMetrics(entries: filtered, weekOf: weekStart)
            if metrics.totalCandidates > 0 {
                allMetrics.append(metrics)
            }
            weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        }

        // Aggregate all metrics across weeks
        let totalCandidates = filtered.count
        let cancelPredictions = filtered.filter { $0.predictedStatus == SubscriptionStatus.canceled.rawValue }.count
        let cancelSelected = filtered.filter {
            $0.predictedStatus == SubscriptionStatus.canceled.rawValue && ($0.outcome == "selected" || $0.outcome == "auto_applied")
        }.count
        let cancelIgnored = filtered.filter {
            $0.predictedStatus == SubscriptionStatus.canceled.rawValue && ($0.outcome == "ignored" || $0.outcome == "auto_skipped")
        }.count
        let reactivations = filtered.filter { $0.wasReactivation == true }.count
        let unknownType = filtered.filter { $0.predictedChargeType == ChargeType.unknown.rawValue }.count
        let unknownStatus = filtered.filter {
            $0.predictedChargeType != ChargeType.unknown.rawValue
            && $0.predictedChargeType == ChargeType.recurringSubscription.rawValue
            && $0.lifecycleConfidence == nil
        }.count
        let bodyOnlyCancel = filtered.filter { $0.hasCancelSignalBody && !$0.hasCancelSignalSubject && !$0.hasCancelSignalSnippet }.count

        let cancelPrecision: Double = (cancelSelected + cancelIgnored > 0) ? Double(cancelSelected) / Double(cancelSelected + cancelIgnored) : 1.0
        let falsePositive: Double = totalCandidates > 0 ? Double(cancelIgnored) / Double(totalCandidates) : 0
        let unknownRate: Double = totalCandidates > 0 ? Double(unknownStatus + unknownType) / Double(totalCandidates) : 0

        // Gather alerts from all weekly metrics
        var allAlerts: [[String: Any]] = []
        for weekMetrics in allMetrics {
            for alert in checkAlerts(metrics: weekMetrics) {
                allAlerts.append([
                    "type": alert.type.rawValue,
                    "message": alert.message,
                    "metric": alert.metric,
                    "threshold": alert.threshold
                ])
            }
        }

        let report: [String: Any] = [
            "period": [
                "start": df.string(from: from),
                "end": df.string(from: to)
            ],
            "total_candidates": totalCandidates,
            "metrics": [
                "cancel_predictions": cancelPredictions,
                "cancel_selected": cancelSelected,
                "cancel_ignored": cancelIgnored,
                "cancel_precision_proxy": round(cancelPrecision * 100) / 100,
                "false_positive_proxy": round(falsePositive * 100) / 100,
                "reactivations": reactivations,
                "unknown_status_count": unknownStatus,
                "unknown_type_count": unknownType,
                "unknown_rate": round(unknownRate * 100) / 100,
                "body_only_cancel_count": bodyOnlyCancel
            ],
            "alerts": allAlerts,
            "scan_count": scanGroups.count,
            "scans": scans
        ]

        return report
    }

    // MARK: - CSV Report

    static func generateCSVReport(entries: [ScanQualityEntry], from: Date, to: Date) -> String {
        let filtered = entries.filter { $0.timestamp >= from && $0.timestamp < to }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("scan_id,timestamp,service_name,predicted_charge_type,predicted_status,ai_confidence,lifecycle_confidence,has_cancel_subject,has_cancel_snippet,has_cancel_body,has_billing_signal,was_existing,outcome,resulting_status,was_reactivation")

        for entry in filtered.sorted(by: { $0.timestamp < $1.timestamp }) {
            let lc = entry.lifecycleConfidence.map { String(format: "%.2f", $0) } ?? ""
            let outcome = entry.outcome ?? ""
            let resultingStatus = entry.resultingStatus ?? ""
            let wasReact = entry.wasReactivation.map { $0 ? "true" : "false" } ?? ""

            lines.append([
                entry.scanId,
                df.string(from: entry.timestamp),
                FinanceExportEngine.escapeCSV(entry.serviceName),
                entry.predictedChargeType,
                entry.predictedStatus,
                String(format: "%.2f", entry.aiConfidence),
                lc,
                entry.hasCancelSignalSubject ? "true" : "false",
                entry.hasCancelSignalSnippet ? "true" : "false",
                entry.hasCancelSignalBody ? "true" : "false",
                entry.hasBillingSignal ? "true" : "false",
                entry.wasExistingSubscription ? "true" : "false",
                outcome,
                resultingStatus,
                wasReact
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }
}
