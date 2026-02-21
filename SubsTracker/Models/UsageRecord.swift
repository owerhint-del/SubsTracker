import Foundation
import SwiftData

@Model
final class UsageRecord {
    var id: UUID
    var date: Date
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var totalCost: Double?
    var model: String?
    var sessionCount: Int?
    var messageCount: Int?
    var toolCallCount: Int?
    var source: String // DataSource raw value

    var subscription: Subscription?

    init(
        date: Date,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedTokens: Int = 0,
        totalCost: Double? = nil,
        model: String? = nil,
        sessionCount: Int? = nil,
        messageCount: Int? = nil,
        toolCallCount: Int? = nil,
        source: DataSource = .manual,
        subscription: Subscription? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.totalCost = totalCost
        self.model = model
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.source = source.rawValue
        self.subscription = subscription
    }

    // MARK: - Computed

    var dataSource: DataSource {
        get { DataSource(rawValue: source) ?? .manual }
        set { source = newValue.rawValue }
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cachedTokens
    }
}
