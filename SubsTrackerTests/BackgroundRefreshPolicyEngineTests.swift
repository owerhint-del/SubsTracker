import XCTest
@testable import SubsTracker

final class BackgroundRefreshPolicyEngineTests: XCTestCase {

    // MARK: - Disabled

    func testDisabledIntervalReturnsSkip() {
        let result = BackgroundRefreshPolicyEngine.evaluate(input: PolicyInput(
            baseIntervalMinutes: 0,
            policy: .balanced,
            isLowPowerMode: false,
            thermalState: .nominal
        ))
        XCTAssertTrue(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 0)
        XCTAssertNotNil(result.deferReason)
    }

    // MARK: - Critical Thermal (safety floor, all presets)

    func testCriticalThermalSkipsPerformance() {
        let result = evaluate(.performance, lowPower: false, thermal: .critical)
        XCTAssertTrue(result.shouldSkip)
        XCTAssertNotNil(result.deferReason)
        XCTAssertTrue(result.deferReason!.contains("critical"))
    }

    func testCriticalThermalSkipsBalanced() {
        let result = evaluate(.balanced, lowPower: false, thermal: .critical)
        XCTAssertTrue(result.shouldSkip)
    }

    func testCriticalThermalSkipsSaver() {
        let result = evaluate(.saver, lowPower: false, thermal: .critical)
        XCTAssertTrue(result.shouldSkip)
    }

    // MARK: - Performance Policy

    func testPerformanceNominalNoThrottle() {
        let result = evaluate(.performance, lowPower: false, thermal: .nominal)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 1800) // 30 * 60
        XCTAssertNil(result.deferReason)
    }

    func testPerformanceLowPowerNoThrottle() {
        let result = evaluate(.performance, lowPower: true, thermal: .nominal)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 1800)
        XCTAssertNil(result.deferReason)
    }

    func testPerformanceSeriousThermalNoThrottle() {
        let result = evaluate(.performance, lowPower: false, thermal: .serious)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 1800)
        XCTAssertNil(result.deferReason)
    }

    func testPerformanceFairThermalNoThrottle() {
        let result = evaluate(.performance, lowPower: false, thermal: .fair)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 1800)
        XCTAssertNil(result.deferReason)
    }

    // MARK: - Balanced Policy

    func testBalancedNominalNoThrottle() {
        let result = evaluate(.balanced, lowPower: false, thermal: .nominal)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 1800) // 1.0x
        XCTAssertNil(result.deferReason)
    }

    func testBalancedFairThermalNoThrottle() {
        let result = evaluate(.balanced, lowPower: false, thermal: .fair)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 1800) // 1.0x
        XCTAssertNil(result.deferReason)
    }

    func testBalancedLowPowerThrottles() {
        let result = evaluate(.balanced, lowPower: true, thermal: .nominal)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 2700) // 1.5x of 1800
        XCTAssertNotNil(result.deferReason)
        XCTAssertTrue(result.deferReason!.contains("Low Power"))
    }

    func testBalancedSeriousThermalThrottles() {
        let result = evaluate(.balanced, lowPower: false, thermal: .serious)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 3600) // 2.0x of 1800
        XCTAssertNotNil(result.deferReason)
        XCTAssertTrue(result.deferReason!.contains("Thermal"))
    }

    func testBalancedLowPowerAndSeriousThermalPicksMax() {
        // Both active: low power = 1.5x, serious = 2.0x → picks 2.0x (not 3.0x compound)
        let result = evaluate(.balanced, lowPower: true, thermal: .serious)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 3600) // max(1.5, 2.0) = 2.0x
        XCTAssertNotNil(result.deferReason)
    }

    func testBalancedLowPowerAndFairThermalPicksLowPower() {
        // low power = 1.5x, fair = 1.0x → picks 1.5x
        let result = evaluate(.balanced, lowPower: true, thermal: .fair)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 2700) // 1.5x
        XCTAssertTrue(result.deferReason!.contains("Low Power"))
    }

    // MARK: - Saver Policy

    func testSaverBaselineDoubles() {
        let result = evaluate(.saver, lowPower: false, thermal: .nominal)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 3600) // 2.0x
        XCTAssertNotNil(result.deferReason) // Always shows "Saver mode active"
    }

    func testSaverLowPowerTriples() {
        let result = evaluate(.saver, lowPower: true, thermal: .nominal)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 5400) // 3.0x of 1800
        XCTAssertNotNil(result.deferReason)
        XCTAssertTrue(result.deferReason!.contains("Low Power"))
    }

    func testSaverSeriousThermalSkips() {
        let result = evaluate(.saver, lowPower: false, thermal: .serious)
        XCTAssertTrue(result.shouldSkip)
        XCTAssertNotNil(result.deferReason)
    }

    func testSaverFairThermalDoesNotSkip() {
        let result = evaluate(.saver, lowPower: false, thermal: .fair)
        XCTAssertFalse(result.shouldSkip)
        XCTAssertEqual(result.effectiveIntervalSeconds, 3600) // 2.0x baseline
    }

    // MARK: - Different Base Intervals

    func testDifferentBaseInterval15Min() {
        let result = BackgroundRefreshPolicyEngine.evaluate(input: PolicyInput(
            baseIntervalMinutes: 15,
            policy: .balanced,
            isLowPowerMode: true,
            thermalState: .nominal
        ))
        XCTAssertEqual(result.effectiveIntervalSeconds, 1350) // 15 * 60 * 1.5
    }

    func testDifferentBaseInterval60Min() {
        let result = BackgroundRefreshPolicyEngine.evaluate(input: PolicyInput(
            baseIntervalMinutes: 60,
            policy: .saver,
            isLowPowerMode: false,
            thermalState: .nominal
        ))
        XCTAssertEqual(result.effectiveIntervalSeconds, 7200) // 60 * 60 * 2.0
    }

    // MARK: - Convenience Function

    func testEffectiveIntervalConvenience() {
        let interval = BackgroundRefreshPolicyEngine.effectiveInterval(
            baseMinutes: 30,
            policy: .balanced,
            isLowPowerMode: true,
            thermalState: .nominal
        )
        XCTAssertEqual(interval, 2700) // 1.5x of 1800
    }

    // MARK: - EnergyThermalState Comparable

    func testThermalStateOrdering() {
        XCTAssertTrue(EnergyThermalState.nominal < .fair)
        XCTAssertTrue(EnergyThermalState.fair < .serious)
        XCTAssertTrue(EnergyThermalState.serious < .critical)
        XCTAssertFalse(EnergyThermalState.critical < .serious)
    }

    // MARK: - Helpers

    /// Convenience: evaluate with 30-min base interval.
    private func evaluate(
        _ policy: EnergyPolicy,
        lowPower: Bool,
        thermal: EnergyThermalState,
        baseMinutes: Int = 30
    ) -> PolicyResult {
        BackgroundRefreshPolicyEngine.evaluate(input: PolicyInput(
            baseIntervalMinutes: baseMinutes,
            policy: policy,
            isLowPowerMode: lowPower,
            thermalState: thermal
        ))
    }
}
