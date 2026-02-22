import XCTest

// MARK: - Monthly Projection Tests

final class MonthlyProjectionTests: XCTestCase {

    func testMonthly_StaleByOneMonth_AdvancesOnce() {
        // Renewal was Jan 15, now is Feb 15 → projected to Feb 15 (1 cycle)
        let renewal = makeDate(2026, 1, 15)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .monthly, now: now)

        XCTAssertEqual(result.projectedDate, makeDate(2026, 2, 15))
        XCTAssertTrue(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 1)
    }

    func testMonthly_StaleByMultipleMonths() {
        // Renewal was Jun 10, 2025, now is Feb 15, 2026
        // Jun→Jul→Aug→Sep→Oct→Nov→Dec→Jan→Feb = 8 cycles → Feb 10 < Feb 15 → Mar 10 = 9 cycles
        let renewal = makeDate(2025, 6, 10)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .monthly, now: now)

        XCTAssertEqual(result.projectedDate, makeDate(2026, 3, 10))
        XCTAssertTrue(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 9)
    }

    func testMonthly_EndOfMonth_Jan31() {
        // Jan 31 + 1 month = Feb 28 (non-leap). Now is Mar 1 → Feb 28 < Mar 1 → Mar 28
        let renewal = makeDate(2025, 1, 31)
        let now = makeDate(2025, 3, 1)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .monthly, now: now)

        XCTAssertTrue(result.projectedDate >= now)
        XCTAssertTrue(result.wasStale)
    }

    func testMonthly_LeapYear_Feb29() {
        // Renewal on Feb 29 (leap year 2024). Now is Mar 15, 2026.
        // Feb 29 → Mar 29 → ... advancing until >= now
        let renewal = makeDate(2024, 2, 29)
        let now = makeDate(2026, 3, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .monthly, now: now)

        XCTAssertTrue(result.projectedDate >= now)
        XCTAssertTrue(result.wasStale)
        XCTAssertGreaterThan(result.cyclesAdvanced, 12)
    }
}

// MARK: - Weekly Projection Tests

final class WeeklyProjectionTests: XCTestCase {

    func testWeekly_StaleByTwoWeeks() {
        // Renewal was Feb 1, now is Feb 15 → Feb 1 + 7 = Feb 8 + 7 = Feb 15 (2 cycles)
        let renewal = makeDate(2026, 2, 1)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .weekly, now: now)

        XCTAssertEqual(result.projectedDate, makeDate(2026, 2, 15))
        XCTAssertTrue(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 2)
    }

    func testWeekly_ProjectedWithinSevenDays() {
        // Any stale weekly should project to within 7 days of now
        let renewal = makeDate(2025, 1, 6) // far past
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .weekly, now: now)

        let daysDiff = Calendar.current.dateComponents([.day], from: now, to: result.projectedDate).day!
        XCTAssertTrue(daysDiff >= 0 && daysDiff < 7)
        XCTAssertTrue(result.wasStale)
    }
}

// MARK: - Annual Projection Tests

final class AnnualProjectionTests: XCTestCase {

    func testAnnual_StaleByOneYear() {
        let renewal = makeDate(2025, 2, 15)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .annual, now: now)

        XCTAssertEqual(result.projectedDate, makeDate(2026, 2, 15))
        XCTAssertTrue(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 1)
    }

    func testAnnual_StaleByMultipleYears() {
        let renewal = makeDate(2020, 6, 1)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .annual, now: now)

        XCTAssertEqual(result.projectedDate, makeDate(2026, 6, 1))
        XCTAssertTrue(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 6)
    }
}

// MARK: - Boundary Tests

final class ProjectionBoundaryTests: XCTestCase {

    func testFutureDate_Unchanged() {
        let renewal = makeDate(2026, 3, 10)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .monthly, now: now)

        XCTAssertEqual(result.projectedDate, makeDate(2026, 3, 10))
        XCTAssertFalse(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 0)
    }

    func testDateExactlyToday_NotStale() {
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: now, billingCycle: .monthly, now: now)

        XCTAssertEqual(result.projectedDate, now)
        XCTAssertFalse(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 0)
    }

    func testDateYesterday_AdvancesOneCycle() {
        let renewal = makeDate(2026, 2, 14)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .monthly, now: now)

        XCTAssertEqual(result.projectedDate, makeDate(2026, 3, 14))
        XCTAssertTrue(result.wasStale)
        XCTAssertEqual(result.cyclesAdvanced, 1)
    }

    func testLoopGuard_VeryOldDate() {
        // Weekly from 2000 — would be ~1300 cycles, exceeding the 1000 limit
        let renewal = makeDate(2000, 1, 1)
        let now = makeDate(2026, 2, 15)
        let result = RenewalProjectionEngine.projectRenewalDate(from: renewal, billingCycle: .weekly, now: now)

        // Should cap at maxCycles and return whatever date was reached
        XCTAssertTrue(result.cyclesAdvanced <= RenewalProjectionEngine.maxCycles)
    }
}

// MARK: - Batch / Stale Count Tests

final class StaleCountTests: XCTestCase {

    func testStaleCount_MixedDates() {
        let now = makeDate(2026, 2, 15)
        let entries: [(date: Date, billingCycle: BillingCycle)] = [
            (makeDate(2025, 6, 1), .monthly),   // stale
            (makeDate(2026, 3, 1), .monthly),   // future
            (makeDate(2025, 1, 1), .annual),    // stale
            (makeDate(2026, 2, 15), .weekly)    // today = not stale
        ]
        let count = RenewalProjectionEngine.staleCount(renewalDates: entries, now: now)
        XCTAssertEqual(count, 2)
    }

    func testStaleCount_AllFresh() {
        let now = makeDate(2026, 2, 15)
        let entries: [(date: Date, billingCycle: BillingCycle)] = [
            (makeDate(2026, 3, 1), .monthly),
            (makeDate(2026, 2, 20), .weekly)
        ]
        let count = RenewalProjectionEngine.staleCount(renewalDates: entries, now: now)
        XCTAssertEqual(count, 0)
    }

    func testStaleCount_Empty() {
        let count = RenewalProjectionEngine.staleCount(renewalDates: [], now: Date())
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Test Helpers

private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}
