import XCTest

// MARK: - Weekly Metrics Tests

final class ScanQualityMetricsTests: XCTestCase {

    func testWeeklyMetrics_EmptyEntries() {
        let weekStart = makeDate(2026, 2, 17)
        let metrics = ScanQualityEngine.computeWeeklyMetrics(entries: [], weekOf: weekStart)

        XCTAssertEqual(metrics.totalCandidates, 0)
        XCTAssertEqual(metrics.cancelPredictions, 0)
        XCTAssertEqual(metrics.cancelSelected, 0)
        XCTAssertEqual(metrics.cancelIgnored, 0)
        XCTAssertEqual(metrics.reactivations, 0)
        // Precision defaults to 1.0 when no cancel predictions
        XCTAssertEqual(metrics.cancelPrecisionProxy, 1.0)
        XCTAssertEqual(metrics.falsePositiveProxy, 0)
        XCTAssertEqual(metrics.unknownRate, 0)
    }

    func testWeeklyMetrics_MixedOutcomes() {
        let weekStart = makeDate(2026, 2, 17)
        let entries = [
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Netflix", status: "canceled", outcome: "selected"),
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Hulu", status: "canceled", outcome: "ignored"),
            makeEntry(timestamp: makeDate(2026, 2, 19), serviceName: "Spotify", status: "active", outcome: "auto_applied"),
            makeEntry(timestamp: makeDate(2026, 2, 19), serviceName: "Disney+", status: "canceled", outcome: "auto_applied"),
        ]

        let metrics = ScanQualityEngine.computeWeeklyMetrics(entries: entries, weekOf: weekStart)

        XCTAssertEqual(metrics.totalCandidates, 4)
        XCTAssertEqual(metrics.cancelPredictions, 3)
        // Selected: Netflix + Disney+, Ignored: Hulu
        XCTAssertEqual(metrics.cancelSelected, 2)
        XCTAssertEqual(metrics.cancelIgnored, 1)
        // Precision: 2 / (2 + 1) = 0.667
        XCTAssertEqual(metrics.cancelPrecisionProxy, 2.0 / 3.0, accuracy: 0.01)
        // FP: 1 / 4 = 0.25
        XCTAssertEqual(metrics.falsePositiveProxy, 0.25, accuracy: 0.01)
    }

    func testWeeklyMetrics_BodyOnlyCancelCounting() {
        let weekStart = makeDate(2026, 2, 17)
        let entries = [
            // Body-only cancel signal (subject and snippet are false)
            makeEntry(
                timestamp: makeDate(2026, 2, 18),
                serviceName: "ServiceA",
                hasCancelSubject: false,
                hasCancelSnippet: false,
                hasCancelBody: true
            ),
            // Subject cancel signal (not body-only)
            makeEntry(
                timestamp: makeDate(2026, 2, 18),
                serviceName: "ServiceB",
                hasCancelSubject: true,
                hasCancelSnippet: false,
                hasCancelBody: true
            ),
            // No cancel signal at all
            makeEntry(
                timestamp: makeDate(2026, 2, 19),
                serviceName: "ServiceC",
                hasCancelSubject: false,
                hasCancelSnippet: false,
                hasCancelBody: false
            ),
        ]

        let metrics = ScanQualityEngine.computeWeeklyMetrics(entries: entries, weekOf: weekStart)
        XCTAssertEqual(metrics.bodyOnlyCancelCount, 1)
    }

    func testWeeklyMetrics_DateFiltering() {
        let weekStart = makeDate(2026, 2, 17)
        let entries = [
            // Inside week
            makeEntry(timestamp: makeDate(2026, 2, 17), serviceName: "InWeek1"),
            makeEntry(timestamp: makeDate(2026, 2, 23), serviceName: "InWeek2"),
            // Outside week
            makeEntry(timestamp: makeDate(2026, 2, 16), serviceName: "BeforeWeek"),
            makeEntry(timestamp: makeDate(2026, 2, 24), serviceName: "AfterWeek"),
        ]

        let metrics = ScanQualityEngine.computeWeeklyMetrics(entries: entries, weekOf: weekStart)
        XCTAssertEqual(metrics.totalCandidates, 2)
    }
}

// MARK: - Alert Threshold Tests

final class ScanQualityAlertTests: XCTestCase {

    func testAlert_LowPrecision() {
        let metrics = ScanQualityEngine.WeeklyQualityMetrics(
            periodStart: makeDate(2026, 2, 17),
            periodEnd: makeDate(2026, 2, 24),
            totalCandidates: 10,
            cancelPredictions: 5,
            cancelSelected: 2,
            cancelIgnored: 3,
            reactivations: 0,
            unknownStatusCount: 0,
            unknownTypeCount: 0,
            bodyOnlyCancelCount: 0
        )

        let alerts = ScanQualityEngine.checkAlerts(metrics: metrics)
        XCTAssertTrue(alerts.contains { $0.type == .precisionDrop })
        // precision = 2/(2+3) = 0.40, which is < 0.90
        let precisionAlert = alerts.first { $0.type == .precisionDrop }!
        XCTAssertEqual(precisionAlert.metric, 0.40, accuracy: 0.01)
        XCTAssertEqual(precisionAlert.threshold, 0.90)
    }

    func testAlert_HighFalsePositive() {
        let metrics = ScanQualityEngine.WeeklyQualityMetrics(
            periodStart: makeDate(2026, 2, 17),
            periodEnd: makeDate(2026, 2, 24),
            totalCandidates: 10,
            cancelPredictions: 3,
            cancelSelected: 1,
            cancelIgnored: 2,
            reactivations: 0,
            unknownStatusCount: 0,
            unknownTypeCount: 0,
            bodyOnlyCancelCount: 0
        )

        let alerts = ScanQualityEngine.checkAlerts(metrics: metrics)
        // FP = 2/10 = 0.20 > 0.10
        XCTAssertTrue(alerts.contains { $0.type == .falsePositiveSpike })
        let fpAlert = alerts.first { $0.type == .falsePositiveSpike }!
        XCTAssertEqual(fpAlert.metric, 0.20, accuracy: 0.01)
    }

    func testAlert_HighUnknownRate() {
        // unknownStatusCount and unknownTypeCount are now mutually exclusive
        let metrics = ScanQualityEngine.WeeklyQualityMetrics(
            periodStart: makeDate(2026, 2, 17),
            periodEnd: makeDate(2026, 2, 24),
            totalCandidates: 10,
            cancelPredictions: 0,
            cancelSelected: 0,
            cancelIgnored: 0,
            reactivations: 0,
            unknownStatusCount: 1,  // known type, no lifecycle confidence
            unknownTypeCount: 3,    // unknown charge type
            bodyOnlyCancelCount: 0
        )

        let alerts = ScanQualityEngine.checkAlerts(metrics: metrics)
        // unknownRate = (1+3)/10 = 0.40 > 0.30
        XCTAssertTrue(alerts.contains { $0.type == .unknownSpike })
        let unknownAlert = alerts.first { $0.type == .unknownSpike }!
        XCTAssertEqual(unknownAlert.metric, 0.40, accuracy: 0.01)
    }

    func testUnknownRate_NoDoubleCount() {
        // Regression test: entries with unknown type must NOT be double-counted
        // in unknownStatusCount. The two counts are mutually exclusive.
        let weekStart = makeDate(2026, 2, 17)

        let entries = [
            // Entry with unknown type — should count in unknownTypeCount only
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Mystery", chargeType: "unknown", status: "active"),
            // Entry with known recurring type but no lifecycle confidence — unknownStatusCount
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Netflix", chargeType: "recurring_subscription", status: "active", lifecycleConfidence: nil),
            // Entry with known type AND lifecycle confidence — neither count
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Spotify", chargeType: "recurring_subscription", status: "active", lifecycleConfidence: 0.95),
            // Entry with known non-recurring type — neither count
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Domain", chargeType: "one_time_purchase", status: "active"),
        ]

        let metrics = ScanQualityEngine.computeWeeklyMetrics(entries: entries, weekOf: weekStart)

        XCTAssertEqual(metrics.unknownTypeCount, 1, "Only 'Mystery' has unknown charge type")
        XCTAssertEqual(metrics.unknownStatusCount, 1, "Only 'Netflix' has known type but no lifecycle confidence")
        // unknownRate = (1 + 1) / 4 = 0.50 — no double counting
        XCTAssertEqual(metrics.unknownRate, 0.50, accuracy: 0.01)
        XCTAssertEqual(metrics.totalCandidates, 4)

        // Before the fix, unknownStatusCount would have been 1 (active+unknown)
        // AND unknownTypeCount would have been 1 (unknown), but the Mystery entry
        // would have been counted in BOTH, giving unknownRate = (1+1)/4 = 0.50.
        // With only unknown-type entries, the old code gave (1+1)/4 = 0.50 because
        // the subset was counted twice. This test ensures the counts are orthogonal.
    }
}

// MARK: - Sanitization Test

final class ScanQualityExportTests: XCTestCase {

    func testExportJSON_NoPII() {
        let entries = [
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Netflix"),
            makeEntry(timestamp: makeDate(2026, 2, 19), serviceName: "Spotify"),
        ]

        let report = ScanQualityEngine.generateReport(
            entries: entries,
            from: makeDate(2026, 2, 17),
            to: makeDate(2026, 2, 24)
        )

        // Convert to JSON string for inspection
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
        let jsonString = String(data: data, encoding: .utf8)!

        // Should NOT contain email addresses, subjects, snippets, or body content
        XCTAssertFalse(jsonString.contains("@"))
        XCTAssertFalse(jsonString.contains("subject"))
        XCTAssertFalse(jsonString.contains("snippet"))
        XCTAssertFalse(jsonString.contains("body_text"))
        XCTAssertFalse(jsonString.contains("email"))

        // Should contain expected aggregate keys
        XCTAssertTrue(jsonString.contains("total_candidates"))
        XCTAssertTrue(jsonString.contains("cancel_predictions"))
        XCTAssertTrue(jsonString.contains("scan_count"))
    }

    func testGenerateReport_CorrectStructure() {
        let entries = [
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Netflix", scanId: "scan-1"),
            makeEntry(timestamp: makeDate(2026, 2, 18), serviceName: "Spotify", scanId: "scan-1"),
            makeEntry(timestamp: makeDate(2026, 2, 20), serviceName: "Hulu", scanId: "scan-2"),
        ]

        let report = ScanQualityEngine.generateReport(
            entries: entries,
            from: makeDate(2026, 2, 17),
            to: makeDate(2026, 2, 24)
        )

        // Top-level keys
        XCTAssertNotNil(report["period"])
        XCTAssertNotNil(report["total_candidates"])
        XCTAssertNotNil(report["metrics"])
        XCTAssertNotNil(report["alerts"])
        XCTAssertNotNil(report["scan_count"])
        XCTAssertNotNil(report["scans"])

        XCTAssertEqual(report["total_candidates"] as? Int, 3)
        XCTAssertEqual(report["scan_count"] as? Int, 2)

        // Period structure
        let period = report["period"] as? [String: String]
        XCTAssertNotNil(period?["start"])
        XCTAssertNotNil(period?["end"])

        // Metrics structure
        let metrics = report["metrics"] as? [String: Any]
        XCTAssertNotNil(metrics?["cancel_predictions"])
        XCTAssertNotNil(metrics?["cancel_precision_proxy"])
        XCTAssertNotNil(metrics?["false_positive_proxy"])
        XCTAssertNotNil(metrics?["unknown_rate"])
        XCTAssertNotNil(metrics?["body_only_cancel_count"])

        // Scans structure
        let scans = report["scans"] as? [[String: Any]]
        XCTAssertEqual(scans?.count, 2)
        if let firstScan = scans?.first {
            XCTAssertNotNil(firstScan["scan_id"])
            XCTAssertNotNil(firstScan["timestamp"])
            XCTAssertNotNil(firstScan["candidate_count"])
        }
    }
}

// MARK: - Test Helpers

private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    return Calendar.current.date(from: components)!
}

private func makeEntry(
    timestamp: Date = Date(),
    serviceName: String = "TestService",
    chargeType: String = "recurring_subscription",
    status: String = "active",
    aiConfidence: Double = 0.85,
    lifecycleConfidence: Double? = nil,
    hasCancelSubject: Bool = false,
    hasCancelSnippet: Bool = false,
    hasCancelBody: Bool = false,
    hasBillingSignal: Bool = true,
    wasExisting: Bool = false,
    outcome: String? = nil,
    resultingStatus: String? = nil,
    wasReactivation: Bool? = nil,
    scanId: String = "test-scan-id"
) -> ScanQualityEngine.ScanQualityEntry {
    ScanQualityEngine.ScanQualityEntry(
        scanId: scanId,
        timestamp: timestamp,
        serviceName: serviceName,
        predictedChargeType: chargeType,
        predictedStatus: status,
        aiConfidence: aiConfidence,
        lifecycleConfidence: lifecycleConfidence,
        hasCancelSignalSubject: hasCancelSubject,
        hasCancelSignalSnippet: hasCancelSnippet,
        hasCancelSignalBody: hasCancelBody,
        hasBillingSignal: hasBillingSignal,
        wasExistingSubscription: wasExisting,
        outcome: outcome,
        resultingStatus: resultingStatus,
        wasReactivation: wasReactivation
    )
}
