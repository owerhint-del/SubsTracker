import Foundation

// MARK: - Scan Progress

enum ScanPhase: String {
    case searching = "Searching Gmail..."
    case fetching = "Fetching email headers..."
    case grouping = "Grouping by sender..."
    case analyzing = "Sending to AI..."
    case deduplicating = "Deduplicating results..."
}

struct ScanProgress {
    var phase: ScanPhase = .searching
    var current: Int = 0
    var total: Int = 0

    var description: String {
        if total > 0 {
            return "\(phase.rawValue) (\(current)/\(total))"
        }
        return phase.rawValue
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

// MARK: - Email Metadata (headers only, no body)

struct EmailMetadata {
    let id: String
    let from: String
    let subject: String
    let date: Date
    let snippet: String
}

// MARK: - Sender Summary (aggregated from multiple emails)

struct SenderSummary {
    let senderName: String
    let senderDomain: String
    let emailCount: Int
    let amounts: [Double]
    let latestSubject: String
    let latestDate: Date
    let latestSnippet: String
}

// MARK: - Subscription Candidate (found by AI)

struct SubscriptionCandidate: Identifiable {
    let id = UUID()
    var name: String
    var cost: Double
    var billingCycle: BillingCycle
    var category: SubscriptionCategory
    var renewalDate: Date?
    var confidence: Double // 0.0 - 1.0
    var isSelected: Bool = true
    var sourceEmailCount: Int = 1
    var notes: String?

    var confidenceLabel: String {
        if confidence >= 0.9 { return "High" }
        if confidence >= 0.7 { return "Medium" }
        return "Low"
    }

    var confidenceColor: String {
        if confidence >= 0.9 { return "green" }
        if confidence >= 0.7 { return "orange" }
        return "red"
    }
}
