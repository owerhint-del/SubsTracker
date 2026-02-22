import XCTest

// MARK: - Period Filtering Tests

final class PurchaseFilteringTests: XCTestCase {

    func testFilterByPeriod_IncludesWithinRange() {
        let purchases = [
            makePurchase("A", amount: 10, date: makeDate(2026, 2, 5)),
            makePurchase("B", amount: 20, date: makeDate(2026, 2, 15)),
            makePurchase("C", amount: 30, date: makeDate(2026, 3, 1))
        ]
        let filtered = OneTimePurchaseEngine.filterByPeriod(
            purchases,
            start: makeDate(2026, 2, 1),
            end: makeDate(2026, 3, 1)
        )
        XCTAssertEqual(filtered.count, 2)
    }

    func testFilterByPeriod_StartInclusive() {
        let purchases = [makePurchase("A", amount: 10, date: makeDate(2026, 2, 1))]
        let filtered = OneTimePurchaseEngine.filterByPeriod(
            purchases,
            start: makeDate(2026, 2, 1),
            end: makeDate(2026, 3, 1)
        )
        XCTAssertEqual(filtered.count, 1, "Start date should be inclusive")
    }

    func testFilterByPeriod_EndExclusive() {
        let purchases = [makePurchase("A", amount: 10, date: makeDate(2026, 3, 1))]
        let filtered = OneTimePurchaseEngine.filterByPeriod(
            purchases,
            start: makeDate(2026, 2, 1),
            end: makeDate(2026, 3, 1)
        )
        XCTAssertEqual(filtered.count, 0, "End date should be exclusive")
    }

    func testCurrentMonthPurchases() {
        let now = makeDate(2026, 2, 15)
        let purchases = [
            makePurchase("In", amount: 50, date: makeDate(2026, 2, 10)),
            makePurchase("Out", amount: 100, date: makeDate(2026, 1, 20))
        ]
        let result = OneTimePurchaseEngine.currentMonthPurchases(purchases, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "In")
    }

    func testLastNDaysPurchases() {
        let now = makeDate(2026, 2, 15)
        let purchases = [
            makePurchase("Recent", amount: 25, date: makeDate(2026, 2, 10)),
            makePurchase("Old", amount: 50, date: makeDate(2026, 1, 1))
        ]
        let result = OneTimePurchaseEngine.lastNDaysPurchases(purchases, days: 30, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Recent")
    }

    func testEmptyPurchases() {
        let filtered = OneTimePurchaseEngine.filterByPeriod(
            [],
            start: makeDate(2026, 1, 1),
            end: makeDate(2026, 12, 31)
        )
        XCTAssertTrue(filtered.isEmpty)
    }
}

// MARK: - Aggregation Tests

final class PurchaseAggregationTests: XCTestCase {

    func testAggregate_TotalAmount() {
        let purchases = [
            makePurchase("A", amount: 10),
            makePurchase("B", amount: 25.50),
            makePurchase("C", amount: 14.50)
        ]
        let result = OneTimePurchaseEngine.aggregate(purchases)
        XCTAssertEqual(result.totalAmount, 50.0, accuracy: 0.01)
        XCTAssertEqual(result.count, 3)
    }

    func testAggregate_ByCategory() {
        let purchases = [
            makePurchase("API Credits", amount: 100, category: .aiServices),
            makePurchase("More Credits", amount: 50, category: .aiServices),
            makePurchase("Domain", amount: 20, category: .other)
        ]
        let result = OneTimePurchaseEngine.aggregate(purchases)
        XCTAssertEqual(result.byCategory.count, 2)
        // AI Services should be first (highest amount)
        XCTAssertEqual(result.byCategory.first?.category, .aiServices)
        XCTAssertEqual(result.byCategory.first!.amount, 150.0, accuracy: 0.01)
    }

    func testAggregate_EmptyPurchases() {
        let result = OneTimePurchaseEngine.aggregate([])
        XCTAssertEqual(result.totalAmount, 0)
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.byCategory.isEmpty)
    }

    func testCurrentMonthTotal() {
        let now = makeDate(2026, 2, 15)
        let purchases = [
            makePurchase("In", amount: 30, date: makeDate(2026, 2, 5)),
            makePurchase("In2", amount: 20, date: makeDate(2026, 2, 10)),
            makePurchase("Out", amount: 100, date: makeDate(2026, 1, 15))
        ]
        let total = OneTimePurchaseEngine.currentMonthTotal(purchases, now: now)
        XCTAssertEqual(total, 50.0, accuracy: 0.01)
    }
}

// MARK: - Funding Planner Integration Tests

final class PurchaseFundingTests: XCTestCase {

    func testEffectiveReserve_DeductsRecentPurchases() {
        let now = makeDate(2026, 2, 15)
        let purchases = [
            makePurchase("API Top-up", amount: 200, date: makeDate(2026, 2, 10)),
            makePurchase("Old", amount: 500, date: makeDate(2026, 1, 1))
        ]
        let effective = OneTimePurchaseEngine.effectiveReserve(
            cashReserve: 1000, purchases: purchases, now: now
        )
        // Only the recent $200 should be deducted, not the old $500
        XCTAssertEqual(effective, 800.0, accuracy: 0.01)
    }

    func testEffectiveReserve_NeverNegative() {
        let now = makeDate(2026, 2, 15)
        let purchases = [
            makePurchase("Big spend", amount: 2000, date: makeDate(2026, 2, 10))
        ]
        let effective = OneTimePurchaseEngine.effectiveReserve(
            cashReserve: 500, purchases: purchases, now: now
        )
        XCTAssertEqual(effective, 0, "Effective reserve should never go below zero")
    }

    func testEffectiveReserve_NoPurchases() {
        let effective = OneTimePurchaseEngine.effectiveReserve(
            cashReserve: 1000, purchases: [], now: Date()
        )
        XCTAssertEqual(effective, 1000)
    }

    func testEffectiveReserve_ZeroReserve() {
        let purchases = [makePurchase("A", amount: 50, date: Date())]
        let effective = OneTimePurchaseEngine.effectiveReserve(
            cashReserve: 0, purchases: purchases, now: Date()
        )
        XCTAssertEqual(effective, 0)
    }
}

// MARK: - Rounding / Edge Cases

final class PurchaseEdgeCaseTests: XCTestCase {

    func testZeroAmountPurchase() {
        let purchases = [makePurchase("Free", amount: 0)]
        let result = OneTimePurchaseEngine.aggregate(purchases)
        XCTAssertEqual(result.totalAmount, 0)
        XCTAssertEqual(result.count, 1)
    }

    func testLargeAmountPurchase() {
        let purchases = [makePurchase("Enterprise", amount: 99999.99)]
        let result = OneTimePurchaseEngine.aggregate(purchases)
        XCTAssertEqual(result.totalAmount, 99999.99, accuracy: 0.01)
    }

    func testMultipleCategoriesSortedByAmount() {
        let purchases = [
            makePurchase("A", amount: 10, category: .streaming),
            makePurchase("B", amount: 30, category: .development),
            makePurchase("C", amount: 20, category: .productivity)
        ]
        let result = OneTimePurchaseEngine.aggregate(purchases)
        XCTAssertEqual(result.byCategory[0].category, .development)
        XCTAssertEqual(result.byCategory[1].category, .productivity)
        XCTAssertEqual(result.byCategory[2].category, .streaming)
    }
}

// MARK: - Test Helpers

private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

private func makePurchase(
    _ name: String,
    amount: Double,
    date: Date = Date(),
    category: SubscriptionCategory = .other
) -> OneTimePurchaseEngine.PurchaseSnapshot {
    OneTimePurchaseEngine.PurchaseSnapshot(
        name: name,
        amount: amount,
        date: date,
        category: category
    )
}
