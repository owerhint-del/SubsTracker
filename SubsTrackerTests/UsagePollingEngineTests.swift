import XCTest

// MARK: - Tick Decision Tests

final class PollingTickDecisionTests: XCTestCase {

    private let now = Date()

    // MARK: - Basic Refresh

    func testRefresh_AllConditionsMet() {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .refresh)
    }

    // MARK: - Disabled

    func testDisabled_IntervalZero() {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 0,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .skipDisabled)
    }

    // MARK: - Already Refreshing (Anti-Race)

    func testSkip_AlreadyRefreshing() {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: true,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .skipAlreadyRefreshing)
    }

    // MARK: - View Not Visible

    func testSkip_ViewNotVisible() {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: false,
            isAppActive: true,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .skipInactive)
    }

    // MARK: - App Not Active (Background/Inactive)

    func testSkip_AppNotActive() {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: false,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .skipInactive)
    }

    // MARK: - Both Inactive

    func testSkip_ViewHiddenAndAppInactive() {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 5,
            isRefreshing: false,
            isViewVisible: false,
            isAppActive: false,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .skipInactive)
    }

    // MARK: - Error Backoff

    func testBackoff_BelowThreshold_Refreshes() {
        // 2 errors < threshold of 3 — should still refresh
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 2,
            lastErrorAt: now.addingTimeInterval(-5),
            now: now
        )
        XCTAssertEqual(decision, .refresh)
    }

    func testBackoff_AtThreshold_RecentError_Skips() {
        // 3 errors, last error 10s ago (< 30s backoff)
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 3,
            lastErrorAt: now.addingTimeInterval(-10),
            now: now
        )
        if case .skipBackoff(let resumesIn) = decision {
            XCTAssertEqual(resumesIn, 20, accuracy: 1)
        } else {
            XCTFail("Expected skipBackoff, got \(decision)")
        }
    }

    func testBackoff_Expired_Refreshes() {
        // 3 errors, but last error was 31s ago (> 30s backoff)
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 3,
            lastErrorAt: now.addingTimeInterval(-31),
            now: now
        )
        XCTAssertEqual(decision, .refresh)
    }

    func testBackoff_HighErrorCount_StillBacksOff() {
        // 10 consecutive errors, 5 seconds ago
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 10,
            lastErrorAt: now.addingTimeInterval(-5),
            now: now
        )
        if case .skipBackoff = decision {
            // Expected
        } else {
            XCTFail("Expected skipBackoff, got \(decision)")
        }
    }

    func testBackoff_NoErrorDate_Refreshes() {
        // Edge case: high error count but nil lastErrorAt
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 5,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .refresh)
    }
}

// MARK: - Interval Switch Tests

final class PollingIntervalTests: XCTestCase {

    func testClamp_Zero_StaysOff() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(0), 0)
    }

    func testClamp_Negative_BecomesOff() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(-1), 0)
    }

    func testClamp_Five() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(5), 5)
    }

    func testClamp_Ten() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(10), 10)
    }

    func testClamp_Three_RoundsToFive() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(3), 5)
    }

    func testClamp_Seven_RoundsToFive() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(7), 5)
    }

    func testClamp_Eight_RoundsToTen() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(8), 10)
    }

    func testClamp_Fifteen_RoundsToTen() {
        XCTAssertEqual(UsagePollingEngine.clampInterval(15), 10)
    }

    func testValidIntervals() {
        XCTAssertEqual(UsagePollingEngine.validIntervals, [0, 5, 10])
    }
}

// MARK: - Status Label Tests

final class PollingStatusLabelTests: XCTestCase {

    private let now = Date()

    func testLabel_Off() {
        let label = UsagePollingEngine.statusLabel(
            intervalSeconds: 0,
            isRefreshing: false,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(label, "Live: Off")
    }

    func testLabel_TenSeconds() {
        let label = UsagePollingEngine.statusLabel(
            intervalSeconds: 10,
            isRefreshing: false,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(label, "Live: 10s")
    }

    func testLabel_FiveSeconds() {
        let label = UsagePollingEngine.statusLabel(
            intervalSeconds: 5,
            isRefreshing: false,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(label, "Live: 5s")
    }

    func testLabel_Paused_DuringBackoff() {
        let label = UsagePollingEngine.statusLabel(
            intervalSeconds: 10,
            isRefreshing: false,
            consecutiveErrors: 3,
            lastErrorAt: now.addingTimeInterval(-10),
            now: now
        )
        XCTAssertEqual(label, "Live: Paused")
    }

    func testLabel_BackoffExpired_ShowsInterval() {
        let label = UsagePollingEngine.statusLabel(
            intervalSeconds: 10,
            isRefreshing: false,
            consecutiveErrors: 3,
            lastErrorAt: now.addingTimeInterval(-31),
            now: now
        )
        XCTAssertEqual(label, "Live: 10s")
    }
}

// MARK: - Scene Phase Transition Tests

final class PollingSceneTransitionTests: XCTestCase {

    private let now = Date()

    func testActive_ViewVisible_Refreshes() {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .refresh)
    }

    func testInactive_ViewVisible_Skips() {
        // App goes inactive while view is visible — should skip
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: false,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .skipInactive)
    }

    func testActive_ViewHidden_Skips() {
        // App is active but user navigated away
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 10,
            isRefreshing: false,
            isViewVisible: false,
            isAppActive: true,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .skipInactive)
    }

    func testReactivation_AfterInactive_Refreshes() {
        // App comes back to active with view visible — should refresh
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: 5,
            isRefreshing: false,
            isViewVisible: true,
            isAppActive: true,
            consecutiveErrors: 0,
            lastErrorAt: nil,
            now: now
        )
        XCTAssertEqual(decision, .refresh)
    }
}

// MARK: - Engine Constants Tests

final class PollingEngineConstantsTests: XCTestCase {

    func testErrorThreshold() {
        XCTAssertEqual(UsagePollingEngine.errorThreshold, 3)
    }

    func testBackoffDuration() {
        XCTAssertEqual(UsagePollingEngine.backoffDuration, 30)
    }
}
