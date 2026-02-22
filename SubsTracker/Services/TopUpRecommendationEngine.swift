import Foundation

// MARK: - Types

/// How the safety buffer is calculated.
enum TopUpBufferMode: String, CaseIterable, Identifiable {
    case fixed = "Fixed Amount"
    case percent = "Percent of Required"

    var id: String { rawValue }
}

/// Urgency level for a top-up recommendation.
enum TopUpUrgency: String, Comparable {
    case none = "None"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    private var sortOrder: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (lhs: TopUpUrgency, rhs: TopUpUrgency) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Complete top-up recommendation output.
struct TopUpRecommendation {
    let recommendedAmount: Double
    let recommendedDate: Date?
    let urgency: TopUpUrgency
    let reason: String
}

// MARK: - Engine

/// Pure calculation engine for top-up recommendations.
/// No I/O, no UserDefaults, no SwiftData — fully testable.
enum TopUpRecommendationEngine {

    /// Calculate a top-up recommendation from funding planner results.
    /// - Parameters:
    ///   - plannerResult: Output from FundingPlannerEngine.calculate()
    ///   - cashReserve: Current effective cash reserve (after one-time purchases)
    ///   - bufferMode: How to calculate the safety buffer
    ///   - bufferValue: The buffer amount (dollars for .fixed, percentage for .percent)
    ///   - leadDays: Days before depletion to recommend top-up (default 2)
    ///   - now: Current date for urgency calculation
    /// - Returns: A TopUpRecommendation with amount, date, urgency, and reason
    static func calculate(
        plannerResult: FundingPlannerResult,
        cashReserve: Double,
        bufferMode: TopUpBufferMode,
        bufferValue: Double,
        leadDays: Int = 2,
        now: Date
    ) -> TopUpRecommendation {
        let shortfall = plannerResult.shortfall

        // No shortfall — everything is covered
        guard shortfall > 0 else {
            return TopUpRecommendation(
                recommendedAmount: 0,
                recommendedDate: nil,
                urgency: .none,
                reason: "Your reserve covers the next 30 days."
            )
        }

        // Calculate buffer
        let buffer: Double
        switch bufferMode {
        case .fixed:
            buffer = max(0, bufferValue)
        case .percent:
            buffer = max(0, plannerResult.requiredNext30Days * (bufferValue / 100))
        }

        let recommendedAmount = shortfall + buffer

        // Calculate recommended date
        let recommendedDate: Date?
        if let depletion = plannerResult.depletionDate {
            let calendar = Calendar.current
            let leadDate = calendar.date(byAdding: .day, value: -leadDays, to: depletion)!
            // Don't recommend a date in the past — use today at minimum
            recommendedDate = max(calendar.startOfDay(for: now), calendar.startOfDay(for: leadDate))
        } else if let firstCharge = plannerResult.projectedCharges.first {
            // No depletion date but there's a shortfall — use the first charge as reference
            let calendar = Calendar.current
            let leadDate = calendar.date(byAdding: .day, value: -leadDays, to: firstCharge.date)!
            recommendedDate = max(calendar.startOfDay(for: now), calendar.startOfDay(for: leadDate))
        } else {
            recommendedDate = nil
        }

        // Calculate urgency based on days until recommended date
        let urgency: TopUpUrgency
        if let date = recommendedDate {
            let daysUntil = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: now),
                to: Calendar.current.startOfDay(for: date)
            ).day ?? 0

            if daysUntil <= 3 {
                urgency = .high
            } else if daysUntil <= 7 {
                urgency = .medium
            } else {
                urgency = .low
            }
        } else {
            // Has shortfall but no clear date — medium urgency
            urgency = .medium
        }

        // Build reason string
        let reason: String
        if let depletion = plannerResult.depletionDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            reason = "Reserve runs out \(formatter.string(from: depletion)). Top up to cover the next 30 days."
        } else {
            reason = "Projected spending exceeds your reserve by the shortfall amount."
        }

        return TopUpRecommendation(
            recommendedAmount: recommendedAmount,
            recommendedDate: recommendedDate,
            urgency: urgency,
            reason: reason
        )
    }
}
