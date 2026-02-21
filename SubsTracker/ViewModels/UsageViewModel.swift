import Foundation
import SwiftUI

@MainActor
@Observable
final class UsageViewModel {
    // Claude data
    var claudeDailyUsage: [ClaudeDailyUsage] = []
    var claudeModelUsage: [String: ClaudeModelUsage] = [:]
    var claudeSummary: ClaudeSummary?
    var claudeError: String?

    // OpenAI data
    var openAIDailyUsage: [OpenAIDailyUsage] = []
    var openAIError: String?

    var isLoadingClaude = false
    var isLoadingOpenAI = false

    private let claudeService = ClaudeCodeLocalService.shared
    private let openAIService = OpenAIUsageService.shared

    // MARK: - Claude

    func loadClaudeData() {
        isLoadingClaude = true
        claudeError = nil

        do {
            claudeDailyUsage = try claudeService.fetchDailyUsage()
            claudeModelUsage = try claudeService.fetchModelUsage()
            claudeSummary = try claudeService.fetchSummary()
        } catch {
            claudeError = error.localizedDescription
        }

        isLoadingClaude = false
    }

    var claudeTotalTokens: Int {
        claudeModelUsage.values.reduce(0) { total, model in
            total + model.inputTokens + model.outputTokens
        }
    }

    var claudeTotalCachedTokens: Int {
        claudeModelUsage.values.reduce(0) { total, model in
            total + model.cacheReadInputTokens
        }
    }

    var claudeModelNames: [String] {
        Array(claudeModelUsage.keys).sorted()
    }

    /// Human-friendly model name
    func displayModelName(_ rawName: String) -> String {
        if rawName.contains("opus-4-6") { return "Opus 4.6" }
        if rawName.contains("opus-4-5") { return "Opus 4.5" }
        if rawName.contains("sonnet-4-5") || rawName.contains("sonnet-4-6") { return "Sonnet 4.5" }
        if rawName.contains("haiku") { return "Haiku" }
        return rawName
    }

    // MARK: - OpenAI

    func loadOpenAIData() async {
        isLoadingOpenAI = true
        openAIError = nil

        do {
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            openAIDailyUsage = try await openAIService.fetchUsage(from: thirtyDaysAgo)
        } catch {
            openAIError = error.localizedDescription
        }

        isLoadingOpenAI = false
    }

    var hasOpenAIKey: Bool {
        openAIService.hasAPIKey
    }

    var openAITotalTokens: Int {
        openAIDailyUsage.reduce(0) { $0 + $1.totalTokens }
    }

    var openAITotalCost: Double {
        openAIDailyUsage.compactMap(\.cost).reduce(0, +)
    }
}
