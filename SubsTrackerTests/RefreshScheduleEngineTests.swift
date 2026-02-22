import XCTest

final class RefreshScheduleEngineTests: XCTestCase {

    private let now = Date()

    private func minutesAgo(_ minutes: Int) -> Date {
        now.addingTimeInterval(-Double(minutes) * 60)
    }

    private func secondsAgo(_ seconds: Int) -> Date {
        now.addingTimeInterval(-Double(seconds))
    }

    // MARK: - shouldRefresh: Startup

    func testStartup_NeverRefreshed_Refreshes() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: nil,
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .startup
        )
        XCTAssertEqual(decision, .refresh(reason: .startup))
    }

    func testStartup_IntervalElapsed_Refreshes() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(31),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .startup
        )
        XCTAssertEqual(decision, .refresh(reason: .startup))
    }

    // MARK: - shouldRefresh: Interval Not Elapsed

    func testInterval_NotElapsed_Skips() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(5),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .interval
        )
        XCTAssertEqual(decision, .skip(reason: .intervalNotElapsed))
    }

    func testInterval_Elapsed_Refreshes() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(31),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .interval
        )
        XCTAssertEqual(decision, .refresh(reason: .interval))
    }

    func testInterval_ExactBoundary_Refreshes() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(30),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .interval
        )
        XCTAssertEqual(decision, .refresh(reason: .interval))
    }

    // MARK: - shouldRefresh: Disabled

    func testDisabled_NonManual_Skips() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: nil,
            refreshInterval: 0,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .startup
        )
        XCTAssertEqual(decision, .skip(reason: .disabled))
    }

    func testDisabled_Manual_Refreshes() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: nil,
            refreshInterval: 0,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .manual
        )
        XCTAssertEqual(decision, .refresh(reason: .manual))
    }

    // MARK: - shouldRefresh: Already Refreshing

    func testAlreadyRefreshing_Skips() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(60),
            refreshInterval: 30,
            isRefreshing: true,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .startup
        )
        XCTAssertEqual(decision, .skip(reason: .inProgressSkip))
    }

    func testAlreadyRefreshing_ManualAlso_Skips() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(60),
            refreshInterval: 30,
            isRefreshing: true,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .manual
        )
        XCTAssertEqual(decision, .skip(reason: .inProgressSkip))
    }

    // MARK: - shouldRefresh: Backoff

    func testBackoff_Active_Skips() {
        // 1 error, 60s ago → backoff is 120s → still within window
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(60),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: secondsAgo(60),
            consecutiveErrors: 1,
            reason: .interval
        )
        XCTAssertEqual(decision, .skip(reason: .backoffActive))
    }

    func testBackoff_Expired_Refreshes() {
        // 1 error, 200s ago → backoff is 120s → expired
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(60),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: secondsAgo(200),
            consecutiveErrors: 1,
            reason: .interval
        )
        XCTAssertEqual(decision, .refresh(reason: .interval))
    }

    func testBackoff_ManualBypassesBackoff() {
        // 1 error, 60s ago → backoff active, but manual always wins
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(60),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: secondsAgo(60),
            consecutiveErrors: 1,
            reason: .manual
        )
        XCTAssertEqual(decision, .refresh(reason: .manual))
    }

    // MARK: - shouldRefresh: Returned to Foreground

    func testForeground_IntervalElapsed_Refreshes() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(35),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .returnedToForeground
        )
        XCTAssertEqual(decision, .refresh(reason: .returnedToForeground))
    }

    func testForeground_IntervalNotElapsed_Skips() {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: now,
            lastRefreshAt: minutesAgo(10),
            refreshInterval: 30,
            isRefreshing: false,
            lastErrorAt: nil,
            consecutiveErrors: 0,
            reason: .returnedToForeground
        )
        XCTAssertEqual(decision, .skip(reason: .intervalNotElapsed))
    }

    // MARK: - backoffInterval

    func testBackoffInterval_ZeroErrors_ReturnsZero() {
        XCTAssertEqual(RefreshScheduleEngine.backoffInterval(consecutiveErrors: 0), 0)
    }

    func testBackoffInterval_OneError_Returns120() {
        XCTAssertEqual(RefreshScheduleEngine.backoffInterval(consecutiveErrors: 1), 120)
    }

    func testBackoffInterval_TwoErrors_Returns300() {
        XCTAssertEqual(RefreshScheduleEngine.backoffInterval(consecutiveErrors: 2), 300)
    }

    func testBackoffInterval_ThreeErrors_Returns900() {
        XCTAssertEqual(RefreshScheduleEngine.backoffInterval(consecutiveErrors: 3), 900)
    }

    func testBackoffInterval_HighCount_CapsAtMax() {
        XCTAssertEqual(RefreshScheduleEngine.backoffInterval(consecutiveErrors: 99), 900)
    }

    // MARK: - nextRefreshDate

    func testNextRefreshDate_Disabled_ReturnsNil() {
        let result = RefreshScheduleEngine.nextRefreshDate(lastRefreshAt: now, refreshInterval: 0)
        XCTAssertNil(result)
    }

    func testNextRefreshDate_NeverRefreshed_ReturnsEpochPlusInterval() {
        let result = RefreshScheduleEngine.nextRefreshDate(lastRefreshAt: nil, refreshInterval: 30)
        XCTAssertNotNil(result)
        // Should be epoch + 30 min (effectively in the past → triggers immediately)
        let expected = Date(timeIntervalSince1970: 0).addingTimeInterval(30 * 60)
        XCTAssertEqual(result!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testNextRefreshDate_RecentRefresh_ReturnsFuture() {
        let tenMinAgo = minutesAgo(10)
        let result = RefreshScheduleEngine.nextRefreshDate(lastRefreshAt: tenMinAgo, refreshInterval: 30)
        XCTAssertNotNil(result)
        // Should be 20 min from now
        let expected = tenMinAgo.addingTimeInterval(30 * 60)
        XCTAssertEqual(result!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }
}
