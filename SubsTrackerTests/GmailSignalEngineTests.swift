import XCTest

// MARK: - Name Normalization Tests

final class NameNormalizationTests: XCTestCase {

    func testNormalize_StripsIncSuffix() {
        XCTAssertEqual(GmailSignalEngine.normalizeName("Vercel Inc."), "vercel")
    }

    func testNormalize_StripsCommaSeparatedSuffix() {
        XCTAssertEqual(GmailSignalEngine.normalizeName("Anthropic, PBC"), "anthropic")
    }

    func testNormalize_StripsLLC() {
        XCTAssertEqual(GmailSignalEngine.normalizeName("Acme LLC"), "acme")
    }

    func testNormalize_StripsLtd() {
        XCTAssertEqual(GmailSignalEngine.normalizeName("Spotify Ltd"), "spotify")
    }

    func testNormalize_StripsPunctuation() {
        XCTAssertEqual(GmailSignalEngine.normalizeName("Open-AI"), "openai")
    }

    func testNormalize_LowercasesAndTrims() {
        XCTAssertEqual(GmailSignalEngine.normalizeName("  Netflix  "), "netflix")
    }

    func testNormalize_CollapsesSpaces() {
        XCTAssertEqual(GmailSignalEngine.normalizeName("Linear  App"), "linear app")
    }

    func testNamesMatch_ExactAfterNormalization() {
        XCTAssertTrue(GmailSignalEngine.namesMatch("Vercel Inc.", "vercel"))
    }

    func testNamesMatch_ContainsSubstring() {
        XCTAssertTrue(GmailSignalEngine.namesMatch("Anthropic", "Anthropic, PBC"))
    }

    func testNamesMatch_DifferentNames() {
        XCTAssertFalse(GmailSignalEngine.namesMatch("Netflix", "Spotify"))
    }

    func testNamesMatch_EmptyString() {
        XCTAssertFalse(GmailSignalEngine.namesMatch("", "Netflix"))
    }
}

// MARK: - Amount Extraction Tests

final class AmountExtractionTests: XCTestCase {

    func testExtract_DollarSign_FromSubject() {
        let amounts = GmailSignalEngine.extractAmounts(from: "Your receipt for $19.99", source: "subject")
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first?.value, 19.99)
        XCTAssertEqual(amounts.first?.currency, "USD")
        XCTAssertEqual(amounts.first?.source, "subject")
    }

    func testExtract_EuroSign() {
        let amounts = GmailSignalEngine.extractAmounts(from: "Invoice: €49.00", source: "snippet")
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first?.value, 49.0)
        XCTAssertEqual(amounts.first?.currency, "EUR")
    }

    func testExtract_PoundSign() {
        let amounts = GmailSignalEngine.extractAmounts(from: "Payment of £9.99 received", source: "body")
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first?.value, 9.99)
        XCTAssertEqual(amounts.first?.currency, "GBP")
    }

    func testExtract_SuffixPattern_USD() {
        let amounts = GmailSignalEngine.extractAmounts(from: "Charged 200 USD for API usage", source: "subject")
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first?.value, 200)
        XCTAssertEqual(amounts.first?.currency, "USD")
    }

    func testExtract_CommaFormatted() {
        let amounts = GmailSignalEngine.extractAmounts(from: "Payment of $1,299.00", source: "subject")
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first?.value, 1299.0)
    }

    func testExtract_MultipleAmounts() {
        let amounts = GmailSignalEngine.extractAmounts(from: "Subtotal: $10.00, Tax: $1.50, Total: $11.50", source: "snippet")
        XCTAssertTrue(amounts.count >= 2, "Should find multiple amounts")
    }

    func testExtract_EmptyText() {
        let amounts = GmailSignalEngine.extractAmounts(from: "", source: "subject")
        XCTAssertTrue(amounts.isEmpty)
    }

    func testExtract_NoAmounts() {
        let amounts = GmailSignalEngine.extractAmounts(from: "Your subscription has been renewed", source: "subject")
        XCTAssertTrue(amounts.isEmpty)
    }

    func testExtractAll_DeduplicatesAcrossSources() {
        let amounts = GmailSignalEngine.extractAllAmounts(
            subject: "Receipt: $19.99",
            snippet: "You were charged $19.99 for Spotify Premium"
        )
        // Same amount in both — should deduplicate to one, preferring subject source
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first?.source, "subject")
    }

    func testExtractAll_BodyFallback() {
        let amounts = GmailSignalEngine.extractAllAmounts(
            subject: "Your receipt from Vercel",
            snippet: "Thank you for your payment",
            bodyText: "Amount: $20.00"
        )
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first?.value, 20.0)
        XCTAssertEqual(amounts.first?.source, "body")
    }

    func testExtract_RejectsHugeAmounts() {
        let amounts = GmailSignalEngine.extractAmounts(from: "ID: $999999.99", source: "subject")
        XCTAssertTrue(amounts.isEmpty, "Should reject amounts >= 100,000")
    }
}

// MARK: - Billing Signal Score Tests

final class BillingSignalScoreTests: XCTestCase {

    func testScore_ReceiptKeyword() {
        let score = GmailSignalEngine.billingSignalScore(
            subject: "Your receipt from Stripe",
            snippet: ""
        )
        XCTAssertEqual(score, 1.0, "Receipt should score 1.0")
    }

    func testScore_InvoiceKeyword() {
        let score = GmailSignalEngine.billingSignalScore(
            subject: "Invoice #1234",
            snippet: ""
        )
        XCTAssertEqual(score, 1.0)
    }

    func testScore_SubscriptionKeyword() {
        let score = GmailSignalEngine.billingSignalScore(
            subject: "Your subscription has been renewed",
            snippet: ""
        )
        XCTAssertGreaterThanOrEqual(score, 0.7)
    }

    func testScore_NoKeywords() {
        let score = GmailSignalEngine.billingSignalScore(
            subject: "Welcome to our newsletter!",
            snippet: "Check out our latest features"
        )
        XCTAssertEqual(score, 0, "No billing keywords should score 0")
    }

    func testScore_SnippetContainsKeyword() {
        let score = GmailSignalEngine.billingSignalScore(
            subject: "Update from Vercel",
            snippet: "Your payment confirmation for $20.00"
        )
        XCTAssertGreaterThanOrEqual(score, 0.9)
    }
}

// MARK: - Payment Processor Detection Tests

final class ProcessorDetectionTests: XCTestCase {

    func testStripe_WithServiceName() {
        let result = GmailSignalEngine.detectProcessor(
            domain: "stripe.com",
            subject: "Your receipt from Cursor"
        )
        XCTAssertTrue(result.isProcessor)
        XCTAssertEqual(result.processorName, "Stripe")
        XCTAssertEqual(result.serviceName, "Cursor")
    }

    func testPaddle_WithServiceName() {
        let result = GmailSignalEngine.detectProcessor(
            domain: "paddle.com",
            subject: "Invoice for Setapp"
        )
        XCTAssertTrue(result.isProcessor)
        XCTAssertEqual(result.processorName, "Paddle")
        XCTAssertEqual(result.serviceName, "Setapp")
    }

    func testStripe_WithoutServiceName() {
        let result = GmailSignalEngine.detectProcessor(
            domain: "stripe.com",
            subject: "Payment successful"
        )
        XCTAssertTrue(result.isProcessor)
        XCTAssertNil(result.serviceName, "No service name pattern in subject")
    }

    func testNonProcessor_Domain() {
        let result = GmailSignalEngine.detectProcessor(
            domain: "netflix.com",
            subject: "Your receipt"
        )
        XCTAssertFalse(result.isProcessor)
    }

    func testPayPal_WithServiceName() {
        let result = GmailSignalEngine.detectProcessor(
            domain: "paypal.com",
            subject: "Receipt for payment to Figma"
        )
        XCTAssertTrue(result.isProcessor)
        XCTAssertEqual(result.processorName, "PayPal")
        XCTAssertEqual(result.serviceName, "Figma")
    }
}

// MARK: - HTML Stripping Tests

final class HTMLStrippingTests: XCTestCase {

    func testStrip_BasicTags() {
        let result = GmailSignalEngine.stripHTML("<p>Hello <b>World</b></p>")
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
        XCTAssertFalse(result.contains("<p>"))
        XCTAssertFalse(result.contains("<b>"))
    }

    func testStrip_HTMLEntities() {
        let result = GmailSignalEngine.stripHTML("Price: &dollar;19.99 &amp; tax")
        XCTAssertTrue(result.contains("$19.99"))
        XCTAssertTrue(result.contains("& tax"))
    }

    func testStrip_EmptyString() {
        XCTAssertEqual(GmailSignalEngine.stripHTML(""), "")
    }

    func testStrip_PreservesAmounts() {
        let result = GmailSignalEngine.stripHTML("<td>$200.00</td>")
        XCTAssertTrue(result.contains("$200.00"))
    }
}

// MARK: - Body Fetch Decision Tests

final class BodyFetchDecisionTests: XCTestCase {

    func testNeedsBody_HighSignalNoAmount() {
        let needs = GmailSignalEngine.needsBodyFetch(
            emailCount: 5,
            amounts: [],
            billingScore: 0.8
        )
        XCTAssertTrue(needs, "High signal + no amounts should need body fetch")
    }

    func testNeedsBody_HasAmounts() {
        let needs = GmailSignalEngine.needsBodyFetch(
            emailCount: 5,
            amounts: [19.99],
            billingScore: 1.0
        )
        XCTAssertFalse(needs, "Already has amounts — no body fetch needed")
    }

    func testNeedsBody_LowSignalNoAmount() {
        let needs = GmailSignalEngine.needsBodyFetch(
            emailCount: 1,
            amounts: [],
            billingScore: 0.3
        )
        XCTAssertFalse(needs, "Low signal + 1 email — not worth body fetch")
    }

    func testNeedsBody_HighBillingScoreSingleEmail() {
        let needs = GmailSignalEngine.needsBodyFetch(
            emailCount: 1,
            amounts: [],
            billingScore: 0.9
        )
        XCTAssertTrue(needs, "High billing score alone should trigger body fetch")
    }
}

// MARK: - AI Response Parsing Tests

final class AIResponseParsingTests: XCTestCase {

    func testParse_NewSchemaFields() {
        let json: [[String: Any]] = [[
            "service_name": "Vercel",
            "cost": 20.0,
            "billing_cycle": "monthly",
            "category": "Development",
            "confidence": 0.9,
            "cost_source": "subject",
            "is_estimated": false,
            "evidence": "found $20.00 in subject line",
            "renewal_date": "2026-03-15",
            "notes": "Vercel Pro plan"
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates.count, 1)

        let c = candidates[0]
        XCTAssertEqual(c.name, "Vercel")
        XCTAssertEqual(c.cost, 20.0)
        XCTAssertEqual(c.costSource, CostSource.subject)
        XCTAssertFalse(c.isEstimated)
        XCTAssertEqual(c.evidence, "found $20.00 in subject line")
        XCTAssertEqual(c.confidence, 0.9)
    }

    func testParse_EstimatedCost() {
        let json: [[String: Any]] = [[
            "service_name": "Linear",
            "cost": 10.0,
            "billing_cycle": "monthly",
            "category": "Productivity",
            "confidence": 0.55,
            "cost_source": "estimated",
            "is_estimated": true,
            "evidence": "estimated from standard Linear pricing"
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].isEstimated)
        XCTAssertEqual(candidates[0].costSource, CostSource.estimated)
    }

    func testParse_MissingNewFields_DefaultsToEstimated() {
        let json: [[String: Any]] = [[
            "service_name": "OldFormat",
            "cost": 5.0,
            "billing_cycle": "monthly",
            "category": "Other",
            "confidence": 0.7
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].isEstimated, "Missing cost_source should default to estimated")
        XCTAssertEqual(candidates[0].costSource, CostSource.estimated)
    }

    func testParse_EmptyServiceName_Skipped() {
        let json: [[String: Any]] = [[
            "service_name": "",
            "cost": 10.0,
            "billing_cycle": "monthly",
            "category": "Other",
            "confidence": 0.8
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertTrue(candidates.isEmpty, "Empty service name should be skipped")
    }

    func testParse_CostAsInt() {
        let json: [[String: Any]] = [[
            "service_name": "Railway",
            "cost": 5,
            "billing_cycle": "monthly",
            "category": "Development",
            "confidence": 0.8,
            "cost_source": "snippet",
            "is_estimated": false,
            "evidence": "found $5 in snippet"
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates.first?.cost, 5.0, "Int cost should convert to Double")
        XCTAssertEqual(candidates.first?.costSource, CostSource.snippet)
    }
}

// MARK: - CostSource Label Tests

final class CostSourceLabelTests: XCTestCase {

    func testExtractedLabel() {
        var candidate = SubscriptionCandidate(
            name: "Test", cost: 10, billingCycle: .monthly,
            category: .other, confidence: 0.9
        )
        candidate.isEstimated = false
        XCTAssertEqual(candidate.costSourceLabel, "Extracted")
    }

    func testEstimatedLabel() {
        let candidate = SubscriptionCandidate(
            name: "Test", cost: 10, billingCycle: .monthly,
            category: .other, confidence: 0.5
        )
        // Default isEstimated = true
        XCTAssertEqual(candidate.costSourceLabel, "Estimated")
    }
}

// MARK: - QueryDomain Tests

final class QueryDomainTests: XCTestCase {

    func testProcessorSplitGroup_QueryDomainIsProcessorDomain() {
        // For a via: group (processor-split), queryDomain should be the real processor domain,
        // not the extracted service name
        let summary = SenderSummary(
            senderName: "Cursor",
            senderDomain: "cursor",
            queryDomain: "stripe.com",
            emailCount: 3,
            amounts: [20.0],
            latestSubject: "Your receipt from Cursor",
            latestDate: Date(),
            latestSnippet: ""
        )

        XCTAssertEqual(summary.queryDomain, "stripe.com",
                        "Processor-split group should use real processor domain for queries")
        XCTAssertNotEqual(summary.queryDomain, summary.senderDomain,
                          "queryDomain and senderDomain should differ for processor splits")
    }

    func testNonProcessorGroup_QueryDomainEqualsSenderDomain() {
        // For a regular group (not a processor), queryDomain == senderDomain
        let summary = SenderSummary(
            senderName: "Netflix",
            senderDomain: "netflix.com",
            queryDomain: "netflix.com",
            emailCount: 5,
            amounts: [15.99],
            latestSubject: "Your receipt",
            latestDate: Date(),
            latestSnippet: ""
        )

        XCTAssertEqual(summary.queryDomain, "netflix.com")
        XCTAssertEqual(summary.queryDomain, summary.senderDomain,
                       "Non-processor group should have matching queryDomain and senderDomain")
    }
}
