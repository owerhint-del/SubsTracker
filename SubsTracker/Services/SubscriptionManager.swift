import Foundation
import SwiftData
import WidgetKit
import AppKit

/// Coordinates data fetching and sync across all services
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    let claudeService = ClaudeCodeLocalService.shared
    let openAIService = OpenAIUsageService.shared
    let notificationService = NotificationService.shared

    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var lastRefreshAtDate: Date?
    @Published var lastErrorAt: Date?
    @Published var consecutiveErrors: Int = 0
    @Published private(set) var currentRefreshInterval: Int = 30
    @Published private(set) var currentPolicyResult: PolicyResult?
    @Published private(set) var isSceneActive: Bool = true

    private var refreshTimer: Timer?
    private var storedContext: ModelContext?
    private var hasStarted = false
    private var backgroundScheduler: NSBackgroundActivityScheduler?
    private var currentThermalState: EnergyThermalState = .nominal
    private var isLowPowerMode: Bool = false
    private var energyObservers: [Any] = []

    /// Whether auto-refresh is enabled (refreshInterval > 0).
    var autoRefreshEnabled: Bool {
        currentRefreshInterval > 0
    }

    /// When the next auto-refresh is due, accounting for energy throttling.
    /// Nil when auto-refresh is disabled.
    var nextRefreshDate: Date? {
        guard currentRefreshInterval > 0 else { return nil }
        guard let last = lastRefreshAtDate else { return nil }
        let effectiveSeconds = currentPolicyResult?.effectiveIntervalSeconds
            ?? Double(currentRefreshInterval) * 60
        return last.addingTimeInterval(effectiveSeconds)
    }

    private init() {
        // Register defaults matching @AppStorage defaults in Views
        UserDefaults.standard.register(defaults: [
            "topUpEnabled": true,
            "topUpBufferValue": 50.0,
            "topUpLeadDays": 2,
            "refreshInterval": 30,
            "backgroundRefreshEnabled": true,
            "energyPolicy": EnergyPolicy.balanced.rawValue
        ])
    }

    // MARK: - Refresh Tiers

    /// Frequent background refresh: only Claude/Codex data.
    /// Safe to call every timer tick — no OpenAI, widget, or notification work.
    func refreshFrequentBackground(context: ModelContext) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil

        // Apply Claude data path from Settings
        let savedPath = UserDefaults.standard.string(forKey: "claudeDataPath") ?? "~/.claude"
        let expandedPath = NSString(string: savedPath).expandingTildeInPath
        claudeService.updateBasePath(expandedPath)

        await refreshClaudeUsage(context: context)

        trackRefreshResult()
        isRefreshing = false
    }

    /// Daily maintenance: OpenAI sync + widget update + notifications.
    /// Gated to run at most once per 24 hours.
    func refreshDailyMaintenance(context: ModelContext) async {
        if openAIService.hasAPIKey {
            await refreshOpenAIUsage(context: context)
        }
        updateWidgetData(context: context)
        await scheduleNotifications(context: context)

        // Mark daily maintenance as done
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastDailyMaintenanceAt")
    }

    /// Full refresh: frequent + daily. Used for manual refresh and first launch.
    /// Re-entrant safe: returns immediately if already refreshing.
    func refreshAll(context: ModelContext) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil

        // Apply Claude data path from Settings
        let savedPath = UserDefaults.standard.string(forKey: "claudeDataPath") ?? "~/.claude"
        let expandedPath = NSString(string: savedPath).expandingTildeInPath
        claudeService.updateBasePath(expandedPath)

        // Frequent: Claude/Codex
        await refreshClaudeUsage(context: context)

        // Daily: OpenAI + widget + notifications (unconditional for manual/full)
        if openAIService.hasAPIKey {
            await refreshOpenAIUsage(context: context)
        }
        updateWidgetData(context: context)
        await scheduleNotifications(context: context)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastDailyMaintenanceAt")

        trackRefreshResult()
        isRefreshing = false
    }

    // MARK: - Daily Gate

    private static let dailyMaintenanceInterval: TimeInterval = 24 * 60 * 60 // 24 hours

    /// Whether daily maintenance is due (>= 24h since last run, or never run).
    func isDailyMaintenanceDue(now: Date = Date()) -> Bool {
        let lastTs = UserDefaults.standard.double(forKey: "lastDailyMaintenanceAt")
        guard lastTs > 0 else { return true } // never run
        let elapsed = now.timeIntervalSince1970 - lastTs
        return elapsed >= Self.dailyMaintenanceInterval
    }

    /// Common success/error tracking after a refresh cycle.
    private func trackRefreshResult() {
        if lastError != nil {
            consecutiveErrors += 1
            lastErrorAt = Date()
        } else {
            consecutiveErrors = 0
            lastErrorAt = nil
            lastRefreshAtDate = Date()
            UserDefaults.standard.set(lastRefreshAtDate!.timeIntervalSince1970, forKey: "lastRefreshAt")
        }
    }

    // MARK: - Auto-Refresh Orchestration

    /// Entry point called once from ContentView.onAppear.
    /// Idempotent — safe to call multiple times (only the first call has effect).
    func startAutoRefresh(context: ModelContext) async {
        guard !hasStarted else { return }
        storedContext = context

        // Sync current refresh interval
        currentRefreshInterval = UserDefaults.standard.integer(forKey: "refreshInterval")

        // Restore persisted lastRefreshAt
        let stored = UserDefaults.standard.double(forKey: "lastRefreshAt")
        lastRefreshAtDate = stored > 0 ? Date(timeIntervalSince1970: stored) : nil

        // Seed initial energy state from ProcessInfo
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        currentThermalState = mapThermalState(ProcessInfo.processInfo.thermalState)
        recomputePolicy()

        // Subscribe to energy/power/sleep notifications
        setupEnergyObservers()

        // Notification setup
        if notificationService.isEnabled {
            await notificationService.requestPermissionIfNeeded()
        }
        notificationService.pruneOldKeys()

        // Startup refresh — frequent always, daily only if due
        var didRefresh = false
        if currentPolicyResult?.shouldSkip != true {
            let decision = RefreshScheduleEngine.shouldRefresh(
                now: Date(),
                lastRefreshAt: lastRefreshAtDate,
                refreshInterval: effectiveIntervalMinutes,
                isRefreshing: isRefreshing,
                lastErrorAt: lastErrorAt,
                consecutiveErrors: consecutiveErrors,
                reason: .startup
            )
            if case .refresh = decision {
                await refreshFrequentBackground(context: context)
                if isDailyMaintenanceDue() {
                    await refreshDailyMaintenance(context: context)
                }
                didRefresh = true
            }
        }

        // Schedule notifications from local data if refresh didn't already do it
        if !didRefresh {
            await scheduleNotifications(context: context)
        }

        // Arm the repeating timer (app starts in active scene)
        scheduleTimer()
        hasStarted = true
    }

    /// Called on every scenePhase change.
    /// isActive=true: restart foreground timer, check if refresh is due.
    /// isActive=false: pause timer, start background scheduler.
    func handleScenePhaseChange(isActive: Bool, context: ModelContext) async {
        guard hasStarted else { return }

        if isActive {
            let wasInactive = !isSceneActive
            isSceneActive = true
            stopBackgroundScheduler()
            recomputePolicy()
            scheduleTimer()

            // Check if refresh is due after returning to foreground
            // Frequent always, daily only if due
            if wasInactive && currentPolicyResult?.shouldSkip != true {
                let decision = RefreshScheduleEngine.shouldRefresh(
                    now: Date(),
                    lastRefreshAt: lastRefreshAtDate,
                    refreshInterval: effectiveIntervalMinutes,
                    isRefreshing: isRefreshing,
                    lastErrorAt: lastErrorAt,
                    consecutiveErrors: consecutiveErrors,
                    reason: .returnedToForeground
                )
                if case .refresh = decision {
                    await refreshFrequentBackground(context: context)
                    if isDailyMaintenanceDue() {
                        await refreshDailyMaintenance(context: context)
                    }
                }
            }
        } else {
            isSceneActive = false
            refreshTimer?.invalidate()
            refreshTimer = nil
            stopBackgroundScheduler()
            startBackgroundSchedulerIfEnabled()
        }
    }

    /// Called from the Dashboard toolbar button.
    func manualRefresh(context: ModelContext) async {
        let decision = RefreshScheduleEngine.shouldRefresh(
            now: Date(),
            lastRefreshAt: lastRefreshAtDate,
            refreshInterval: UserDefaults.standard.integer(forKey: "refreshInterval"),
            isRefreshing: isRefreshing,
            lastErrorAt: lastErrorAt,
            consecutiveErrors: consecutiveErrors,
            reason: .manual
        )
        if case .refresh = decision {
            await refreshAll(context: context)
        }
    }

    /// Re-arms the timer when the user changes refreshInterval or energy policy in Settings.
    func refreshIntervalDidChange() {
        currentRefreshInterval = UserDefaults.standard.integer(forKey: "refreshInterval")
        recomputePolicy()
        if isSceneActive {
            scheduleTimer()
        } else {
            stopBackgroundScheduler()
            startBackgroundSchedulerIfEnabled()
        }
    }

    /// Arms or disarms the foreground repeating timer.
    /// Uses effective interval from energy policy (or raw interval as fallback).
    private func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let interval = UserDefaults.standard.integer(forKey: "refreshInterval")
        guard interval > 0 else { return }

        // If policy says skip, don't arm the timer at all
        if let policy = currentPolicyResult, policy.shouldSkip {
            return
        }

        let intervalSeconds = currentPolicyResult?.effectiveIntervalSeconds
            ?? Double(interval) * 60
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: intervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let context = self.storedContext else { return }
                let effectiveMinutes = self.effectiveIntervalMinutes
                let decision = RefreshScheduleEngine.shouldRefresh(
                    now: Date(),
                    lastRefreshAt: self.lastRefreshAtDate,
                    refreshInterval: effectiveMinutes,
                    isRefreshing: self.isRefreshing,
                    lastErrorAt: self.lastErrorAt,
                    consecutiveErrors: self.consecutiveErrors,
                    reason: .interval
                )
                if case .refresh = decision {
                    await self.refreshFrequentBackground(context: context)
                    if self.isDailyMaintenanceDue() {
                        await self.refreshDailyMaintenance(context: context)
                    }
                }
            }
        }
    }

    // MARK: - Energy-Aware Refresh

    /// Subscribe to system energy/power/sleep notifications.
    /// Called once from startAutoRefresh. Tokens stored to prevent duplicates.
    private func setupEnergyObservers() {
        guard energyObservers.isEmpty else { return }

        // Power state changes (Low Power Mode toggle)
        let powerObs = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.handleEnergyStateChange()
            }
        }
        energyObservers.append(powerObs)

        // Thermal state changes
        let thermalObs = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentThermalState = self.mapThermalState(ProcessInfo.processInfo.thermalState)
                self.handleEnergyStateChange()
            }
        }
        energyObservers.append(thermalObs)

        // Machine sleep — invalidate timer to avoid stale fires on wake
        let sleepObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTimer?.invalidate()
                self?.refreshTimer = nil
                self?.stopBackgroundScheduler()
            }
        }
        energyObservers.append(sleepObs)

        // Machine wake — reschedule based on current state
        let wakeObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.currentThermalState = self.mapThermalState(ProcessInfo.processInfo.thermalState)
                self.recomputePolicy()
                if self.isSceneActive {
                    self.scheduleTimer()
                } else {
                    self.startBackgroundSchedulerIfEnabled()
                }
            }
        }
        energyObservers.append(wakeObs)
    }

    /// React to any energy state change (power, thermal).
    private func handleEnergyStateChange() {
        recomputePolicy()
        if isSceneActive {
            scheduleTimer()
        } else {
            stopBackgroundScheduler()
            startBackgroundSchedulerIfEnabled()
        }
    }

    /// Build PolicyInput from current state and evaluate through the engine.
    private func recomputePolicy() {
        let policyRaw = UserDefaults.standard.string(forKey: "energyPolicy") ?? EnergyPolicy.balanced.rawValue
        let policy = EnergyPolicy(rawValue: policyRaw) ?? .balanced

        let result = BackgroundRefreshPolicyEngine.evaluate(input: PolicyInput(
            baseIntervalMinutes: currentRefreshInterval,
            policy: policy,
            isLowPowerMode: isLowPowerMode,
            thermalState: currentThermalState
        ))
        currentPolicyResult = result
    }

    /// Effective refresh interval in minutes, accounting for energy throttling.
    /// Used to pass to RefreshScheduleEngine for correct elapsed-time gating.
    private var effectiveIntervalMinutes: Int {
        if let policy = currentPolicyResult, !policy.shouldSkip {
            return max(1, Int(policy.effectiveIntervalSeconds / 60))
        }
        return currentRefreshInterval
    }

    /// Map Foundation's ProcessInfo.ThermalState to our pure enum.
    private func mapThermalState(_ state: ProcessInfo.ThermalState) -> EnergyThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    // MARK: - Background Scheduler

    /// Start the NSBackgroundActivityScheduler if background refresh is enabled.
    /// Always invalidates any existing scheduler first to prevent duplicates.
    private func startBackgroundSchedulerIfEnabled() {
        // Replace-safe: always clean up any existing scheduler first
        stopBackgroundScheduler()

        let bgEnabled = UserDefaults.standard.bool(forKey: "backgroundRefreshEnabled")
        guard bgEnabled, currentRefreshInterval > 0 else { return }
        guard !(currentPolicyResult?.shouldSkip ?? false) else { return }

        let effectiveSeconds = currentPolicyResult?.effectiveIntervalSeconds
            ?? Double(currentRefreshInterval) * 60

        let scheduler = NSBackgroundActivityScheduler(
            identifier: "com.owerhintdel.substracker.backgroundRefresh"
        )
        scheduler.repeats = true
        scheduler.interval = effectiveSeconds
        scheduler.tolerance = effectiveSeconds * 0.1

        scheduler.schedule { [weak self, weak scheduler] completion in
            guard self != nil else {
                completion(.finished)
                return
            }
            if scheduler?.shouldDefer == true {
                completion(.deferred)
                return
            }
            Task { @MainActor [weak self] in
                defer { completion(.finished) }
                guard let self, let context = self.storedContext else { return }
                let effectiveMinutes = self.effectiveIntervalMinutes
                let decision = RefreshScheduleEngine.shouldRefresh(
                    now: Date(),
                    lastRefreshAt: self.lastRefreshAtDate,
                    refreshInterval: effectiveMinutes,
                    isRefreshing: self.isRefreshing,
                    lastErrorAt: self.lastErrorAt,
                    consecutiveErrors: self.consecutiveErrors,
                    reason: .interval
                )
                if case .refresh = decision {
                    await self.refreshFrequentBackground(context: context)
                    if self.isDailyMaintenanceDue() {
                        await self.refreshDailyMaintenance(context: context)
                    }
                }
            }
        }
        backgroundScheduler = scheduler
    }

    /// Invalidate the background scheduler.
    private func stopBackgroundScheduler() {
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
    }

    // MARK: - Notifications

    /// Build snapshots from SwiftData models and pass to NotificationService.
    func scheduleNotifications(context: ModelContext) async {
        let subDescriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.renewalDate)]
        )
        let subscriptions = (try? context.fetch(subDescriptor)) ?? []

        // Compute current month spend for budget check
        let calendar = Calendar.current
        let now = Date()

        // Build lightweight snapshots (safe to pass off MainActor)
        // Project stale renewal dates forward when setting is enabled
        let autoCorrect = UserDefaults.standard.object(forKey: "autoCorrectRenewalDates") as? Bool ?? true
        var snapshots: [SubscriptionSnapshot] = []
        for sub in subscriptions {
            let effectiveDate: Date
            if autoCorrect {
                effectiveDate = RenewalProjectionEngine.projectRenewalDate(
                    from: sub.renewalDate, billingCycle: sub.billing, now: now
                ).projectedDate
            } else {
                effectiveDate = sub.renewalDate
            }
            snapshots.append(SubscriptionSnapshot(
                id: sub.id,
                name: sub.name,
                cost: sub.cost,
                renewalDate: effectiveDate
            ))
        }
        let recurringMonthly = subscriptions.reduce(0.0) { $0 + $1.monthlyCost }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let monthUsageDescriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= monthStart && $0.date < nextMonthStart }
        )
        let currentMonthUsage = (try? context.fetch(monthUsageDescriptor)) ?? []
        let variableSpend = currentMonthUsage.compactMap(\.totalCost).reduce(0, +)
        let totalMonthly = recurringMonthly + variableSpend

        let budget = UserDefaults.standard.double(forKey: "monthlyBudget")
        let threshold = UserDefaults.standard.integer(forKey: "alertThresholdPercent")
        let currency = UserDefaults.standard.string(forKey: "currencyCode") ?? "USD"
        let cashReserve = UserDefaults.standard.double(forKey: "cashReserve")

        // Compute top-up recommendation for notification
        var topUpRec: TopUpRecommendation?
        let topUpEnabled = UserDefaults.standard.object(forKey: "topUpEnabled") as? Bool ?? true
        if topUpEnabled && cashReserve > 0 {
            let plannerSubs = subscriptions.map { sub in
                PlannerSubscription(
                    name: sub.name,
                    cost: sub.cost,
                    billingCycle: sub.billing,
                    renewalDate: sub.renewalDate
                )
            }
            // Fetch last 30 days usage for API spend projection
            let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!
            let last30Descriptor = FetchDescriptor<UsageRecord>(
                predicate: #Predicate<UsageRecord> { $0.date >= thirtyDaysAgo }
            )
            let last30Usage = (try? context.fetch(last30Descriptor)) ?? []
            let usageCosts = last30Usage.compactMap(\.totalCost)

            // Count actual days with data, not the fixed 30-day window
            let usageDaysOfData: Int
            if let oldest = last30Usage.min(by: { $0.date < $1.date })?.date {
                usageDaysOfData = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: oldest), to: now).day ?? 0)
            } else {
                usageDaysOfData = 0
            }

            // Use effectiveReserve (deducting recent one-time purchases)
            let purchaseDescriptor = FetchDescriptor<OneTimePurchase>()
            let purchases = (try? context.fetch(purchaseDescriptor)) ?? []
            let purchaseSnapshots = purchases.map {
                OneTimePurchaseEngine.PurchaseSnapshot(
                    name: $0.name, amount: $0.amount, date: $0.date, category: $0.purchaseCategory
                )
            }
            let effectiveReserve = OneTimePurchaseEngine.effectiveReserve(
                cashReserve: cashReserve,
                purchases: purchaseSnapshots,
                now: now
            )

            let plannerResult = FundingPlannerEngine.calculate(
                subscriptions: plannerSubs,
                usageCosts: usageCosts,
                usageDaysOfData: usageDaysOfData,
                cashReserve: effectiveReserve,
                now: now
            )

            let bufferModeRaw = UserDefaults.standard.string(forKey: "topUpBufferMode") ?? TopUpBufferMode.fixed.rawValue
            let bufferMode = TopUpBufferMode(rawValue: bufferModeRaw) ?? .fixed
            let bufferValue = UserDefaults.standard.double(forKey: "topUpBufferValue")
            let leadDays = UserDefaults.standard.integer(forKey: "topUpLeadDays")

            topUpRec = TopUpRecommendationEngine.calculate(
                plannerResult: plannerResult,
                cashReserve: effectiveReserve,
                bufferMode: bufferMode,
                bufferValue: bufferValue,
                leadDays: max(1, leadDays),
                now: now
            )
        }

        await notificationService.scheduleNotifications(
            subscriptions: snapshots,
            totalMonthlySpend: totalMonthly,
            monthlyBudget: budget,
            alertThresholdPercent: threshold > 0 ? threshold : 90,
            currencyCode: currency,
            topUpRecommendation: topUpRec
        )
    }

    // MARK: - Widget Data

    /// Build and save a WidgetData snapshot for the widget extension to display.
    func updateWidgetData(context: ModelContext) {
        let subDescriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.renewalDate)]
        )
        let subscriptions = (try? context.fetch(subDescriptor)) ?? []

        let recurringMonthly = subscriptions.reduce(0.0) { $0 + $1.monthlyCost }
        let savedCurrency = UserDefaults.standard.string(forKey: "currencyCode") ?? "USD"

        // Build upcoming renewals sorted by nearest projected date
        let now = Date()
        let autoCorrect = UserDefaults.standard.object(forKey: "autoCorrectRenewalDates") as? Bool ?? true

        // Compute effective (projected) renewal dates for each subscription
        let effectiveDates: [Date] = subscriptions.map { sub in
            if autoCorrect {
                return RenewalProjectionEngine.projectRenewalDate(
                    from: sub.renewalDate, billingCycle: sub.billing, now: now
                ).projectedDate
            } else {
                return sub.renewalDate
            }
        }

        // Build sorted indices of upcoming subscriptions (startOfDay so today's renewals are included)
        let todayStart = Calendar.current.startOfDay(for: now)
        let upcomingIndices = subscriptions.indices
            .filter { effectiveDates[$0] >= todayStart }
            .sorted { effectiveDates[$0] < effectiveDates[$1] }

        var upcoming: [WidgetData.UpcomingRenewal] = []
        for i in upcomingIndices.prefix(3) {
            let sub = subscriptions[i]
            upcoming.append(WidgetData.UpcomingRenewal(
                name: sub.name,
                iconName: sub.displayIcon,
                renewalDate: effectiveDates[i],
                monthlyCost: sub.monthlyCost
            ))
        }

        // Next charge signal
        let nextChargeName: String? = upcomingIndices.first.map { subscriptions[$0].name }
        let nextChargeDaysUntil: Int? = upcomingIndices.first.map { i in
            Calendar.current.dateComponents([.day], from: now, to: effectiveDates[i]).day ?? 0
        }

        // Variable spend for the current month
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let monthUsageDescriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate<UsageRecord> { $0.date >= monthStart && $0.date < nextMonthStart }
        )
        let currentMonthUsage = (try? context.fetch(monthUsageDescriptor)) ?? []
        let variableSpend = currentMonthUsage.compactMap(\.totalCost).reduce(0, +)

        // Forecast: linear extrapolation of variable spend
        let elapsedDays = calendar.dateComponents([.day], from: monthStart, to: now).day ?? 0
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let projectedVariable: Double
        if elapsedDays > 0 {
            projectedVariable = (variableSpend / Double(elapsedDays)) * Double(daysInMonth)
        } else {
            projectedVariable = variableSpend
        }
        let forecastedMonthly = recurringMonthly + projectedVariable

        // Budget percent
        let monthlyBudget = UserDefaults.standard.double(forKey: "monthlyBudget")
        let totalMonthly = recurringMonthly + variableSpend
        let budgetPct: Double? = monthlyBudget > 0 ? (totalMonthly / monthlyBudget) * 100 : nil

        let widgetData = WidgetData(
            totalMonthlyCost: totalMonthly,
            totalAnnualCost: recurringMonthly * 12,
            subscriptionCount: subscriptions.count,
            recentTotalTokens: 0,
            currencyCode: savedCurrency,
            lastUpdated: now,
            upcomingRenewals: Array(upcoming),
            nextChargeName: nextChargeName,
            nextChargeDaysUntil: nextChargeDaysUntil,
            budgetUsedPercent: budgetPct,
            forecastedMonthlySpend: forecastedMonthly
        )

        widgetData.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Claude Usage Sync

    func refreshClaudeUsage(context: ModelContext) async {
        do {
            let dailyUsage = try claudeService.fetchAll().dailyUsage

            // Find or create Claude subscription
            let claudeSub = findOrCreateSubscription(
                name: "Claude Code (Max)",
                provider: .anthropic,
                cost: 200,
                billingCycle: .monthly,
                category: .aiServices,
                context: context
            )

            // Sync daily usage records
            for daily in dailyUsage {
                guard let date = daily.parsedDate else { continue }

                let dateStart = Calendar.current.startOfDay(for: date)
                guard let dateEnd = Calendar.current.date(byAdding: .day, value: 1, to: dateStart) else { continue }
                let sourceRaw = DataSource.localFile.rawValue

                // Fetch all usage records for this source and date range,
                // then filter in memory to avoid SwiftData optional predicate issues
                let descriptor = FetchDescriptor<UsageRecord>(
                    predicate: #Predicate<UsageRecord> { record in
                        record.source == sourceRaw &&
                        record.date >= dateStart &&
                        record.date < dateEnd
                    }
                )

                let existing = (try? context.fetch(descriptor)) ?? []
                let alreadySynced = existing.contains { $0.subscription?.id == claudeSub.id }
                if !alreadySynced {
                    let record = UsageRecord(
                        date: date,
                        inputTokens: daily.totalTokens,
                        outputTokens: 0,
                        sessionCount: daily.sessionCount,
                        messageCount: daily.messageCount,
                        toolCallCount: daily.toolCallCount,
                        source: .localFile,
                        subscription: claudeSub
                    )
                    context.insert(record)
                }
            }

            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - OpenAI Usage Sync

    func refreshOpenAIUsage(context: ModelContext) async {
        do {
            guard let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) else { return }
            let dailyUsage = try await openAIService.fetchUsage(from: thirtyDaysAgo)

            // Find or create OpenAI subscription
            let openAISub = findOrCreateSubscription(
                name: "OpenAI API",
                provider: .openai,
                cost: 0, // Pay-as-you-go
                billingCycle: .monthly,
                category: .aiServices,
                context: context
            )

            for daily in dailyUsage {
                guard let date = daily.parsedDate else { continue }

                let dateStart = Calendar.current.startOfDay(for: date)
                guard let dateEnd = Calendar.current.date(byAdding: .day, value: 1, to: dateStart) else { continue }
                let sourceRaw = DataSource.api.rawValue

                let descriptor = FetchDescriptor<UsageRecord>(
                    predicate: #Predicate<UsageRecord> { record in
                        record.source == sourceRaw &&
                        record.date >= dateStart &&
                        record.date < dateEnd
                    }
                )

                let existing = (try? context.fetch(descriptor)) ?? []
                let alreadySynced = existing.contains { $0.subscription?.id == openAISub.id }
                if !alreadySynced {
                    let record = UsageRecord(
                        date: date,
                        inputTokens: daily.inputTokens ?? 0,
                        outputTokens: daily.outputTokens ?? 0,
                        totalCost: daily.cost,
                        model: daily.model,
                        source: .api,
                        subscription: openAISub
                    )
                    context.insert(record)
                }
            }

            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func findOrCreateSubscription(
        name: String,
        provider: ServiceProvider,
        cost: Double,
        billingCycle: BillingCycle,
        category: SubscriptionCategory,
        context: ModelContext
    ) -> Subscription {
        let providerRaw = provider.rawValue
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate<Subscription> { sub in
                sub.provider == providerRaw && sub.isAPIConnected == true
            }
        )

        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let subscription = Subscription(
            name: name,
            provider: provider,
            cost: cost,
            billingCycle: billingCycle,
            category: category,
            isAPIConnected: true
        )
        context.insert(subscription)
        return subscription
    }
}
