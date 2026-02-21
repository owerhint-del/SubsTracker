import Foundation
import SwiftData

/// Coordinates data fetching and sync across all services
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    let claudeService = ClaudeCodeLocalService.shared
    let openAIService = OpenAIUsageService.shared

    @Published var isRefreshing = false
    @Published var lastError: String?

    private init() {}

    // MARK: - Refresh All

    /// Refresh usage data for all API-connected subscriptions
    func refreshAll(context: ModelContext) async {
        isRefreshing = true
        lastError = nil

        // Apply Claude data path from Settings
        let savedPath = UserDefaults.standard.string(forKey: "claudeDataPath") ?? "~/.claude"
        let expandedPath = NSString(string: savedPath).expandingTildeInPath
        claudeService.updateBasePath(expandedPath)

        // Refresh Claude data
        await refreshClaudeUsage(context: context)

        // Refresh OpenAI data if key is available
        if openAIService.hasAPIKey {
            await refreshOpenAIUsage(context: context)
        }

        isRefreshing = false
    }

    // MARK: - Claude Usage Sync

    func refreshClaudeUsage(context: ModelContext) async {
        do {
            let dailyUsage = try claudeService.fetchDailyUsage()

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
