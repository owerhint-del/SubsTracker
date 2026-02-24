import Foundation
import Combine

/// Coordinates high-frequency polling for usage data (Claude/OpenAI/Codex).
/// Single timer owner — consumers register/unregister interest.
/// Menu bar counts as an implicit consumer when enabled.
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

    // MARK: - Consumer Tracking

    /// Number of view-based consumers (usage views that called registerConsumer)
    private(set) var viewConsumerCount = 0

    /// Whether the menu bar live label is enabled (read from UserDefaults)
    var menuBarLiveEnabled: Bool {
        // UserDefaults.bool returns false for unset keys; default is ON
        UserDefaults.standard.object(forKey: "menuBarEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "menuBarEnabled")
    }

    /// True when any consumer needs live data
    var hasActiveConsumer: Bool {
        UsagePollingEngine.hasActiveConsumer(
            viewConsumerCount: viewConsumerCount,
            menuBarEnabled: menuBarLiveEnabled
        )
    }

    // MARK: - App State

    private(set) var isAppActive = true

    // MARK: - Timer

    private var timer: Timer?
    private var refreshAction: (() async -> Bool)?       // full refresh (all data)
    private var lightRefreshAction: (() async -> Bool)?  // lightweight (menu bar only)

    // MARK: - Lifecycle

    /// Set the shared refresh actions. Call once at app startup.
    /// `full`: refreshes all usage data (for when usage views are open).
    /// `light`: refreshes only menu-bar data (API utilization + rate limits).
    func setRefreshActions(
        full: @escaping () async -> Bool,
        light: @escaping () async -> Bool
    ) {
        refreshAction = full
        lightRefreshAction = light
        evaluateTimer()
        // Immediate first refresh if consumers are waiting
        if hasActiveConsumer && isAppActive {
            Task { await refreshNow() }
        }
    }

    /// Register a view-based consumer (call from onAppear of usage views).
    func registerConsumer() {
        viewConsumerCount += 1
        evaluateTimer()
    }

    /// Unregister a view-based consumer (call from onDisappear of usage views).
    func unregisterConsumer() {
        viewConsumerCount = max(0, viewConsumerCount - 1)
        evaluateTimer()
    }

    /// Notify scene phase change. Call from onChange(of: scenePhase).
    func scenePhaseChanged(isActive: Bool) {
        isAppActive = isActive
        evaluateTimer()
    }

    /// Re-evaluate timer state (call when settings change).
    func evaluateTimer() {
        if hasActiveConsumer && isAppActive && refreshAction != nil && intervalSeconds > 0 {
            scheduleTimer()
        } else {
            cancelTimer()
        }
    }

    /// Force an immediate full refresh (manual refresh button).
    func refreshNow() async {
        guard !isRefreshing, let action = refreshAction else { return }
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
        evaluateTimer()
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
        intervalSeconds > 0 && hasActiveConsumer && isAppActive
    }

    // MARK: - Private

    private func scheduleTimer() {
        cancelTimer()
        let interval = intervalSeconds
        guard interval > 0, hasActiveConsumer, isAppActive, refreshAction != nil else { return }

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
            isViewVisible: hasActiveConsumer,
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
        guard refreshAction != nil else { return }
        isRefreshing = true

        // Use lightweight refresh when only menu bar is active (no usage views open)
        let action: () async -> Bool
        if viewConsumerCount == 0, let light = lightRefreshAction {
            action = light
        } else {
            action = refreshAction!
        }

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
        evaluateTimer()
    }
}
