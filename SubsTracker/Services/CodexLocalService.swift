import Foundation

/// Reads Codex CLI usage data from ~/.codex/sessions/ JSONL files
final class CodexLocalService: Sendable {
    static let shared = CodexLocalService()

    private let codexBasePath: String

    init(basePath: String? = nil) {
        self.codexBasePath = basePath ?? "\(NSHomeDirectory())/.codex/sessions"
    }

    // MARK: - Snapshot (single-pass)

    /// All Codex data from a single scan — avoids redundant file I/O.
    struct Snapshot {
        let dailyUsage: [CodexDailyUsage]
        let modelUsage: [String: CodexModelUsage]
        let summary: CodexSummary
        let rateLimits: CodexRateLimits?
    }

    /// Scan and parse all session files once, returning every dataset.
    func fetchAll() throws -> Snapshot {
        let files = try scanSessionFiles(daysBack: 30)

        var usageByDate: [String: CodexDailyUsage] = [:]
        var modelUsage: [String: CodexModelUsage] = [:]
        var totalSessions = 0
        var totalMessages = 0
        var firstDate: String?
        var lastRateLimits: CodexRateLimits?

        for file in files {
            let session = try parseSession(at: file.path)
            let dateKey = file.dateString

            // Daily usage
            var daily = usageByDate[dateKey] ?? CodexDailyUsage(
                date: dateKey,
                messageCount: 0,
                sessionCount: 0,
                tokensByModel: [:]
            )
            daily.sessionCount += 1
            daily.messageCount += session.messageCount
            for (model, tokens) in session.tokensByModel {
                daily.tokensByModel[model, default: 0] += tokens
            }
            usageByDate[dateKey] = daily

            // Model usage
            for (model, usage) in session.modelUsage {
                var existing = modelUsage[model] ?? CodexModelUsage(
                    inputTokens: 0,
                    outputTokens: 0,
                    cachedInputTokens: 0,
                    reasoningTokens: 0
                )
                existing.inputTokens += usage.inputTokens
                existing.outputTokens += usage.outputTokens
                existing.cachedInputTokens += usage.cachedInputTokens
                existing.reasoningTokens += usage.reasoningTokens
                modelUsage[model] = existing
            }

            // Summary
            totalSessions += 1
            totalMessages += session.messageCount
            if firstDate == nil || dateKey < (firstDate ?? "") {
                firstDate = dateKey
            }

            // Rate limits — keep the last file's (chronologically latest)
            if let rl = session.rateLimits {
                lastRateLimits = rl
            }
        }

        return Snapshot(
            dailyUsage: usageByDate.values.sorted { $0.date < $1.date },
            modelUsage: modelUsage,
            summary: CodexSummary(
                totalSessions: totalSessions,
                totalMessages: totalMessages,
                firstSessionDate: firstDate
            ),
            rateLimits: lastRateLimits
        )
    }

    /// Lightweight: only fetch rate limits from the most recent session file.
    /// Used for menu-bar-only polling to avoid full 30-day scan.
    func fetchRateLimitsOnly() throws -> CodexRateLimits? {
        let files = try scanSessionFiles(daysBack: 7)
        guard let lastFile = files.last else { return nil }
        let session = try parseSession(at: lastFile.path)
        return session.rateLimits
    }

    // MARK: - File Scanning

    private struct SessionFile {
        let path: String
        let dateString: String // YYYY-MM-DD
    }

    private func scanSessionFiles(daysBack: Int) throws -> [SessionFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexBasePath) else {
            throw CodexDataError.directoryNotFound(codexBasePath)
        }

        let calendar = Calendar.current
        let today = Date()
        var sessionFiles: [SessionFile] = []

        // Generate date paths for the scan window
        for dayOffset in 0..<daysBack {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }

            let year = calendar.component(.year, from: date)
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)

            let dayPath = "\(codexBasePath)/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))"
            let dateString = String(format: "%04d-%02d-%02d", year, month, day)

            guard fm.fileExists(atPath: dayPath) else { continue }

            let contents = try fm.contentsOfDirectory(atPath: dayPath)
            for filename in contents where filename.hasPrefix("rollout-") && filename.hasSuffix(".jsonl") {
                sessionFiles.append(SessionFile(
                    path: "\(dayPath)/\(filename)",
                    dateString: dateString
                ))
            }
        }

        // Sort by path (which includes timestamp) for chronological order
        return sessionFiles.sorted { $0.path < $1.path }
    }

    // MARK: - JSONL Parsing

    private struct ParsedSession {
        var messageCount: Int = 0
        var tokensByModel: [String: Int] = [:]
        var modelUsage: [String: CodexModelUsage] = [:]
        var rateLimits: CodexRateLimits?
        var currentModel: String?
    }

    private func parseSession(at path: String) throws -> ParsedSession {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CodexDataError.parseError("Cannot read file: \(path)")
        }

        var session = ParsedSession()
        // Track per-model last token_count with info for final totals
        var lastTokenInfoByModel: [String: TokenCountInfo] = [:]
        // Track the most recent rate limits (prefer the main "codex" limit)
        var lastMainRateLimits: RawRateLimits?
        var lastAnyRateLimits: RawRateLimits?

        // Parse directly from Data — avoid full String copy.
        // Split on newline byte (0x0A) and parse each line from its Data slice.
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let lineData = data[start..<end]
            start = (end < data.endIndex) ? data.index(after: end) : data.endIndex

            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String ?? ""

            switch type {
            case "turn_context":
                if let payload = json["payload"] as? [String: Any],
                   let model = payload["model"] as? String {
                    session.currentModel = model
                }

            case "event_msg":
                guard let payload = json["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String else { continue }

                switch payloadType {
                case "user_message":
                    session.messageCount += 1

                case "token_count":
                    // Parse token info if present
                    if let info = payload["info"] as? [String: Any],
                       let totalUsage = info["total_token_usage"] as? [String: Any] {
                        let tokenInfo = TokenCountInfo(
                            inputTokens: totalUsage["input_tokens"] as? Int ?? 0,
                            cachedInputTokens: totalUsage["cached_input_tokens"] as? Int ?? 0,
                            outputTokens: totalUsage["output_tokens"] as? Int ?? 0,
                            reasoningTokens: totalUsage["reasoning_output_tokens"] as? Int ?? 0,
                            totalTokens: totalUsage["total_tokens"] as? Int ?? 0
                        )
                        let model = session.currentModel ?? "unknown"
                        lastTokenInfoByModel[model] = tokenInfo
                    }

                    // Parse rate limits
                    if let rl = payload["rate_limits"] as? [String: Any] {
                        let parsed = parseRawRateLimits(rl)
                        let limitId = rl["limit_id"] as? String ?? ""

                        if limitId == "codex" {
                            lastMainRateLimits = parsed
                        }
                        lastAnyRateLimits = parsed
                    }

                default:
                    break
                }

            default:
                break
            }
        }

        // Aggregate final token counts per model
        for (model, info) in lastTokenInfoByModel {
            session.tokensByModel[model] = info.totalTokens

            session.modelUsage[model] = CodexModelUsage(
                inputTokens: info.inputTokens,
                outputTokens: info.outputTokens,
                cachedInputTokens: info.cachedInputTokens,
                reasoningTokens: info.reasoningTokens
            )
        }

        // Build rate limits from the best available source
        if let rl = lastMainRateLimits ?? lastAnyRateLimits {
            session.rateLimits = CodexRateLimits(
                sessionUtilization: rl.primaryUsedPercent,
                sessionResetsAt: rl.primaryResetsAt,
                weeklyUtilization: rl.secondaryUsedPercent,
                weeklyResetsAt: rl.secondaryResetsAt,
                hasCredits: rl.hasCredits,
                creditBalance: rl.creditBalance
            )
        }

        return session
    }

    // MARK: - Rate Limit Parsing

    private struct RawRateLimits {
        var primaryUsedPercent: Double
        var primaryResetsAt: Date?
        var secondaryUsedPercent: Double
        var secondaryResetsAt: Date?
        var hasCredits: Bool
        var creditBalance: String?
    }

    private struct TokenCountInfo {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int
    }

    private func parseRawRateLimits(_ dict: [String: Any]) -> RawRateLimits {
        var result = RawRateLimits(
            primaryUsedPercent: 0,
            primaryResetsAt: nil,
            secondaryUsedPercent: 0,
            secondaryResetsAt: nil,
            hasCredits: false,
            creditBalance: nil
        )

        if let primary = dict["primary"] as? [String: Any] {
            result.primaryUsedPercent = primary["used_percent"] as? Double ?? 0
            if let ts = primary["resets_at"] as? Double {
                result.primaryResetsAt = Date(timeIntervalSince1970: ts)
            } else if let ts = primary["resets_at"] as? Int {
                result.primaryResetsAt = Date(timeIntervalSince1970: Double(ts))
            }
        }

        if let secondary = dict["secondary"] as? [String: Any] {
            result.secondaryUsedPercent = secondary["used_percent"] as? Double ?? 0
            if let ts = secondary["resets_at"] as? Double {
                result.secondaryResetsAt = Date(timeIntervalSince1970: ts)
            } else if let ts = secondary["resets_at"] as? Int {
                result.secondaryResetsAt = Date(timeIntervalSince1970: Double(ts))
            }
        }

        if let credits = dict["credits"] as? [String: Any] {
            result.hasCredits = credits["has_credits"] as? Bool ?? false
            result.creditBalance = credits["balance"] as? String
        }

        return result
    }
}

// MARK: - Data Types

struct CodexDailyUsage {
    let date: String
    var messageCount: Int
    var sessionCount: Int
    var tokensByModel: [String: Int]

    var totalTokens: Int {
        tokensByModel.values.reduce(0, +)
    }

    var parsedDate: Date? {
        SharedDateFormatter.yyyyMMdd.date(from: date)
    }
}

struct CodexModelUsage {
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningTokens: Int
}

struct CodexSummary {
    let totalSessions: Int
    let totalMessages: Int
    let firstSessionDate: String?
}

struct CodexRateLimits {
    let sessionUtilization: Double   // 0-100
    let sessionResetsAt: Date?
    let weeklyUtilization: Double    // 0-100
    let weeklyResetsAt: Date?
    let hasCredits: Bool
    let creditBalance: String?
}

// MARK: - Errors

enum CodexDataError: LocalizedError {
    case directoryNotFound(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "Codex sessions directory not found: \(path)"
        case .parseError(let detail):
            return "Failed to parse Codex data: \(detail)"
        }
    }
}
