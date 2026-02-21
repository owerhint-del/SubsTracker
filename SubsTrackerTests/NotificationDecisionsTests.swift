import XCTest
@testable import SubsTracker

final class NotificationDecisionsTests: XCTestCase {

    // MARK: - Budget Threshold Tests

    func testBudget_92Percent_Threshold80_FiresTwoLevels() {
        let results = NotificationDecisions.budgetThresholdsToAlert(
            spendPercent: 92,
            alertThresholdPercent: 80,
            sentKeys: [],
            yearMonth: 202602
        )

        let thresholds = results.map(\.threshold)
        XCTAssertEqual(thresholds, [80, 90], "At 92% with threshold 80, should fire 80 and 90 (not 100)")
    }

    func testBudget_92Percent_Threshold90_FiresOnlyOne() {
        let results = NotificationDecisions.budgetThresholdsToAlert(
            spendPercent: 92,
            alertThresholdPercent: 90,
            sentKeys: [],
            yearMonth: 202602
        )

        let thresholds = results.map(\.threshold)
        XCTAssertEqual(thresholds, [90], "At 92% with threshold 90, should fire only 90")
    }

    func testBudget_100Percent_SkipsAlreadySent() {
        let sentKeys: Set<String> = ["budget:202602:80", "budget:202602:90"]
        let results = NotificationDecisions.budgetThresholdsToAlert(
            spendPercent: 100,
            alertThresholdPercent: 80,
            sentKeys: sentKeys,
            yearMonth: 202602
        )

        let thresholds = results.map(\.threshold)
        XCTAssertEqual(thresholds, [100], "Already sent 80 and 90 — should only fire 100")
    }

    func testBudget_ZeroSpend_ReturnsEmpty() {
        let results = NotificationDecisions.budgetThresholdsToAlert(
            spendPercent: 0,
            alertThresholdPercent: 80,
            sentKeys: [],
            yearMonth: 202602
        )

        XCTAssertTrue(results.isEmpty, "Zero spend should never fire alerts")
    }

    // MARK: - Renewal Progressive Hierarchy Tests

    func testRenewal_1Day_FiresMostSpecific() {
        let result = NotificationDecisions.renewalAlertLevel(
            daysUntil: 1,
            sentKeys: [],
            subId: "abc",
            dateStr: "2026-03-01"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.daysBefore, 1, "1 day out should fire the 1-day alert")
    }

    func testRenewal_5Days_Fires7DayLevel() {
        let result = NotificationDecisions.renewalAlertLevel(
            daysUntil: 5,
            sentKeys: [],
            subId: "abc",
            dateStr: "2026-03-01"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.daysBefore, 7, "5 days out should fire the 7-day alert")
    }

    func testRenewal_1Day_AlreadySent_ReturnsNil() {
        let sentKeys: Set<String> = ["renewal:abc:2026-03-01:1"]
        let result = NotificationDecisions.renewalAlertLevel(
            daysUntil: 1,
            sentKeys: sentKeys,
            subId: "abc",
            dateStr: "2026-03-01"
        )

        XCTAssertNil(result, "Most specific already sent — should not fall back to less-specific")
    }

    func testRenewal_10Days_ReturnsNil() {
        let result = NotificationDecisions.renewalAlertLevel(
            daysUntil: 10,
            sentKeys: [],
            subId: "abc",
            dateStr: "2026-03-01"
        )

        XCTAssertNil(result, "10 days out is beyond all alert windows")
    }

    // MARK: - Quiet Hours Tests

    func testQuietHours_OvernightRange_InsideAtNight() {
        // 22:00 → 08:00, current hour 23
        let result = NotificationDecisions.isInQuietHours(
            currentHour: 23,
            startHour: 22,
            endHour: 8
        )

        XCTAssertTrue(result, "23:00 is inside 22→8 quiet hours")
    }

    func testQuietHours_OvernightRange_InsideEarlyMorning() {
        // 22:00 → 08:00, current hour 5
        let result = NotificationDecisions.isInQuietHours(
            currentHour: 5,
            startHour: 22,
            endHour: 8
        )

        XCTAssertTrue(result, "05:00 is inside 22→8 quiet hours")
    }

    func testQuietHours_OvernightRange_OutsideMidday() {
        // 22:00 → 08:00, current hour 14
        let result = NotificationDecisions.isInQuietHours(
            currentHour: 14,
            startHour: 22,
            endHour: 8
        )

        XCTAssertFalse(result, "14:00 is outside 22→8 quiet hours")
    }

    func testQuietHours_SameDayRange_Inside() {
        // 08:00 → 22:00, current hour 15
        let result = NotificationDecisions.isInQuietHours(
            currentHour: 15,
            startHour: 8,
            endHour: 22
        )

        XCTAssertTrue(result, "15:00 is inside 8→22 quiet hours")
    }

    func testQuietHours_SameDayRange_Outside() {
        // 08:00 → 22:00, current hour 23
        let result = NotificationDecisions.isInQuietHours(
            currentHour: 23,
            startHour: 8,
            endHour: 22
        )

        XCTAssertFalse(result, "23:00 is outside 8→22 quiet hours")
    }

    func testQuietHours_EqualStartEnd_NeverQuiet() {
        let result = NotificationDecisions.isInQuietHours(
            currentHour: 10,
            startHour: 10,
            endHour: 10
        )

        XCTAssertFalse(result, "Equal start/end means quiet hours disabled")
    }
}
