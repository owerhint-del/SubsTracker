import XCTest

// MARK: - Period Helpers Tests

final class ExportPeriodTests: XCTestCase {

    func testCurrentMonthPeriod_StartsAtFirstOfMonth() {
        let now = makeDate(2026, 2, 15)
        let period = FinanceExportEngine.currentMonthPeriod(now: now)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.day, from: period.start), 1)
        XCTAssertEqual(cal.component(.month, from: period.start), 2)
    }

    func testCurrentMonthPeriod_EndsAtFirstOfNextMonth() {
        let now = makeDate(2026, 2, 15)
        let period = FinanceExportEngine.currentMonthPeriod(now: now)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.month, from: period.end), 3)
        XCTAssertEqual(cal.component(.day, from: period.end), 1)
    }

    func testLast30DaysPeriod() {
        let now = makeDate(2026, 3, 15)
        let period = FinanceExportEngine.lastNDaysPeriod(days: 30, now: now)
        let cal = Calendar.current
        let diff = cal.dateComponents([.day], from: period.start, to: now).day!
        XCTAssertEqual(diff, 30)
    }
}

// MARK: - Summary Calculation Tests

final class ExportSummaryTests: XCTestCase {

    func testRecurringSpend_MonthlyOnly() {
        let subs = [
            makeSub("Netflix", cost: 15.99, cycle: .monthly),
            makeSub("Spotify", cost: 9.99, cycle: .monthly)
        ]
        let summary = FinanceExportEngine.computeSummary(
            subscriptions: subs, usageRecords: [], cashReserve: 0, now: Date()
        )
        XCTAssertEqual(summary.recurringMonthlySpend, 25.98, accuracy: 0.01)
    }

    func testRecurringSpend_MixedCycles() {
        let subs = [
            makeSub("Weekly", cost: 10, cycle: .weekly),
            makeSub("Annual", cost: 120, cycle: .annual)
        ]
        let summary = FinanceExportEngine.computeSummary(
            subscriptions: subs, usageRecords: [], cashReserve: 0, now: Date()
        )
        // Weekly: 10 * 52/12 = 43.33; Annual: 120/12 = 10; Total = 53.33
        XCTAssertEqual(summary.recurringMonthlySpend, 53.33, accuracy: 0.01)
    }

    func testVariableSpend_SumsUsageCosts() {
        let usage = [
            makeUsage(date: Date(), cost: 5.50, name: "OpenAI"),
            makeUsage(date: Date(), cost: 3.25, name: "OpenAI")
        ]
        let summary = FinanceExportEngine.computeSummary(
            subscriptions: [], usageRecords: usage, cashReserve: 0, now: Date()
        )
        XCTAssertEqual(summary.variableSpend, 8.75, accuracy: 0.01)
    }

    func testTotalSpend_RecurringPlusVariable() {
        let subs = [makeSub("Netflix", cost: 20, cycle: .monthly)]
        let usage = [makeUsage(date: Date(), cost: 10, name: "OpenAI")]
        let summary = FinanceExportEngine.computeSummary(
            subscriptions: subs, usageRecords: usage, cashReserve: 0, now: Date()
        )
        XCTAssertEqual(summary.totalMonthlySpend, 30.0, accuracy: 0.01)
    }

    func testEmptyData_AllZeros() {
        let summary = FinanceExportEngine.computeSummary(
            subscriptions: [], usageRecords: [], cashReserve: 0, now: Date()
        )
        XCTAssertEqual(summary.recurringMonthlySpend, 0)
        XCTAssertEqual(summary.variableSpend, 0)
        XCTAssertEqual(summary.totalMonthlySpend, 0)
        XCTAssertEqual(summary.subscriptionCount, 0)
        XCTAssertEqual(summary.usageRecordCount, 0)
    }

    func testCounts_ReflectInput() {
        let subs = [makeSub("A", cost: 10, cycle: .monthly), makeSub("B", cost: 20, cycle: .monthly)]
        let usage = [makeUsage(date: Date(), cost: 1, name: "X")]
        let summary = FinanceExportEngine.computeSummary(
            subscriptions: subs, usageRecords: usage, cashReserve: 0, now: Date()
        )
        XCTAssertEqual(summary.subscriptionCount, 2)
        XCTAssertEqual(summary.usageRecordCount, 1)
    }
}

// MARK: - CSV Generation Tests

final class CSVGenerationTests: XCTestCase {

    func testCSV_ContainsHeaders() {
        let payload = makePayload(subs: [makeSub("Netflix", cost: 15.99, cycle: .monthly)])
        let csv = FinanceExportEngine.generateCSV(from: payload, includeUsage: false)

        XCTAssertTrue(csv.contains("SubsTracker Finance Export"))
        XCTAssertTrue(csv.contains("Currency,USD"))
        XCTAssertTrue(csv.contains("SUMMARY"))
        XCTAssertTrue(csv.contains("SUBSCRIPTIONS"))
        XCTAssertTrue(csv.contains("Name,Cost,Billing Cycle,Monthly Cost,Category,Renewal Date,Notes"))
    }

    func testCSV_ContainsSubscriptionRow() {
        let payload = makePayload(subs: [makeSub("Netflix", cost: 15.99, cycle: .monthly)])
        let csv = FinanceExportEngine.generateCSV(from: payload, includeUsage: false)
        XCTAssertTrue(csv.contains("Netflix,15.99,Monthly,15.99"))
    }

    func testCSV_IncludesUsageWhenRequested() {
        let usage = [makeUsage(date: Date(), cost: 5.0, name: "OpenAI")]
        let payload = makePayload(subs: [], usage: usage)
        let csvWith = FinanceExportEngine.generateCSV(from: payload, includeUsage: true)
        let csvWithout = FinanceExportEngine.generateCSV(from: payload, includeUsage: false)

        XCTAssertTrue(csvWith.contains("USAGE RECORDS"))
        XCTAssertTrue(csvWith.contains("Date,Subscription,Cost,Input Tokens,Output Tokens,Model"))
        XCTAssertFalse(csvWithout.contains("USAGE RECORDS"))
    }

    func testCSV_EscapesCommasInNotes() {
        let sub = FinanceExportEngine.ExportSubscription(
            name: "Test", cost: 10, billingCycle: .monthly,
            category: .other, renewalDate: Date(), notes: "hello, world"
        )
        let payload = makePayload(subs: [sub])
        let csv = FinanceExportEngine.generateCSV(from: payload, includeUsage: false)
        XCTAssertTrue(csv.contains("\"hello, world\""))
    }
}

// MARK: - JSON Generation Tests

final class JSONGenerationTests: XCTestCase {

    func testJSON_TopLevelKeys() {
        let payload = makePayload(subs: [makeSub("Netflix", cost: 15.99, cycle: .monthly)])
        let json = FinanceExportEngine.generateJSON(from: payload, includeUsage: false)

        XCTAssertNotNil(json["generated_at"])
        XCTAssertNotNil(json["currency"])
        XCTAssertNotNil(json["period"])
        XCTAssertNotNil(json["summary"])
        XCTAssertNotNil(json["subscriptions"])
    }

    func testJSON_CurrencyPropagation() {
        let payload = makePayload(subs: [], currencyCode: "EUR")
        let json = FinanceExportEngine.generateJSON(from: payload, includeUsage: false)
        XCTAssertEqual(json["currency"] as? String, "EUR")
    }

    func testJSON_IncludesUsageWhenRequested() {
        let usage = [makeUsage(date: Date(), cost: 5.0, name: "OpenAI")]
        let payload = makePayload(subs: [], usage: usage)
        let jsonWith = FinanceExportEngine.generateJSON(from: payload, includeUsage: true)
        let jsonWithout = FinanceExportEngine.generateJSON(from: payload, includeUsage: false)

        XCTAssertNotNil(jsonWith["usage_records"])
        XCTAssertNil(jsonWithout["usage_records"])
    }

    func testJSON_SummaryValues() {
        let subs = [makeSub("Netflix", cost: 20, cycle: .monthly)]
        let payload = makePayload(subs: subs)
        let json = FinanceExportEngine.generateJSON(from: payload, includeUsage: false)
        let summary = json["summary"] as? [String: Any]
        XCTAssertEqual(summary?["recurring_monthly_spend"] as? Double, 20.0)
        XCTAssertEqual(summary?["subscription_count"] as? Int, 1)
    }

    func testJSON_SerializesToValidData() throws {
        let subs = [makeSub("Test", cost: 9.99, cycle: .monthly)]
        let payload = makePayload(subs: subs)
        let json = FinanceExportEngine.generateJSON(from: payload, includeUsage: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        XCTAssertTrue(data.count > 0, "Should serialize to non-empty JSON data")
    }
}

// MARK: - Payload & Filtering Tests

final class PayloadFilteringTests: XCTestCase {

    func testPayload_FiltersUsageByPeriod() {
        let now = makeDate(2026, 2, 15)
        let inPeriod = makeUsage(date: makeDate(2026, 2, 10), cost: 5.0, name: "OpenAI")
        let outOfPeriod = makeUsage(date: makeDate(2026, 1, 5), cost: 10.0, name: "OpenAI")

        let period = FinanceExportEngine.currentMonthPeriod(now: now)
        let payload = FinanceExportEngine.buildPayload(
            subscriptions: [],
            usageRecords: [inPeriod, outOfPeriod],
            period: period,
            cashReserve: 0,
            currencyCode: "USD",
            now: now
        )

        XCTAssertEqual(payload.usageRecords.count, 1, "Only records within period should be included")
        XCTAssertEqual(payload.summary.variableSpend, 5.0, accuracy: 0.01)
    }

    func testPayload_BoundaryDate_StartInclusive() {
        let now = makeDate(2026, 2, 15)
        let period = FinanceExportEngine.currentMonthPeriod(now: now)
        let atStart = makeUsage(date: period.start, cost: 7.0, name: "OpenAI")

        let payload = FinanceExportEngine.buildPayload(
            subscriptions: [],
            usageRecords: [atStart],
            period: period,
            cashReserve: 0,
            currencyCode: "USD",
            now: now
        )

        XCTAssertEqual(payload.usageRecords.count, 1, "Start date should be inclusive")
    }

    func testPayload_BoundaryDate_EndExclusive() {
        let now = makeDate(2026, 2, 15)
        let period = FinanceExportEngine.currentMonthPeriod(now: now)
        let atEnd = makeUsage(date: period.end, cost: 7.0, name: "OpenAI")

        let payload = FinanceExportEngine.buildPayload(
            subscriptions: [],
            usageRecords: [atEnd],
            period: period,
            cashReserve: 0,
            currencyCode: "USD",
            now: now
        )

        XCTAssertEqual(payload.usageRecords.count, 0, "End date should be exclusive")
    }
}

// MARK: - Custom Period Tests

final class CustomPeriodTests: XCTestCase {

    func testCustomPeriod_EndDateIncludesWholeDay() {
        // User picks Feb 10 as end date — records on Feb 10 at any time should be included
        let start = makeDate(2026, 2, 1)
        let end = makeDate(2026, 2, 10)

        let period = FinanceExportEngine.customPeriod(start: start, end: end)
        XCTAssertNotNil(period)

        // End should be Feb 11 00:00 (start of next day, end-exclusive)
        let expectedEnd = makeDate(2026, 2, 11)
        XCTAssertEqual(period!.end, expectedEnd, "End should be start-of-day after the selected end date")

        // A record on Feb 10 afternoon should be included
        let afternoonRecord = makeUsage(
            date: Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: end)!,
            cost: 5.0, name: "OpenAI"
        )
        let payload = FinanceExportEngine.buildPayload(
            subscriptions: [], usageRecords: [afternoonRecord],
            period: period!, cashReserve: 0, currencyCode: "USD", now: makeDate(2026, 2, 15)
        )
        XCTAssertEqual(payload.usageRecords.count, 1, "Record on the end date should be included")
    }

    func testCustomPeriod_InvalidRange_ReturnsNil() {
        // End before start
        let result = FinanceExportEngine.customPeriod(
            start: makeDate(2026, 3, 15),
            end: makeDate(2026, 3, 10)
        )
        XCTAssertNil(result, "Reversed date range should return nil")
    }

    func testCustomPeriod_SameDay_IsValid() {
        // User picks same start and end (single day)
        let period = FinanceExportEngine.customPeriod(
            start: makeDate(2026, 2, 10),
            end: makeDate(2026, 2, 10)
        )
        XCTAssertNotNil(period, "Same-day range should be valid (covers one full day)")
        XCTAssertEqual(period!.start, makeDate(2026, 2, 10))
        XCTAssertEqual(period!.end, makeDate(2026, 2, 11))
    }
}

// MARK: - Edge Case Tests

final class ExportEdgeCaseTests: XCTestCase {

    func testZeroCostSubscription() {
        let subs = [makeSub("Free Tier", cost: 0, cycle: .monthly)]
        let summary = FinanceExportEngine.computeSummary(
            subscriptions: subs, usageRecords: [], cashReserve: 0, now: Date()
        )
        XCTAssertEqual(summary.recurringMonthlySpend, 0)
        XCTAssertEqual(summary.subscriptionCount, 1)
    }

    func testRoundToTwoCents() {
        XCTAssertEqual(FinanceExportEngine.roundToTwoCents(19.999), 20.0)
        XCTAssertEqual(FinanceExportEngine.roundToTwoCents(0.001), 0.0)
        XCTAssertEqual(FinanceExportEngine.roundToTwoCents(1.555), 1.56)
    }

    func testEscapeCSV_PlainString() {
        XCTAssertEqual(FinanceExportEngine.escapeCSV("hello"), "hello")
    }

    func testEscapeCSV_CommaString() {
        XCTAssertEqual(FinanceExportEngine.escapeCSV("hello, world"), "\"hello, world\"")
    }

    func testEscapeCSV_QuoteString() {
        XCTAssertEqual(FinanceExportEngine.escapeCSV("say \"hi\""), "\"say \"\"hi\"\"\"")
    }
}

// MARK: - Test Helpers

private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

private func makeSub(_ name: String, cost: Double, cycle: BillingCycle) -> FinanceExportEngine.ExportSubscription {
    FinanceExportEngine.ExportSubscription(
        name: name,
        cost: cost,
        billingCycle: cycle,
        category: .other,
        renewalDate: Date(),
        notes: nil
    )
}

private func makeUsage(date: Date, cost: Double, name: String) -> FinanceExportEngine.ExportUsageRecord {
    FinanceExportEngine.ExportUsageRecord(
        date: date,
        subscriptionName: name,
        cost: cost,
        inputTokens: 1000,
        outputTokens: 500,
        model: "gpt-4o"
    )
}

private func makePayload(
    subs: [FinanceExportEngine.ExportSubscription],
    usage: [FinanceExportEngine.ExportUsageRecord] = [],
    currencyCode: String = "USD"
) -> FinanceExportEngine.ExportPayload {
    let now = Date()
    let period = FinanceExportEngine.currentMonthPeriod(now: now)
    return FinanceExportEngine.buildPayload(
        subscriptions: subs,
        usageRecords: usage,
        period: period,
        cashReserve: 0,
        currencyCode: currencyCode,
        now: now
    )
}
