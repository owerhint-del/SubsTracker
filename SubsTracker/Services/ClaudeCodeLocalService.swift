import Foundation

/// Reads Claude Code usage data directly from ~/.claude/ filesystem
final class ClaudeCodeLocalService {
    static let shared = ClaudeCodeLocalService()

    private var claudeBasePath: String

    init(basePath: String? = nil) {
        self.claudeBasePath = basePath ?? "\(NSHomeDirectory())/.claude"
    }

    func updateBasePath(_ path: String) {
        claudeBasePath = path
    }

    // MARK: - Stats Cache

    /// Reads and parses ~/.claude/stats-cache.json
    func readStatsCache() throws -> ClaudeStatsCache {
        let url = URL(fileURLWithPath: claudeBasePath)
            .appendingPathComponent("stats-cache.json")

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClaudeDataError.fileNotFound(url.path)
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ClaudeStatsCache.self, from: data)
    }

    /// Converts stats cache into UsageRecord-compatible data
    func fetchDailyUsage() throws -> [ClaudeDailyUsage] {
        let cache = try readStatsCache()
        var usageByDate: [String: ClaudeDailyUsage] = [:]

        // Merge daily activity with daily model tokens
        for activity in cache.dailyActivity {
            usageByDate[activity.date] = ClaudeDailyUsage(
                date: activity.date,
                messageCount: activity.messageCount,
                sessionCount: activity.sessionCount,
                toolCallCount: activity.toolCallCount,
                tokensByModel: [:]
            )
        }

        for modelTokens in cache.dailyModelTokens {
            if usageByDate[modelTokens.date] != nil {
                usageByDate[modelTokens.date]?.tokensByModel = modelTokens.tokensByModel
            } else {
                usageByDate[modelTokens.date] = ClaudeDailyUsage(
                    date: modelTokens.date,
                    messageCount: 0,
                    sessionCount: 0,
                    toolCallCount: 0,
                    tokensByModel: modelTokens.tokensByModel
                )
            }
        }

        return usageByDate.values
            .sorted { $0.date < $1.date }
    }

    /// Total aggregate model usage from the cache
    func fetchModelUsage() throws -> [String: ClaudeModelUsage] {
        let cache = try readStatsCache()
        return cache.modelUsage
    }

    /// Summary stats (total sessions, messages, etc.)
    func fetchSummary() throws -> ClaudeSummary {
        let cache = try readStatsCache()
        return ClaudeSummary(
            totalSessions: cache.totalSessions,
            totalMessages: cache.totalMessages,
            firstSessionDate: cache.firstSessionDate,
            lastComputedDate: cache.lastComputedDate
        )
    }
}

// MARK: - Claude Stats JSON Models

struct ClaudeStatsCache: Codable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]
    let modelUsage: [String: ClaudeModelUsage]
    let totalSessions: Int
    let totalMessages: Int
    let longestSession: LongestSession?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?

    struct DailyActivity: Codable {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    struct DailyModelTokens: Codable {
        let date: String
        let tokensByModel: [String: Int]
    }

    struct LongestSession: Codable {
        let sessionId: String
        let duration: Int
        let messageCount: Int
        let timestamp: String
    }
}

struct ClaudeModelUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int
    let costUSD: Double
}

// MARK: - Processed Data Types

struct ClaudeDailyUsage {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
    var tokensByModel: [String: Int]

    var totalTokens: Int {
        tokensByModel.values.reduce(0, +)
    }

    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }
}

struct ClaudeSummary {
    let totalSessions: Int
    let totalMessages: Int
    let firstSessionDate: String?
    let lastComputedDate: String
}

// MARK: - Errors

enum ClaudeDataError: LocalizedError {
    case fileNotFound(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Claude data file not found: \(path)"
        case .parseError(let detail):
            return "Failed to parse Claude data: \(detail)"
        }
    }
}
