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

// MARK: - Email Summary (for timeline)

struct EmailSummary {
    let date: Date
    let subject: String
    let snippet: String
    var bodyExcerpt: String?  // first ~500 chars of plain-text body (for lifecycle signals)
}

// MARK: - Cost Source

enum CostSource: String {
    case subject
    case snippet
    case body
    case estimated
}

// MARK: - Charge Type

enum ChargeType: String, CaseIterable {
    case recurringSubscription = "recurring_subscription"
    case usageTopup = "usage_topup"
    case addonCredits = "addon_credits"
    case oneTimePurchase = "one_time_purchase"
    case refundOrReversal = "refund_or_reversal"
    case unknown

    var displayName: String {
        switch self {
        case .recurringSubscription: return "Subscription"
        case .usageTopup: return "API Top-up"
        case .addonCredits: return "Credits/Add-on"
        case .oneTimePurchase: return "One-time"
        case .refundOrReversal: return "Refund"
        case .unknown: return "Unknown"
        }
    }

    var isRecurring: Bool { self == .recurringSubscription }

    var isNonRecurring: Bool {
        switch self {
        case .usageTopup, .addonCredits, .oneTimePurchase: return true
        default: return false
        }
    }

    var iconSystemName: String {
        switch self {
        case .recurringSubscription: return "arrow.triangle.2.circlepath"
        case .usageTopup: return "gauge.with.dots.needle.33percent"
        case .addonCredits: return "creditcard"
        case .oneTimePurchase: return "bag"
        case .refundOrReversal: return "arrow.uturn.backward"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Scan Configuration Defaults

enum ScanConfig {
    static let defaultMaxMessages = 500
    static let defaultLookbackMonths = 12
    static let defaultIncludeSpamTrash = true
}

// MARK: - Sender Summary (aggregated from multiple emails)

struct SenderSummary {
    let senderName: String
    let senderDomain: String
    let queryDomain: String     // real email sender domain for Gmail queries (differs from senderDomain for processor splits)
    let emailCount: Int
    let amounts: [Double]
    let latestSubject: String
    let latestDate: Date
    let latestSnippet: String
    var billingScore: Double = 0
    var bodyText: String?       // populated by selective body fetch
    var recentEmails: [EmailSummary] = []  // up to 10, newest first
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
    var costSource: CostSource = .estimated
    var isEstimated: Bool = true
    var evidence: String?
    var chargeType: ChargeType = .unknown
    var subscriptionStatus: SubscriptionStatus = .active
    var statusEffectiveDate: Date?
    var lifecycleConfidence: Double?  // deterministic lifecycle resolver confidence (separate from AI)

    /// Best available lifecycle confidence: deterministic resolver when available, otherwise AI confidence.
    var effectiveLifecycleConfidence: Double {
        lifecycleConfidence ?? confidence
    }

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

    var costSourceLabel: String {
        isEstimated ? "Estimated" : "Extracted"
    }
}
