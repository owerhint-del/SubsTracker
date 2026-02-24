import Foundation

// MARK: - Service Provider

enum ServiceProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case codex
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .codex: return "OpenAI Codex"
        case .manual: return "Manual"
        }
    }

    var iconSystemName: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .openai: return "cpu"
        case .codex: return "terminal"
        case .manual: return "square.and.pencil"
        }
    }
}

// MARK: - Billing Cycle

enum BillingCycle: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case annual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .annual: return "Annual"
        }
    }

    /// Normalized monthly cost multiplier
    var monthlyCostMultiplier: Double {
        switch self {
        case .weekly: return 52.0 / 12.0
        case .monthly: return 1.0
        case .annual: return 1.0 / 12.0
        }
    }
}

// MARK: - Data Source

enum DataSource: String, Codable, CaseIterable, Identifiable {
    case api
    case localFile = "local_file"
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .api: return "API"
        case .localFile: return "Local File"
        case .manual: return "Manual Entry"
        }
    }
}

// MARK: - Subscription Status

enum SubscriptionStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case canceled
    case paused
    case expired

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .canceled: return "Canceled"
        case .paused: return "Paused"
        case .expired: return "Expired"
        }
    }

    var iconSystemName: String {
        switch self {
        case .active: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle"
        case .paused: return "pause.circle"
        case .expired: return "clock.badge.xmark"
        }
    }
}

// MARK: - Subscription Category

enum SubscriptionCategory: String, Codable, CaseIterable, Identifiable {
    case aiServices = "AI Services"
    case streaming = "Streaming"
    case saas = "SaaS"
    case development = "Development"
    case productivity = "Productivity"
    case other = "Other"

    var id: String { rawValue }

    var iconSystemName: String {
        switch self {
        case .aiServices: return "brain"
        case .streaming: return "play.tv"
        case .saas: return "cloud"
        case .development: return "hammer"
        case .productivity: return "checkmark.circle"
        case .other: return "ellipsis.circle"
        }
    }
}
