import XCTest

// Helper: use the same formatter as production to get locale-correct strings
private func fmtCurrency(_ amount: Double, code: String = "USD") -> String {
    CurrencyFormatter.format(amount, code: code)
}

// MARK: - Full Label Tests

final class MenuBarLabelFormatTests: XCTestCase {

    func testLabel_Disabled_ReturnsEmpty() {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: 45,
            claudeExtraDollars: nil,
            openAICost: 12.50,
            codexUtilization: nil,
            currencyCode: "USD",
            isEnabled: false
        )
        XCTAssertEqual(label, "")
    }

    func testLabel_Enabled_FullData() {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: 45,
            claudeExtraDollars: nil,
            openAICost: 12.50,
            codexUtilization: nil,
            currencyCode: "USD",
            isEnabled: true
        )
        XCTAssertTrue(label.contains("C 45%"))
        XCTAssertTrue(label.contains("|"))
        XCTAssertTrue(label.contains("O"))
    }

    func testLabel_Enabled_NoData() {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: nil,
            claudeExtraDollars: nil,
            openAICost: nil,
            codexUtilization: nil,
            currencyCode: "USD",
            isEnabled: true
        )
        XCTAssertEqual(label, "C — | O —")
    }

    func testLabel_ClaudeOnly() {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: 80,
            claudeExtraDollars: nil,
            openAICost: nil,
            codexUtilization: nil,
            currencyCode: "USD",
            isEnabled: true
        )
        XCTAssertTrue(label.contains("C 80%"))
        XCTAssertTrue(label.contains("O —"))
    }

    func testLabel_OpenAIOnly() {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: nil,
            claudeExtraDollars: nil,
            openAICost: 5.99,
            codexUtilization: nil,
            currencyCode: "USD",
            isEnabled: true
        )
        XCTAssertTrue(label.contains("C —"))
        XCTAssertTrue(label.contains("O"))
        XCTAssertTrue(label.contains(fmtCurrency(5.99)))
    }

    func testLabel_WithExtraUsage() {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: 60,
            claudeExtraDollars: 2.50,
            openAICost: nil,
            codexUtilization: nil,
            currencyCode: "USD",
            isEnabled: true
        )
        XCTAssertTrue(label.contains("C 60%"))
        XCTAssertTrue(label.contains(fmtCurrency(2.50)))
    }

    func testLabel_CodexFallback() {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: nil,
            claudeExtraDollars: nil,
            openAICost: nil,
            codexUtilization: 30,
            currencyCode: "USD",
            isEnabled: true
        )
        XCTAssertTrue(label.contains("O 30%"))
    }
}

// MARK: - Claude Part Tests

final class MenuBarClaudePartTests: XCTestCase {

    func testClaude_NoData() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: nil, extraDollars: nil, currencyCode: "USD"
        )
        XCTAssertEqual(part, "C —")
    }

    func testClaude_ZeroPercent() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: 0, extraDollars: nil, currencyCode: "USD"
        )
        XCTAssertEqual(part, "C 0%")
    }

    func testClaude_HundredPercent() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: 100, extraDollars: nil, currencyCode: "USD"
        )
        XCTAssertEqual(part, "C 100%")
    }

    func testClaude_WithExtraDollars() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: 50, extraDollars: 3.25, currencyCode: "USD"
        )
        XCTAssertTrue(part.hasPrefix("C 50%"))
        XCTAssertTrue(part.contains(fmtCurrency(3.25)))
    }

    func testClaude_ExtraDollarsZero_NotShown() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: 50, extraDollars: 0, currencyCode: "USD"
        )
        XCTAssertEqual(part, "C 50%")
    }

    func testClaude_ExtraDollarsNil_NotShown() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: 75, extraDollars: nil, currencyCode: "USD"
        )
        XCTAssertEqual(part, "C 75%")
    }

    func testClaude_RoundsUtilization() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: 45.6, extraDollars: nil, currencyCode: "USD"
        )
        XCTAssertEqual(part, "C 46%")
    }

    func testClaude_EuroCurrency() {
        let part = MenuBarLabelEngine.formatClaudePart(
            utilization: 50, extraDollars: 5.00, currencyCode: "EUR"
        )
        XCTAssertTrue(part.hasPrefix("C 50%"))
        XCTAssertTrue(part.contains(fmtCurrency(5.00, code: "EUR")))
    }
}

// MARK: - OpenAI Part Tests

final class MenuBarOpenAIPartTests: XCTestCase {

    func testOpenAI_NoData() {
        let part = MenuBarLabelEngine.formatOpenAIPart(
            cost: nil, codexUtilization: nil, currencyCode: "USD"
        )
        XCTAssertEqual(part, "O —")
    }

    func testOpenAI_WithCost() {
        let part = MenuBarLabelEngine.formatOpenAIPart(
            cost: 12.50, codexUtilization: nil, currencyCode: "USD"
        )
        XCTAssertTrue(part.hasPrefix("O"))
        XCTAssertTrue(part.contains(fmtCurrency(12.50)))
    }

    func testOpenAI_CostZero_FallsToCodex() {
        let part = MenuBarLabelEngine.formatOpenAIPart(
            cost: 0, codexUtilization: 40, currencyCode: "USD"
        )
        XCTAssertEqual(part, "O 40%")
    }

    func testOpenAI_CostNil_FallsToCodex() {
        let part = MenuBarLabelEngine.formatOpenAIPart(
            cost: nil, codexUtilization: 65, currencyCode: "USD"
        )
        XCTAssertEqual(part, "O 65%")
    }

    func testOpenAI_CostPreferredOverCodex() {
        let part = MenuBarLabelEngine.formatOpenAIPart(
            cost: 8.00, codexUtilization: 50, currencyCode: "USD"
        )
        XCTAssertTrue(part.contains(fmtCurrency(8.00)))
        XCTAssertFalse(part.contains("50%"))
    }

    func testOpenAI_HighCostFormatting() {
        let part = MenuBarLabelEngine.formatOpenAIPart(
            cost: 150.0, codexUtilization: nil, currencyCode: "USD"
        )
        XCTAssertTrue(part.contains(fmtCurrency(150.0)))
    }

    func testOpenAI_TinyCostFormatting() {
        let part = MenuBarLabelEngine.formatOpenAIPart(
            cost: 0.005, codexUtilization: nil, currencyCode: "USD"
        )
        XCTAssertTrue(part.hasPrefix("O"))
        XCTAssertTrue(part.contains(fmtCurrency(0.005)))
    }
}

// MARK: - Detail Line Tests

final class MenuBarDetailLineTests: XCTestCase {

    func testClaudeDetail_NoData() {
        let line = MenuBarLabelEngine.claudeDetailLine(
            utilization: nil, extraDollars: nil, currencyCode: "USD"
        )
        XCTAssertEqual(line, "Claude: No data")
    }

    func testClaudeDetail_WithUtilization() {
        let line = MenuBarLabelEngine.claudeDetailLine(
            utilization: 72, extraDollars: nil, currencyCode: "USD"
        )
        XCTAssertEqual(line, "Claude: 72% session")
    }

    func testClaudeDetail_WithExtraUsage() {
        let line = MenuBarLabelEngine.claudeDetailLine(
            utilization: 50, extraDollars: 4.20, currencyCode: "USD"
        )
        XCTAssertTrue(line.contains("50% session"))
        XCTAssertTrue(line.contains(fmtCurrency(4.20)))
        XCTAssertTrue(line.contains("extra"))
    }

    func testOpenAIDetail_NoData() {
        let line = MenuBarLabelEngine.openAIDetailLine(
            cost: nil, codexUtilization: nil, currencyCode: "USD"
        )
        XCTAssertEqual(line, "OpenAI: No data")
    }

    func testOpenAIDetail_CostOnly() {
        let line = MenuBarLabelEngine.openAIDetailLine(
            cost: 15.00, codexUtilization: nil, currencyCode: "USD"
        )
        XCTAssertTrue(line.contains("API"))
        XCTAssertTrue(line.contains(fmtCurrency(15.00)))
    }

    func testOpenAIDetail_CodexOnly() {
        let line = MenuBarLabelEngine.openAIDetailLine(
            cost: nil, codexUtilization: 55, currencyCode: "USD"
        )
        XCTAssertEqual(line, "OpenAI: Codex 55%")
    }

    func testOpenAIDetail_Both() {
        let line = MenuBarLabelEngine.openAIDetailLine(
            cost: 10.00, codexUtilization: 40, currencyCode: "USD"
        )
        XCTAssertTrue(line.contains("API"))
        XCTAssertTrue(line.contains("Codex 40%"))
    }
}
