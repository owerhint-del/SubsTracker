import Foundation

// MARK: - Types

/// Why a refresh was triggered or why it was skipped.
enum RefreshReason: String {
    // Triggers
    case startup
    case interval
    case manual
    case returnedToForeground

    // Skip reasons
    case inProgressSkip
    case intervalNotElapsed
    case disabled
    case backoffActive
}

/// The decision output from the refresh engine.
enum RefreshDecision: Equatable {
    case refresh(reason: RefreshReason)
    case skip(reason: RefreshReason)
}

// MARK: - Engine

/// Pure calculation engine for refresh scheduling decisions.
/// No I/O, no UserDefaults, no SwiftData — fully testable.
enum RefreshScheduleEngine {

    /// Backoff steps in seconds: 2 min, 5 min, 15 min (capped).
    static let backoffSteps: [TimeInterval] = [120, 300, 900]

    /// Primary gate: should we attempt a refresh right now?
    static func shouldRefresh(
        now: Date,
        lastRefreshAt: Date?,
        refreshInterval: Int,
        isRefreshing: Bool,
        lastErrorAt: Date?,
        consecutiveErrors: Int,
        reason: RefreshReason
    ) -> RefreshDecision {
        // 1. Already in progress — always skip
        if isRefreshing {
            return .skip(reason: .inProgressSkip)
        }

        // 2. Manual refresh always wins (bypasses interval + backoff)
        if reason == .manual {
            return .refresh(reason: .manual)
        }

        // 3. Auto-refresh disabled
        if refreshInterval <= 0 {
            return .skip(reason: .disabled)
        }

        // 4. Backoff active after errors
        if consecutiveErrors > 0, let errorAt = lastErrorAt {
            let backoff = backoffInterval(consecutiveErrors: consecutiveErrors)
            if now.timeIntervalSince(errorAt) < backoff {
                return .skip(reason: .backoffActive)
            }
        }

        // 5. Check elapsed time
        let intervalSeconds = Double(refreshInterval) * 60
        if let lastRefresh = lastRefreshAt {
            let elapsed = now.timeIntervalSince(lastRefresh)
            if elapsed < intervalSeconds {
                return .skip(reason: .intervalNotElapsed)
            }
        }
        // nil lastRefreshAt = never refreshed, always passes

        return .refresh(reason: reason)
    }

    /// When is the next refresh due? Returns nil when interval is 0 (disabled).
    static func nextRefreshDate(
        lastRefreshAt: Date?,
        refreshInterval: Int
    ) -> Date? {
        guard refreshInterval > 0 else { return nil }
        let intervalSeconds = Double(refreshInterval) * 60
        let base = lastRefreshAt ?? Date(timeIntervalSince1970: 0)
        return base.addingTimeInterval(intervalSeconds)
    }

    /// How long to wait before retrying after consecutive errors.
    /// Returns 0 for zero errors. Capped at backoffSteps.last.
    static func backoffInterval(consecutiveErrors: Int) -> TimeInterval {
        guard consecutiveErrors > 0 else { return 0 }
        let index = min(consecutiveErrors - 1, backoffSteps.count - 1)
        return backoffSteps[index]
    }
}
