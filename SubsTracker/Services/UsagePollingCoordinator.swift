import Foundation
import Combine

/// Coordinates high-frequency polling for usage data (Claude/OpenAI/Codex).
/// Owns the timer lifecycle, tracks errors, and respects view visibility + scene phase.
@MainActor
@Observable
final class UsagePollingCoordinator {

    // MARK: - Observable State

    private(set) var isRefreshing = false
    private(set) var consecutiveErrors = 0
    private(set) var lastErrorAt: Date?

    // MARK: - Configuration (read from UserDefaults)

    var intervalSeconds: Int {
        let raw = UserDefaults.standard.integer(forKey: "usageRefreshSeconds")
        return UsagePollingEngine.clampInterval(raw)
    }

    // MARK: - Visibility Tracking

    private(set) var isViewVisible = false
    private(set) var isAppActive = true

    // MARK: - Timer

    private var timer: Timer?
    private var refreshAction: (() async -> Bool)?  // returns true on success

    // MARK: - Lifecycle

    /// Start polling. Call from onAppear of a usage view.
    /// The refreshAction should return `true` on success, `false` on error.
    func startPolling(action: @escaping () async -> Bool) {
        refreshAction = action
        isViewVisible = true
        scheduleTimer()
    }

    /// Stop polling. Call from onDisappear of a usage view.
    func stopPolling() {
        isViewVisible = false
        cancelTimer()
        refreshAction = nil
    }

    /// Notify scene phase change. Call from onChange(of: scenePhase).
    func scenePhaseChanged(isActive: Bool) {
        isAppActive = isActive
        if isActive && isViewVisible {
            scheduleTimer()
        } else {
            cancelTimer()
        }
    }

    /// Force an immediate refresh (manual refresh button).
    func refreshNow() async {
        guard !isRefreshing else { return }
        await executeRefresh()
    }

    // MARK: - Status

    var statusLabel: String {
        UsagePollingEngine.statusLabel(
            intervalSeconds: intervalSeconds,
            isRefreshing: isRefreshing,
            consecutiveErrors: consecutiveErrors,
            lastErrorAt: lastErrorAt
        )
    }

    var isLive: Bool {
        intervalSeconds > 0 && isViewVisible && isAppActive
    }

    // MARK: - Private

    private func scheduleTimer() {
        cancelTimer()
        let interval = intervalSeconds
        guard interval > 0, isViewVisible, isAppActive else { return }

        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.tick()
            }
        }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() async {
        let decision = UsagePollingEngine.shouldRefresh(
            intervalSeconds: intervalSeconds,
            isRefreshing: isRefreshing,
            isViewVisible: isViewVisible,
            isAppActive: isAppActive,
            consecutiveErrors: consecutiveErrors,
            lastErrorAt: lastErrorAt
        )

        switch decision {
        case .refresh:
            await executeRefresh()
        case .skipBackoff:
            // Check if backoff expired — if so, reset errors and retry
            if let errorDate = lastErrorAt,
               Date().timeIntervalSince(errorDate) >= UsagePollingEngine.backoffDuration {
                consecutiveErrors = 0
                lastErrorAt = nil
                await executeRefresh()
            }
        default:
            break
        }
    }

    private func executeRefresh() async {
        guard let action = refreshAction else { return }
        isRefreshing = true

        let success = await action()

        isRefreshing = false

        if success {
            consecutiveErrors = 0
            lastErrorAt = nil
        } else {
            consecutiveErrors += 1
            lastErrorAt = Date()
        }

        // Re-evaluate timer interval (user might have changed it in Settings)
        if isViewVisible && isAppActive {
            let currentInterval = intervalSeconds
            if currentInterval == 0 {
                cancelTimer()
            } else if timer == nil || !timer!.isValid {
                scheduleTimer()
            }
        }
    }
}
