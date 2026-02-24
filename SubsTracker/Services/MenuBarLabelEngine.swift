import Foundation

/// Pure formatting engine for menu bar labels. No state, fully testable.
enum MenuBarLabelEngine {

    /// Format the compact menu bar title label.
    /// When disabled: returns empty string (system will show icon only).
    /// When enabled: "C 45% | O $12" or "C — | O —" for missing data.
    static func formatLabel(
        claudeUtilization: Double?,
        claudeExtraDollars: Double?,
        openAICost: Double?,
        codexUtilization: Double?,
        currencyCode: String,
        isEnabled: Bool
    ) -> String {
        guard isEnabled else { return "" }

        let claudePart = formatClaudePart(
            utilization: claudeUtilization,
            extraDollars: claudeExtraDollars,
            currencyCode: currencyCode
        )
        let openAIPart = formatOpenAIPart(
            cost: openAICost,
            codexUtilization: codexUtilization,
            currencyCode: currencyCode
        )

        return "\(claudePart) | \(openAIPart)"
    }

    /// Format Claude part: "C 45%" or "C 45% $2.50" (with extra usage) or "C —"
    static func formatClaudePart(
        utilization: Double?,
        extraDollars: Double?,
        currencyCode: String
    ) -> String {
        guard let util = utilization else { return "C —" }
        let pct = Int(round(util))  // utilization is already 0-100
        var result = "C \(pct)%"
        if let extra = extraDollars, extra > 0 {
            result += " \(CurrencyFormatter.format(extra, code: currencyCode))"
        }
        return result
    }

    /// Format OpenAI part: "O $12" or "O 30%" (Codex utilization) or "O —"
    static func formatOpenAIPart(
        cost: Double?,
        codexUtilization: Double?,
        currencyCode: String
    ) -> String {
        // Prefer dollar cost if available
        if let cost, cost > 0 {
            return "O \(CurrencyFormatter.format(cost, code: currencyCode))"
        }
        // Fall back to Codex utilization if available
        if let util = codexUtilization {
            let pct = Int(round(util))  // utilization is already 0-100
            return "O \(pct)%"
        }
        return "O —"
    }

    /// Format dropdown detail line for Claude.
    static func claudeDetailLine(
        utilization: Double?,
        extraDollars: Double?,
        currencyCode: String
    ) -> String {
        guard let util = utilization else { return "Claude: No data" }
        let pct = Int(round(util))  // utilization is already 0-100
        var line = "Claude: \(pct)% session"
        if let extra = extraDollars, extra > 0 {
            line += " · \(CurrencyFormatter.format(extra, code: currencyCode)) extra"
        }
        return line
    }

    /// Format dropdown detail line for OpenAI/Codex.
    static func openAIDetailLine(
        cost: Double?,
        codexUtilization: Double?,
        currencyCode: String
    ) -> String {
        var parts: [String] = []
        if let cost, cost > 0 {
            parts.append("API \(CurrencyFormatter.format(cost, code: currencyCode))")
        }
        if let util = codexUtilization {
            let pct = Int(round(util))  // utilization is already 0-100
            parts.append("Codex \(pct)%")
        }
        if parts.isEmpty { return "OpenAI: No data" }
        return "OpenAI: \(parts.joined(separator: " · "))"
    }
}
