import Foundation

/// Pure deterministic decision engine for usage polling.
/// No timers, no I/O, no state — fully testable.
enum UsagePollingEngine {

    // MARK: - Configuration

    /// Maximum consecutive errors before entering backoff.
    static let errorThreshold = 3

    /// Backoff duration in seconds after hitting error threshold.
    static let backoffDuration: TimeInterval = 30

    // MARK: - Tick Decision

    enum TickDecision: Equatable {
        case refresh
        case skipAlreadyRefreshing
        case skipDisabled
        case skipInactive
        case skipBackoff(resumesIn: TimeInterval)
    }

    /// Decides whether a polling tick should trigger a refresh.
    static func shouldRefresh(
        intervalSeconds: Int,
        isRefreshing: Bool,
        isViewVisible: Bool,
        isAppActive: Bool,
        consecutiveErrors: Int,
        lastErrorAt: Date?,
        now: Date = Date()
    ) -> TickDecision {
        // Disabled
        guard intervalSeconds > 0 else { return .skipDisabled }

        // View not visible or app not active
        guard isViewVisible, isAppActive else { return .skipInactive }

        // Already refreshing — anti-race guard
        guard !isRefreshing else { return .skipAlreadyRefreshing }

        // Error backoff
        if consecutiveErrors >= errorThreshold, let errorDate = lastErrorAt {
            let elapsed = now.timeIntervalSince(errorDate)
            if elapsed < backoffDuration {
                return .skipBackoff(resumesIn: backoffDuration - elapsed)
            }
            // Backoff expired — allow refresh (errors will be reset on success)
        }

        return .refresh
    }

    // MARK: - Interval Validation

    /// Valid polling intervals in seconds.
    static let validIntervals: [Int] = [0, 5, 10]

    /// Clamps an interval to the nearest valid value.
    static func clampInterval(_ seconds: Int) -> Int {
        if seconds <= 0 { return 0 }
        if seconds <= 7 { return 5 }
        return 10
    }

    // MARK: - Consumer Logic

    /// Whether polling has any active consumer.
    /// True when at least one usage view is visible OR the menu bar live label is enabled.
    static func hasActiveConsumer(viewConsumerCount: Int, menuBarEnabled: Bool) -> Bool {
        viewConsumerCount > 0 || menuBarEnabled
    }

    // MARK: - Status Label

    /// Returns a human-readable status label for the polling state.
    static func statusLabel(
        intervalSeconds: Int,
        isRefreshing: Bool,
        consecutiveErrors: Int,
        lastErrorAt: Date?,
        now: Date = Date()
    ) -> String {
        guard intervalSeconds > 0 else { return "Live: Off" }

        if consecutiveErrors >= errorThreshold, let errorDate = lastErrorAt {
            let elapsed = now.timeIntervalSince(errorDate)
            if elapsed < backoffDuration {
                return "Live: Paused"
            }
        }

        if isRefreshing {
            return "Live: \(intervalSeconds)s"
        }

        return "Live: \(intervalSeconds)s"
    }
}
