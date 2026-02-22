import Foundation

// MARK: - Types

/// Energy policy presets that control how aggressively refresh is throttled.
enum EnergyPolicy: String, CaseIterable, Identifiable {
    case performance
    case balanced
    case saver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .performance: return "Performance"
        case .balanced: return "Balanced"
        case .saver: return "Saver"
        }
    }

    var description: String {
        switch self {
        case .performance: return "No throttle. Refreshes at full speed."
        case .balanced: return "Slows down on battery or heat."
        case .saver: return "Maximizes battery life."
        }
    }

    var iconSystemName: String {
        switch self {
        case .performance: return "bolt"
        case .balanced: return "leaf"
        case .saver: return "battery.50"
        }
    }
}

/// Thermal state mirror — independent of ProcessInfo for testability.
enum EnergyThermalState: Int, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    static func < (lhs: EnergyThermalState, rhs: EnergyThermalState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// All inputs the policy engine needs to compute the effective interval.
struct PolicyInput {
    let baseIntervalMinutes: Int
    let policy: EnergyPolicy
    let isLowPowerMode: Bool
    let thermalState: EnergyThermalState
}

/// The engine's output: effective interval, skip flag, and optional UI reason.
struct PolicyResult: Equatable {
    let effectiveIntervalSeconds: TimeInterval
    let shouldSkip: Bool
    let deferReason: String?
}

// MARK: - Engine

/// Pure calculation engine for energy-aware refresh policy.
/// No I/O, no ProcessInfo, no UserDefaults — fully testable.
enum BackgroundRefreshPolicyEngine {

    /// Evaluate the current energy conditions and return the effective refresh policy.
    static func evaluate(input: PolicyInput) -> PolicyResult {
        // Disabled — pass through
        guard input.baseIntervalMinutes > 0 else {
            return PolicyResult(
                effectiveIntervalSeconds: 0,
                shouldSkip: true,
                deferReason: "Auto-refresh disabled"
            )
        }

        // Critical thermal is an unconditional safety floor — all presets skip
        if input.thermalState == .critical {
            return PolicyResult(
                effectiveIntervalSeconds: Double(input.baseIntervalMinutes) * 60,
                shouldSkip: true,
                deferReason: "Paused — critical temperature"
            )
        }

        let baseSeconds = Double(input.baseIntervalMinutes) * 60

        switch input.policy {
        case .performance:
            // No throttle ever (except critical, handled above)
            return PolicyResult(
                effectiveIntervalSeconds: baseSeconds,
                shouldSkip: false,
                deferReason: nil
            )

        case .balanced:
            return evaluateBalanced(baseSeconds: baseSeconds, input: input)

        case .saver:
            return evaluateSaver(baseSeconds: baseSeconds, input: input)
        }
    }

    /// Compute just the effective interval (convenience for timer scheduling).
    static func effectiveInterval(
        baseMinutes: Int,
        policy: EnergyPolicy,
        isLowPowerMode: Bool,
        thermalState: EnergyThermalState
    ) -> TimeInterval {
        let result = evaluate(input: PolicyInput(
            baseIntervalMinutes: baseMinutes,
            policy: policy,
            isLowPowerMode: isLowPowerMode,
            thermalState: thermalState
        ))
        return result.effectiveIntervalSeconds
    }

    // MARK: - Private

    private static func evaluateBalanced(baseSeconds: TimeInterval, input: PolicyInput) -> PolicyResult {
        // Pick the larger multiplier (don't compound)
        let lowPowerMultiplier: Double = input.isLowPowerMode ? 1.5 : 1.0
        let thermalMultiplier: Double
        let thermalReason: String?

        switch input.thermalState {
        case .nominal, .fair:
            thermalMultiplier = 1.0
            thermalReason = nil
        case .serious:
            thermalMultiplier = 2.0
            thermalReason = "Thermal throttle — serious"
        case .critical:
            // Already handled above, but for completeness
            thermalMultiplier = 1.0
            thermalReason = nil
        }

        let multiplier = max(lowPowerMultiplier, thermalMultiplier)
        let effective = baseSeconds * multiplier

        let reason: String?
        if thermalMultiplier > lowPowerMultiplier {
            reason = thermalReason
        } else if input.isLowPowerMode {
            reason = "Low Power Mode — slowed"
        } else {
            reason = nil
        }

        return PolicyResult(
            effectiveIntervalSeconds: effective,
            shouldSkip: false,
            deferReason: reason
        )
    }

    private static func evaluateSaver(baseSeconds: TimeInterval, input: PolicyInput) -> PolicyResult {
        // Serious thermal → skip entirely in Saver mode
        if input.thermalState >= .serious {
            return PolicyResult(
                effectiveIntervalSeconds: baseSeconds * 2.0,
                shouldSkip: true,
                deferReason: "Paused — thermal pressure (Saver)"
            )
        }

        // Low power → 3x
        if input.isLowPowerMode {
            return PolicyResult(
                effectiveIntervalSeconds: baseSeconds * 3.0,
                shouldSkip: false,
                deferReason: "Low Power Mode — heavy throttle"
            )
        }

        // Saver baseline is always 2x
        return PolicyResult(
            effectiveIntervalSeconds: baseSeconds * 2.0,
            shouldSkip: false,
            deferReason: "Saver mode active"
        )
    }
}
