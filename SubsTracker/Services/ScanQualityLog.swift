import Foundation

/// File I/O service for scan quality telemetry.
/// Stores entries as JSON-lines in Application Support — no SwiftData dependency.
final class ScanQualityLog {
    static let shared = ScanQualityLog()

    private let fileName = "scan_quality_log.jsonl"
    private let retentionDays = 90

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SubsTracker", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    // MARK: - Write

    func append(_ entry: ScanQualityEngine.ScanQualityEntry) {
        appendBatch([entry])
    }

    func appendBatch(_ entries: [ScanQualityEngine.ScanQualityEntry]) {
        guard !entries.isEmpty else { return }

        ensureDirectory()

        var lines = ""
        for entry in entries {
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8) else { continue }
            lines += json + "\n"
        }

        guard let lineData = lines.data(using: .utf8), !lineData.isEmpty else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle.seekToEndOfFile()
            handle.write(lineData)
            handle.closeFile()
        } else {
            try? lineData.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Read

    func entries(from: Date, to: Date) -> [ScanQualityEngine.ScanQualityEntry] {
        allEntries().filter { $0.timestamp >= from && $0.timestamp < to }
    }

    func allEntries() -> [ScanQualityEngine.ScanQualityEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return [] }

        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ScanQualityEngine.ScanQualityEntry.self, from: lineData)
            }
    }

    // MARK: - Update Outcomes

    func updateOutcomes(scanId: String, outcomes: [(serviceName: String, outcome: String, resultingStatus: String?, wasReactivation: Bool)]) {
        guard !outcomes.isEmpty else { return }

        var all = allEntries()
        var changed = false

        for i in all.indices where all[i].scanId == scanId {
            if let match = outcomes.first(where: { GmailSignalEngine.namesMatch($0.serviceName, all[i].serviceName) }) {
                all[i].outcome = match.outcome
                all[i].resultingStatus = match.resultingStatus
                all[i].wasReactivation = match.wasReactivation
                changed = true
            }
        }

        guard changed else { return }
        rewriteAll(all)
    }

    // MARK: - Purge

    func purgeOlderThan(_ date: Date? = nil) {
        let cutoff = date ?? Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
        let kept = allEntries().filter { $0.timestamp >= cutoff }
        rewriteAll(kept)
    }

    // MARK: - Export (delegates to engine)

    func exportJSON(from: Date, to: Date) -> Data {
        let all = entries(from: from, to: to)
        let report = ScanQualityEngine.generateReport(entries: all, from: from, to: to)
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    func exportCSV(from: Date, to: Date) -> String {
        let all = entries(from: from, to: to)
        return ScanQualityEngine.generateCSVReport(entries: all, from: from, to: to)
    }

    // MARK: - Helpers

    private func ensureDirectory() {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func rewriteAll(_ entries: [ScanQualityEngine.ScanQualityEntry]) {
        ensureDirectory()
        var lines = ""
        for entry in entries {
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8) else { continue }
            lines += json + "\n"
        }
        try? lines.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
