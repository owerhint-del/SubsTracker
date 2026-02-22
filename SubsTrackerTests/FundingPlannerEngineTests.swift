import XCTest

final class FundingPlannerEngineTests: XCTestCase {

    // Helper: create a date at midnight N days from now
    private func daysFromNow(_ days: Int, from base: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: base))!
    }

    // Fixed reference date for deterministic tests: 2026-02-15
    private var referenceDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 2
        components.day = 15
        return Calendar.current.date(from: components)!
    }

    // MARK: - Renewal Projection

    func testNextRenewalDate_MonthlyStale_AdvancesForward() {
        // Renewal was Jan 1, billing monthly — should advance to Feb 1, then Mar 1
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        let staleDate = Calendar.current.date(from: components)!

        let result = FundingPlannerEngine.nextRenewalDate(
            from: staleDate,
            billingCycle: .monthly,
            after: referenceDate
        )

        // Should be March 1 (Jan→Feb→Mar, since Feb 1 < Feb 15)
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        XCTAssertEqual(
            Calendar.current.startOfDay(for: result),
            Calendar.current.startOfDay(for: expected),
            "Monthly sub from Jan 1 should project to Mar 1 when reference is Feb 15"
        )
    }

    func testNextRenewalDate_WeeklyStale_AdvancesByWeeks() {
        // Renewal was Jan 5 (Monday), weekly
        let staleDate = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5))!

        let result = FundingPlannerEngine.nextRenewalDate(
            from: staleDate,
            billingCycle: .weekly,
            after: referenceDate
        )

        // Should be Feb 16 (Jan 5 + 6 weeks = Feb 16)
        XCTAssertTrue(
            result >= referenceDate,
            "Projected weekly renewal should be on or after reference date"
        )
        // Verify it's within 7 days after referenceDate (the next valid weekly slot)
        let daysDiff = Calendar.current.dateComponents([.day], from: referenceDate, to: result).day!
        XCTAssertTrue(daysDiff < 7, "Next weekly renewal should be within 7 days of reference")
    }

    func testNextRenewalDate_FutureDateUnchanged() {
        // Renewal is already in the future — should not change
        let futureDate = daysFromNow(10, from: referenceDate)

        let result = FundingPlannerEngine.nextRenewalDate(
            from: futureDate,
            billingCycle: .monthly,
            after: referenceDate
        )

        XCTAssertEqual(
            Calendar.current.startOfDay(for: result),
            Calendar.current.startOfDay(for: futureDate),
            "Future renewal date should remain unchanged"
        )
    }

    // MARK: - Projected Charges

    func testProjectedCharges_WeeklyProducesMultiple() {
        let sub = PlannerSubscription(
            name: "Weekly Service",
            cost: 10,
            billingCycle: .weekly,
            renewalDate: referenceDate
        )

        let charges = FundingPlannerEngine.projectedCharges(for: sub, from: referenceDate, days: 30)

        // Days 0, 7, 14, 21, 28 = 5 charges (first charge on day 0)
        XCTAssertEqual(charges.count, 5, "Weekly sub starting today should produce 5 charges in 30 days")
        XCTAssertEqual(charges.first?.amount, 10)
        XCTAssertTrue(charges.allSatisfy { $0.name == "Weekly Service" })
    }

    func testProjectedCharges_AnnualNotDue_ReturnsEmpty() {
        // Annual sub that renewed 2 months ago — next renewal in ~10 months
        let pastDate = Calendar.current.date(from: DateComponents(year: 2025, month: 12, day: 15))!
        let sub = PlannerSubscription(
            name: "Annual Pro",
            cost: 120,
            billingCycle: .annual,
            renewalDate: pastDate
        )

        let charges = FundingPlannerEngine.projectedCharges(for: sub, from: referenceDate, days: 30)

        XCTAssertTrue(charges.isEmpty, "Annual sub not due within 30 days should produce no charges")
    }

    func testProjectedCharges_MonthlyStaleDateProjectsForward() {
        // Monthly sub with stale renewal date (past)
        let staleDate = Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 10))!
        let sub = PlannerSubscription(
            name: "Stale Monthly",
            cost: 50,
            billingCycle: .monthly,
            renewalDate: staleDate
        )

        let charges = FundingPlannerEngine.projectedCharges(for: sub, from: referenceDate, days: 30)

        // Should project forward and find at least one charge in the 30-day window
        XCTAssertFalse(charges.isEmpty, "Stale monthly sub should project forward and produce charges")
        XCTAssertEqual(charges.first?.amount, 50)
    }

    // MARK: - API Spend Projection

    func testProjectedAPISpend_NoCosts_ReturnsZero() {
        let (total, lowConf) = FundingPlannerEngine.projectedAPISpend(
            costs: [],
            daysOfData: 30
        )

        XCTAssertEqual(total, 0, "No costs should project to zero")
        XCTAssertTrue(lowConf, "No data should flag low confidence")
    }

    func testProjectedAPISpend_NormalData() {
        // $3/day over 15 days = $45 total; projected over 30 days = $90
        let costs = Array(repeating: 3.0, count: 15)

        let (total, lowConf) = FundingPlannerEngine.projectedAPISpend(
            costs: costs,
            daysOfData: 15
        )

        XCTAssertEqual(total, 90, accuracy: 0.01, "Should extrapolate $3/day * 30 = $90")
        XCTAssertFalse(lowConf, "15 days of data is sufficient confidence")
    }

    func testProjectedAPISpend_FewDays_LowConfidence() {
        let costs = [5.0, 3.0]

        let (_, lowConf) = FundingPlannerEngine.projectedAPISpend(
            costs: costs,
            daysOfData: 2
        )

        XCTAssertTrue(lowConf, "< 5 days of data should flag low confidence")
    }

    // MARK: - Depletion Date

    func testDepletionDate_SufficientReserve_ReturnsNil() {
        let charges = [
            FundingCharge(name: "Sub A", amount: 50, date: daysFromNow(5, from: referenceDate)),
            FundingCharge(name: "Sub B", amount: 30, date: daysFromNow(20, from: referenceDate))
        ]

        let result = FundingPlannerEngine.depletionDate(
            charges: charges,
            dailyAPIRate: 1.0,
            reserve: 200,
            from: referenceDate
        )

        XCTAssertNil(result, "Reserve of 200 should cover 80 in charges + 30 in API = 110 total")
    }

    func testDepletionDate_InsufficientReserve_ReturnsDate() {
        // Reserve: 40, charge of 50 on day 5 → depleted on day 5
        let charges = [
            FundingCharge(name: "Sub A", amount: 50, date: daysFromNow(5, from: referenceDate))
        ]

        let result = FundingPlannerEngine.depletionDate(
            charges: charges,
            dailyAPIRate: 0,
            reserve: 40,
            from: referenceDate
        )

        XCTAssertNotNil(result, "Reserve of 40 cannot cover charge of 50")
        let expectedDate = daysFromNow(5, from: referenceDate)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: result!),
            Calendar.current.startOfDay(for: expectedDate),
            "Depletion should occur on day 5 when the 50 charge hits"
        )
    }

    func testDepletionDate_DailyAPIDrain() {
        // Reserve: 10, no charges, daily API rate 0.5 → depleted on day 20 (10/0.5 = 20)
        let result = FundingPlannerEngine.depletionDate(
            charges: [],
            dailyAPIRate: 0.5,
            reserve: 10,
            from: referenceDate
        )

        XCTAssertNotNil(result)
        let daysUntil = Calendar.current.dateComponents([.day], from: referenceDate, to: result!).day!
        XCTAssertEqual(daysUntil, 20, "10 reserve / 0.5 daily = depleted on day 20")
    }

    // MARK: - Full Calculation

    func testCalculate_NoSubscriptions_ZeroRequired() {
        let result = FundingPlannerEngine.calculate(
            subscriptions: [],
            usageCosts: [],
            usageDaysOfData: 0,
            cashReserve: 100,
            now: referenceDate
        )

        XCTAssertEqual(result.requiredNext30Days, 0, "No subs + no API = zero required")
        XCTAssertEqual(result.shortfall, 0, "No required = no shortfall")
        XCTAssertNil(result.depletionDate)
    }

    func testCalculate_MixedSubs_CorrectTotals() {
        let subs = [
            PlannerSubscription(
                name: "Monthly A",
                cost: 200,
                billingCycle: .monthly,
                renewalDate: daysFromNow(10, from: referenceDate)
            ),
            PlannerSubscription(
                name: "Weekly B",
                cost: 10,
                billingCycle: .weekly,
                renewalDate: referenceDate
            )
        ]

        let result = FundingPlannerEngine.calculate(
            subscriptions: subs,
            usageCosts: [2.0, 2.0, 2.0], // $6 over 10 days = $0.6/day
            usageDaysOfData: 10,
            cashReserve: 100,
            now: referenceDate
        )

        // Monthly: 1 charge of $200, Weekly: ~4 charges of $10 = $40, API: 0.6 * 30 = $18
        // Total required ~= 258
        XCTAssertGreaterThan(result.requiredNext30Days, 200, "Should include monthly + weekly + API")
        XCTAssertGreaterThan(result.shortfall, 0, "Reserve of 100 < required ~258")
        XCTAssertNotNil(result.depletionDate, "Should have a depletion date")
    }
}

// MARK: - Top-Up Notification Decision

final class TopUpDecisionTests: XCTestCase {

    func testTopUpAlert_Positive_ReturnsDedupKey() {
        let key = NotificationDecisions.topUpAlert(
            recommendedAmount: 150,
            sentKeys: [],
            yearMonth: 202602
        )

        XCTAssertEqual(key, "topup:202602")
    }

    func testTopUpAlert_Zero_ReturnsNil() {
        let key = NotificationDecisions.topUpAlert(
            recommendedAmount: 0,
            sentKeys: [],
            yearMonth: 202602
        )

        XCTAssertNil(key, "No top-up needed should not trigger alert")
    }

    func testTopUpAlert_AlreadySent_ReturnsNil() {
        let key = NotificationDecisions.topUpAlert(
            recommendedAmount: 150,
            sentKeys: ["topup:202602"],
            yearMonth: 202602
        )

        XCTAssertNil(key, "Already sent this month should not re-fire")
    }
}
