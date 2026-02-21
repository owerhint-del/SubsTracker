import Foundation
import SwiftUI

@MainActor
@Observable
final class UsageViewModel {
    // Claude local data
    var claudeDailyUsage: [ClaudeDailyUsage] = []
    var claudeModelUsage: [String: ClaudeModelUsage] = [:]
    var claudeSummary: ClaudeSummary?
    var claudeError: String?

    // Claude API data (real-time utilization)
    var claudeAPIResult: ClaudeAPIUsageResult?
    var isLoadingClaudeAPI = false

    // OpenAI data
    var openAIDailyUsage: [OpenAIDailyUsage] = []
    var openAIError: String?

    var isLoadingClaude = false
    var isLoadingOpenAI = false

    private let claudeService = ClaudeCodeLocalService.shared
    private let claudeAPIService = ClaudeAPIService.shared
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

    func loadClaudeAPIData() async {
        isLoadingClaudeAPI = true
        claudeAPIResult = await claudeAPIService.fetchUsage()
        isLoadingClaudeAPI = false
    }

    var claudeAPIUsage: ClaudeAPIUsage? {
        claudeAPIResult?.usage
    }

    var hasClaudeAPIData: Bool {
        claudeAPIResult?.isAvailable ?? false
    }

    var claudeAPIStatusMessage: String? {
        guard let result = claudeAPIResult else { return nil }
        switch result {
        case .success: return nil
        case .unavailable: return "Live usage data unavailable — showing local stats"
        case .notLoggedIn: return "Not logged into Claude Code"
        case .error(let msg): return msg
        }
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

    // MARK: - Codex

    var codexDailyUsage: [CodexDailyUsage] = []
    var codexModelUsage: [String: CodexModelUsage] = [:]
    var codexSummary: CodexSummary?
    var codexRateLimits: CodexRateLimits?
    var codexError: String?
    var isLoadingCodex = false

    private let codexService = CodexLocalService.shared

    func loadCodexData() async {
        isLoadingCodex = true
        codexError = nil

        do {
            let service = codexService
            let (daily, models, summary, limits) = try await Task.detached {
                let d = try service.fetchDailyUsage()
                let m = try service.fetchModelUsage()
                let s = try service.fetchSummary()
                let l = try service.fetchRateLimits()
                return (d, m, s, l)
            }.value

            codexDailyUsage = daily
            codexModelUsage = models
            codexSummary = summary
            codexRateLimits = limits
        } catch {
            codexError = error.localizedDescription
        }

        isLoadingCodex = false
    }

    var codexTotalTokens: Int {
        codexModelUsage.values.reduce(0) { total, model in
            total + model.inputTokens + model.outputTokens
        }
    }

    var codexTotalReasoningTokens: Int {
        codexModelUsage.values.reduce(0) { total, model in
            total + model.reasoningTokens
        }
    }

    var codexModelNames: [String] {
        Array(codexModelUsage.keys).sorted()
    }

    func displayCodexModelName(_ rawName: String) -> String {
        if rawName.contains("gpt-5.3-codex") { return "GPT-5.3 Codex" }
        if rawName.contains("gpt-5") { return "GPT-5" }
        if rawName.contains("o3") { return "o3" }
        if rawName.contains("o4-mini") { return "o4-mini" }
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
