import XCTest

// MARK: - Zero Shortfall Tests

final class TopUpNoShortfallTests: XCTestCase {

    func testZeroShortfall_ReturnsZeroAmount() {
        let result = makeRecommendation(shortfall: 0, required: 200, reserve: 300)
        XCTAssertEqual(result.recommendedAmount, 0)
        XCTAssertNil(result.recommendedDate)
        XCTAssertEqual(result.urgency, .none)
    }

    func testZeroShortfall_NeutralReason() {
        let result = makeRecommendation(shortfall: 0, required: 100, reserve: 200)
        XCTAssertTrue(result.reason.contains("covers"), "Reason should indicate reserve is sufficient")
    }
}

// MARK: - Fixed Buffer Tests

final class TopUpFixedBufferTests: XCTestCase {

    func testFixedBuffer_AddsToShortfall() {
        let result = makeRecommendation(
            shortfall: 100, required: 300, reserve: 200,
            bufferMode: .fixed, bufferValue: 50
        )
        XCTAssertEqual(result.recommendedAmount, 150, accuracy: 0.01, "shortfall(100) + buffer(50) = 150")
    }

    func testFixedBuffer_ZeroBuffer() {
        let result = makeRecommendation(
            shortfall: 80, required: 200, reserve: 120,
            bufferMode: .fixed, bufferValue: 0
        )
        XCTAssertEqual(result.recommendedAmount, 80, accuracy: 0.01, "Zero buffer = exact shortfall")
    }

    func testFixedBuffer_NegativeBufferClampedToZero() {
        let result = makeRecommendation(
            shortfall: 50, required: 100, reserve: 50,
            bufferMode: .fixed, bufferValue: -10
        )
        XCTAssertEqual(result.recommendedAmount, 50, accuracy: 0.01, "Negative buffer clamped to 0")
    }
}

// MARK: - Percent Buffer Tests

final class TopUpPercentBufferTests: XCTestCase {

    func testPercentBuffer_10Percent() {
        // required = 300, 10% buffer = 30, shortfall = 100
        let result = makeRecommendation(
            shortfall: 100, required: 300, reserve: 200,
            bufferMode: .percent, bufferValue: 10
        )
        XCTAssertEqual(result.recommendedAmount, 130, accuracy: 0.01, "shortfall(100) + 10% of 300(30) = 130")
    }

    func testPercentBuffer_ZeroPercent() {
        let result = makeRecommendation(
            shortfall: 50, required: 200, reserve: 150,
            bufferMode: .percent, bufferValue: 0
        )
        XCTAssertEqual(result.recommendedAmount, 50, accuracy: 0.01, "0% buffer = exact shortfall")
    }
}

// MARK: - Date and Lead Days Tests

final class TopUpDateTests: XCTestCase {

    private var referenceDate: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 2, day: 15))!
    }

    func testWithDepletionDate_LeadDays2() {
        let depletion = Calendar.current.date(byAdding: .day, value: 10, to: referenceDate)!
        let result = makeRecommendation(
            shortfall: 50, required: 200, reserve: 150,
            depletionDate: depletion, leadDays: 2, now: referenceDate
        )

        let expected = Calendar.current.date(byAdding: .day, value: 8, to: referenceDate)!
        XCTAssertNotNil(result.recommendedDate)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: result.recommendedDate!),
            Calendar.current.startOfDay(for: expected),
            "Should recommend 2 days before depletion (day 10 - 2 = day 8)"
        )
    }

    func testWithDepletionDate_LeadDaysExceedsDepletion_ClampsToToday() {
        // Depletion in 1 day, lead days = 5 → would be 4 days in the past → clamp to today
        let depletion = Calendar.current.date(byAdding: .day, value: 1, to: referenceDate)!
        let result = makeRecommendation(
            shortfall: 50, required: 200, reserve: 150,
            depletionDate: depletion, leadDays: 5, now: referenceDate
        )

        XCTAssertNotNil(result.recommendedDate)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: result.recommendedDate!),
            Calendar.current.startOfDay(for: referenceDate),
            "Should clamp to today when lead date is in the past"
        )
    }

    func testNoDepletionDate_UsesFirstCharge() {
        let chargeDate = Calendar.current.date(byAdding: .day, value: 7, to: referenceDate)!
        let charges = [FundingCharge(name: "Sub", amount: 100, date: chargeDate)]
        let plannerResult = FundingPlannerResult(
            projectedCharges: charges,
            projectedAPISpend: 0,
            requiredNext30Days: 200,
            shortfall: 50,
            depletionDate: nil,
            lowConfidence: false
        )

        let result = TopUpRecommendationEngine.calculate(
            plannerResult: plannerResult,
            cashReserve: 150,
            bufferMode: .fixed, bufferValue: 0,
            leadDays: 2, now: referenceDate
        )

        let expected = Calendar.current.date(byAdding: .day, value: 5, to: referenceDate)!
        XCTAssertNotNil(result.recommendedDate)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: result.recommendedDate!),
            Calendar.current.startOfDay(for: expected),
            "Should use first charge date minus lead days"
        )
    }

    func testNoDepletionDate_NoCharges_DateIsNil() {
        let plannerResult = FundingPlannerResult(
            projectedCharges: [],
            projectedAPISpend: 100,
            requiredNext30Days: 100,
            shortfall: 50,
            depletionDate: nil,
            lowConfidence: false
        )

        let result = TopUpRecommendationEngine.calculate(
            plannerResult: plannerResult,
            cashReserve: 50,
            bufferMode: .fixed, bufferValue: 0,
            leadDays: 2, now: referenceDate
        )

        XCTAssertNil(result.recommendedDate, "No depletion and no charges = no date")
        XCTAssertEqual(result.urgency, .medium, "Should default to medium urgency")
    }
}

// MARK: - Urgency Level Tests

final class TopUpUrgencyTests: XCTestCase {

    private var referenceDate: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 2, day: 15))!
    }

    func testUrgency_Today_IsHigh() {
        // Depletion in 1 day, lead 2 → recommended today → high
        let depletion = Calendar.current.date(byAdding: .day, value: 1, to: referenceDate)!
        let result = makeRecommendation(
            shortfall: 50, required: 200, reserve: 150,
            depletionDate: depletion, leadDays: 2, now: referenceDate
        )
        XCTAssertEqual(result.urgency, .high)
    }

    func testUrgency_3Days_IsHigh() {
        let depletion = Calendar.current.date(byAdding: .day, value: 5, to: referenceDate)!
        let result = makeRecommendation(
            shortfall: 50, required: 200, reserve: 150,
            depletionDate: depletion, leadDays: 2, now: referenceDate
        )
        // Recommended date = day 3 → high
        XCTAssertEqual(result.urgency, .high)
    }

    func testUrgency_5Days_IsMedium() {
        let depletion = Calendar.current.date(byAdding: .day, value: 7, to: referenceDate)!
        let result = makeRecommendation(
            shortfall: 50, required: 200, reserve: 150,
            depletionDate: depletion, leadDays: 2, now: referenceDate
        )
        // Recommended date = day 5 → medium
        XCTAssertEqual(result.urgency, .medium)
    }

    func testUrgency_15Days_IsLow() {
        let depletion = Calendar.current.date(byAdding: .day, value: 17, to: referenceDate)!
        let result = makeRecommendation(
            shortfall: 50, required: 200, reserve: 150,
            depletionDate: depletion, leadDays: 2, now: referenceDate
        )
        // Recommended date = day 15 → low
        XCTAssertEqual(result.urgency, .low)
    }
}

// MARK: - Helpers

private func makeRecommendation(
    shortfall: Double,
    required: Double,
    reserve: Double,
    bufferMode: TopUpBufferMode = .fixed,
    bufferValue: Double = 50,
    depletionDate: Date? = nil,
    leadDays: Int = 2,
    now: Date = Date(),
    charges: [FundingCharge] = []
) -> TopUpRecommendation {
    let plannerResult = FundingPlannerResult(
        projectedCharges: charges,
        projectedAPISpend: 0,
        requiredNext30Days: required,
        shortfall: shortfall,
        depletionDate: depletionDate,
        lowConfidence: false
    )
    return TopUpRecommendationEngine.calculate(
        plannerResult: plannerResult,
        cashReserve: reserve,
        bufferMode: bufferMode,
        bufferValue: bufferValue,
        leadDays: leadDays,
        now: now
    )
}
