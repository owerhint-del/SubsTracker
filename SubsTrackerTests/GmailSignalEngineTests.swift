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

// MARK: - Charge Type Classification Tests

final class ChargeTypeClassifierTests: XCTestCase {

    // --- Recurring Subscription Signals ---

    func testClassify_SubscriptionKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Your subscription has been renewed",
            snippet: "Thanks for your payment"
        )
        XCTAssertEqual(result.type, .recurringSubscription)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.7)
    }

    func testClassify_RenewalKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Renewal confirmation for Netflix",
            snippet: ""
        )
        XCTAssertEqual(result.type, .recurringSubscription)
    }

    func testClassify_MonthlyChargeKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Monthly charge for Spotify Premium",
            snippet: ""
        )
        XCTAssertEqual(result.type, .recurringSubscription)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.8)
    }

    func testClassify_AnnualChargeKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Annual charge: GitHub Pro",
            snippet: ""
        )
        XCTAssertEqual(result.type, .recurringSubscription)
    }

    func testClassify_AutopayKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Auto-pay successful",
            snippet: "Your autopay for $9.99 was processed"
        )
        XCTAssertEqual(result.type, .recurringSubscription)
    }

    func testClassify_MembershipKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Your membership renewal",
            snippet: ""
        )
        XCTAssertEqual(result.type, .recurringSubscription)
    }

    func testClassify_BillingPeriodKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Billing period: Jan 2026",
            snippet: "Next billing date: Feb 1"
        )
        XCTAssertEqual(result.type, .recurringSubscription)
    }

    func testClassify_MonthlyPlanKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Your monthly plan was renewed",
            snippet: ""
        )
        XCTAssertEqual(result.type, .recurringSubscription)
    }

    // --- Usage Top-up Signals ---

    func testClassify_TopUpKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Top up successful: $50 added",
            snippet: ""
        )
        XCTAssertEqual(result.type, .usageTopup)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.8)
    }

    func testClassify_CreditsKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Credits purchased",
            snippet: "50 credits added to your account"
        )
        XCTAssertEqual(result.type, .usageTopup)
    }

    func testClassify_TokensKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Tokens added to your account",
            snippet: ""
        )
        XCTAssertEqual(result.type, .usageTopup)
    }

    func testClassify_APIUsageKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "API usage charge for February",
            snippet: ""
        )
        XCTAssertEqual(result.type, .usageTopup)
    }

    func testClassify_PayAsYouGoKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Pay-as-you-go billing statement",
            snippet: ""
        )
        XCTAssertEqual(result.type, .usageTopup)
    }

    func testClassify_PrepaidKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Prepaid balance added",
            snippet: "$100 prepaid credit"
        )
        XCTAssertEqual(result.type, .usageTopup)
    }

    // --- Add-on / One-time Signals ---

    func testClassify_AddonKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Add-on purchased: Extra Storage",
            snippet: ""
        )
        XCTAssertEqual(result.type, .addonCredits)
    }

    func testClassify_OneTimeKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "One-time purchase confirmed",
            snippet: ""
        )
        XCTAssertEqual(result.type, .addonCredits)
    }

    func testClassify_LifetimeKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Lifetime access granted",
            snippet: ""
        )
        XCTAssertEqual(result.type, .addonCredits)
    }

    // --- Refund Signals ---

    func testClassify_RefundKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Refund processed for $19.99",
            snippet: ""
        )
        XCTAssertEqual(result.type, .refundOrReversal)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.8)
    }

    func testClassify_ChargebackKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Chargeback notification",
            snippet: ""
        )
        XCTAssertEqual(result.type, .refundOrReversal)
    }

    func testClassify_ReversalKeyword() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Payment reversal completed",
            snippet: ""
        )
        XCTAssertEqual(result.type, .refundOrReversal)
    }

    func testClassify_RefundOverridesRecurring() {
        // Refund should win even if subscription keyword also present
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Subscription refund processed",
            snippet: "Your subscription refund of $9.99 has been applied"
        )
        XCTAssertEqual(result.type, .refundOrReversal, "Refund should override recurring signals")
    }

    // --- Anti-signals ---

    func testClassify_MarketingAntiSignal() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Free trial welcome promotion",
            snippet: "Start your trial today with this special promo"
        )
        XCTAssertEqual(result.type, .unknown, "Marketing anti-signals should prevent classification")
    }

    func testClassify_ShippingAntiSignal() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Order shipped — tracking info inside",
            snippet: "Your delivery is on the way"
        )
        XCTAssertEqual(result.type, .unknown, "Shipping anti-signals should prevent classification")
    }

    // --- Unknown / No Signal ---

    func testClassify_NoSignals() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Hello from the team",
            snippet: "Just wanted to say hi"
        )
        XCTAssertEqual(result.type, .unknown)
        XCTAssertEqual(result.confidence, 0)
    }

    func testClassify_WeakSignalBelowThreshold() {
        let result = GmailSignalEngine.classifyChargeType(
            subject: "Account balance update",
            snippet: ""
        )
        // "balance" has 0.5 weight — below threshold of 0.4 should still classify
        // but very weak signals should be uncertain
        XCTAssertTrue(result.confidence <= 0.6 || result.type == .unknown)
    }

    // --- Validation ---

    func testValidate_AIAndLocalAgree() {
        let result = GmailSignalEngine.validateChargeType(
            aiType: .recurringSubscription,
            subject: "Your subscription renewal",
            snippet: "Monthly charge processed"
        )
        XCTAssertEqual(result.type, .recurringSubscription)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.8, "Agreement should boost confidence")
    }

    func testValidate_AIAndLocalDisagree() {
        let result = GmailSignalEngine.validateChargeType(
            aiType: .recurringSubscription,
            subject: "Top up credits added",
            snippet: "API usage prepaid balance"
        )
        // AI says recurring, local says top-up — trust AI but lower confidence
        XCTAssertEqual(result.type, .recurringSubscription)
        XCTAssertEqual(result.confidence, 0.5, "Disagreement should lower confidence")
    }

    func testValidate_LocalRefundOverridesAI() {
        let result = GmailSignalEngine.validateChargeType(
            aiType: .recurringSubscription,
            subject: "Refund for your subscription",
            snippet: "Refund of $19.99 has been processed"
        )
        XCTAssertEqual(result.type, .refundOrReversal, "Local refund detection should override AI")
    }

    func testValidate_LocalUnknown_TrustsAI() {
        let result = GmailSignalEngine.validateChargeType(
            aiType: .usageTopup,
            subject: "Payment received",
            snippet: "Thank you"
        )
        XCTAssertEqual(result.type, .usageTopup, "When local has no opinion, trust AI")
        XCTAssertEqual(result.confidence, 0.7)
    }
}

// MARK: - Charge Type Enum Tests

final class ChargeTypeEnumTests: XCTestCase {

    func testIsRecurring() {
        XCTAssertTrue(ChargeType.recurringSubscription.isRecurring)
        XCTAssertFalse(ChargeType.usageTopup.isRecurring)
        XCTAssertFalse(ChargeType.unknown.isRecurring)
    }

    func testIsNonRecurring() {
        XCTAssertTrue(ChargeType.usageTopup.isNonRecurring)
        XCTAssertTrue(ChargeType.addonCredits.isNonRecurring)
        XCTAssertTrue(ChargeType.oneTimePurchase.isNonRecurring)
        XCTAssertFalse(ChargeType.recurringSubscription.isNonRecurring)
        XCTAssertFalse(ChargeType.refundOrReversal.isNonRecurring)
        XCTAssertFalse(ChargeType.unknown.isNonRecurring)
    }

    func testDisplayName() {
        XCTAssertEqual(ChargeType.recurringSubscription.displayName, "Subscription")
        XCTAssertEqual(ChargeType.usageTopup.displayName, "API Top-up")
        XCTAssertEqual(ChargeType.refundOrReversal.displayName, "Refund")
    }

    func testRawValueRoundtrip() {
        for type in ChargeType.allCases {
            XCTAssertEqual(ChargeType(rawValue: type.rawValue), type)
        }
    }
}

// MARK: - Query Builder Tests

final class QueryBuilderTests: XCTestCase {

    func testBuildQueries_ContainsTimeFilter() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 12)
        for query in queries {
            XCTAssertTrue(query.contains("newer_than:12m"), "Query should contain time filter: \(query)")
        }
    }

    func testBuildQueries_DifferentLookback() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 6)
        for query in queries {
            XCTAssertTrue(query.contains("newer_than:6m"), "Query should use 6m lookback: \(query)")
        }
    }

    func testBuildQueries_CoversBillingKeywords() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 12)
        let combined = queries.joined(separator: " ")
        XCTAssertTrue(combined.contains("receipt"), "Should search for receipts")
        XCTAssertTrue(combined.contains("invoice"), "Should search for invoices")
        XCTAssertTrue(combined.contains("subscription"), "Should search for subscriptions")
        XCTAssertTrue(combined.contains("renewal"), "Should search for renewals")
    }

    func testBuildQueries_CoversTopUpKeywords() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 12)
        let combined = queries.joined(separator: " ")
        XCTAssertTrue(combined.contains("top up"), "Should search for top-ups")
        XCTAssertTrue(combined.contains("credits"), "Should search for credits")
    }

    func testBuildQueries_CoversRefundKeywords() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 12)
        let combined = queries.joined(separator: " ")
        XCTAssertTrue(combined.contains("refund"), "Should search for refunds")
    }

    func testBuildQueries_ReturnsMultipleQueries() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 12)
        XCTAssertGreaterThanOrEqual(queries.count, 3, "Should generate multiple queries for coverage")
    }
}

// MARK: - AI Response Parsing with ChargeType Tests

final class AIResponseChargeTypeParsingTests: XCTestCase {

    func testParse_RecurringSubscription() {
        let json: [[String: Any]] = [[
            "service_name": "Netflix",
            "cost": 15.99,
            "billing_cycle": "monthly",
            "category": "Streaming",
            "charge_type": "recurring_subscription",
            "confidence": 0.95,
            "cost_source": "subject",
            "is_estimated": false,
            "evidence": "found $15.99 in subject"
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].chargeType, .recurringSubscription)
    }

    func testParse_UsageTopup() {
        let json: [[String: Any]] = [[
            "service_name": "OpenAI",
            "cost": 50.0,
            "billing_cycle": "monthly",
            "category": "AI Services",
            "charge_type": "usage_topup",
            "confidence": 0.8,
            "cost_source": "snippet",
            "is_estimated": false,
            "evidence": "found $50 in snippet"
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates[0].chargeType, .usageTopup)
    }

    func testParse_Refund() {
        let json: [[String: Any]] = [[
            "service_name": "Spotify",
            "cost": 9.99,
            "billing_cycle": "monthly",
            "category": "Streaming",
            "charge_type": "refund_or_reversal",
            "confidence": 0.9,
            "cost_source": "subject",
            "is_estimated": false,
            "evidence": "refund processed"
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates[0].chargeType, .refundOrReversal)
    }

    func testParse_MissingChargeType_DefaultsToUnknown() {
        let json: [[String: Any]] = [[
            "service_name": "SomeService",
            "cost": 10.0,
            "billing_cycle": "monthly",
            "category": "Other",
            "confidence": 0.7
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates[0].chargeType, .unknown)
    }

    func testParse_InvalidChargeType_DefaultsToUnknown() {
        let json: [[String: Any]] = [[
            "service_name": "SomeService",
            "cost": 10.0,
            "billing_cycle": "monthly",
            "category": "Other",
            "charge_type": "invalid_type",
            "confidence": 0.7
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates[0].chargeType, .unknown)
    }
}

// MARK: - Cancellation Signal Detection Tests

final class CancellationSignalTests: XCTestCase {

    func testExplicitCancellation_HighScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Your subscription has been canceled",
            snippet: "We're sorry to see you go"
        )
        XCTAssertGreaterThanOrEqual(score, 0.95, "Explicit cancellation should score >= 0.95")
    }

    func testCancellationConfirmed_HighScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Cancellation confirmed",
            snippet: "Your Netflix membership has been canceled"
        )
        XCTAssertGreaterThanOrEqual(score, 0.95)
    }

    func testCancelAnytime_ZeroScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Welcome to Spotify Premium",
            snippet: "You can cancel anytime from your account settings"
        )
        XCTAssertEqual(score, 0, "'cancel anytime' is a false positive and should score 0")
    }

    func testRegularBillingEmail_ZeroScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Your receipt from Vercel",
            snippet: "Thank you for your payment of $20.00"
        )
        XCTAssertEqual(score, 0, "Regular billing email should score 0")
    }

    func testAccountClosed_HighScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Account closed",
            snippet: "Your account has been successfully closed"
        )
        XCTAssertGreaterThanOrEqual(score, 0.85, "Account closed should score >= 0.85")
    }

    func testMembershipCanceled_HighScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Membership canceled",
            snippet: "Your gym membership has been canceled effective today"
        )
        XCTAssertGreaterThanOrEqual(score, 0.90)
    }
}

// MARK: - Lifecycle Resolution Tests

final class LifecycleResolutionTests: XCTestCase {

    func testChargeThenCancel_ResultsCanceled() {
        let emails: [(date: Date, subject: String, snippet: String, bodyExcerpt: String?)] = [
            (Date(timeIntervalSinceNow: -60*86400), "Your receipt from Netflix", "Payment of $15.99", nil),
            (Date(timeIntervalSinceNow: -30*86400), "Subscription canceled", "Your Netflix subscription has been canceled", nil)
        ]

        let result = GmailSignalEngine.resolveLifecycle(
            emails: emails,
            aiStatus: .active,
            aiStatusDate: nil
        )
        XCTAssertEqual(result.status, .canceled, "Cancel after charge should result in canceled")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85)
    }

    func testCancelThenCharge_ResultsActive() {
        let emails: [(date: Date, subject: String, snippet: String, bodyExcerpt: String?)] = [
            (Date(timeIntervalSinceNow: -60*86400), "Subscription canceled", "Your subscription has been canceled", nil),
            (Date(timeIntervalSinceNow: -10*86400), "Your receipt from Netflix", "Payment of $15.99 received", nil)
        ]

        let result = GmailSignalEngine.resolveLifecycle(
            emails: emails,
            aiStatus: .canceled,
            aiStatusDate: nil
        )
        XCTAssertEqual(result.status, .active, "Charge after cancel should mean reactivated")
    }

    func testCancelAnytimeInTimeline_StaysActive() {
        let emails: [(date: Date, subject: String, snippet: String, bodyExcerpt: String?)] = [
            (Date(timeIntervalSinceNow: -30*86400), "Your receipt from Spotify", "Payment of $9.99. Cancel anytime from settings.", nil),
            (Date(timeIntervalSinceNow: -5*86400), "Your receipt from Spotify", "Payment of $9.99 received", nil)
        ]

        let result = GmailSignalEngine.resolveLifecycle(
            emails: emails,
            aiStatus: .active,
            aiStatusDate: nil
        )
        XCTAssertEqual(result.status, .active, "'cancel anytime' should not trigger cancellation")
    }

    func testEmptyTimeline_DefersToAI() {
        let result = GmailSignalEngine.resolveLifecycle(
            emails: [],
            aiStatus: .canceled,
            aiStatusDate: Date()
        )
        XCTAssertEqual(result.status, .canceled, "Empty timeline should defer to AI status")
        XCTAssertEqual(result.confidence, 0.5, "Empty timeline confidence should be low")
    }
}

// MARK: - Parsed Status Field Tests

final class ParsedStatusFieldTests: XCTestCase {

    func testParse_CanceledStatus() {
        let json: [[String: Any]] = [[
            "service_name": "Netflix",
            "cost": 15.99,
            "billing_cycle": "monthly",
            "category": "Streaming",
            "charge_type": "recurring_subscription",
            "subscription_status": "canceled",
            "status_effective_date": "2026-02-10",
            "confidence": 0.9
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].subscriptionStatus, .canceled)
        XCTAssertNotNil(candidates[0].statusEffectiveDate)
    }

    func testParse_ActiveStatus() {
        let json: [[String: Any]] = [[
            "service_name": "Spotify",
            "cost": 9.99,
            "billing_cycle": "monthly",
            "category": "Streaming",
            "charge_type": "recurring_subscription",
            "subscription_status": "active",
            "confidence": 0.95
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates[0].subscriptionStatus, .active)
    }

    func testParse_MissingStatus_DefaultsToActive() {
        let json: [[String: Any]] = [[
            "service_name": "Vercel",
            "cost": 20.0,
            "billing_cycle": "monthly",
            "category": "Development",
            "confidence": 0.8
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates[0].subscriptionStatus, .active, "Missing status should default to active")
    }

    func testParse_InvalidStatus_DefaultsToActive() {
        let json: [[String: Any]] = [[
            "service_name": "TestService",
            "cost": 10.0,
            "billing_cycle": "monthly",
            "category": "Other",
            "subscription_status": "invalid_status",
            "confidence": 0.7
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertEqual(candidates[0].subscriptionStatus, .active, "Invalid status should default to active")
    }

    func testParse_StatusEffectiveDate() {
        let json: [[String: Any]] = [[
            "service_name": "GitHub",
            "cost": 4.0,
            "billing_cycle": "monthly",
            "category": "Development",
            "subscription_status": "canceled",
            "status_effective_date": "2026-01-15",
            "confidence": 0.85
        ]]

        let candidates = GmailSignalEngine.parseCandidatesFromJSON(json)
        XCTAssertNotNil(candidates[0].statusEffectiveDate, "Should parse status_effective_date")

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: candidates[0].statusEffectiveDate!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
    }
}

// MARK: - Query Builder Cancellation Tests

final class QueryBuilderCancellationTests: XCTestCase {

    func testBuildQueries_ContainsCancellationKeywords() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 12)
        let combined = queries.joined(separator: " ")
        XCTAssertTrue(combined.contains("cancel"), "Should search for cancellation emails")
        XCTAssertTrue(combined.contains("unsubscribe"), "Should search for unsubscribe emails")
    }

    func testBuildQueries_HasSixQueries() {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: 12)
        XCTAssertEqual(queries.count, 6, "Should now have 6 queries including cancellation")
    }
}

// MARK: - Dedup Lifecycle Passthrough Tests

final class DedupLifecycleTests: XCTestCase {

    /// Canceled candidate matching an existing name should NOT be dropped by dedup.
    func testDedup_CanceledCandidatePassesThroughExistingFilter() {
        // Create a canceled candidate that matches an existing subscription name
        var canceledCandidate = SubscriptionCandidate(
            name: "Netflix",
            cost: 15.99,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.95
        )
        canceledCandidate.chargeType = .recurringSubscription
        canceledCandidate.subscriptionStatus = .canceled

        // Also create an active candidate for a different service (control)
        var activeExisting = SubscriptionCandidate(
            name: "Spotify",
            cost: 9.99,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.9
        )
        activeExisting.chargeType = .recurringSubscription
        activeExisting.subscriptionStatus = .active

        // Active candidate for a new service (should pass through)
        var activeNew = SubscriptionCandidate(
            name: "HBO Max",
            cost: 15.99,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.85
        )
        activeNew.chargeType = .recurringSubscription
        activeNew.subscriptionStatus = .active

        let candidates = [canceledCandidate, activeExisting, activeNew]

        // Netflix and Spotify are "existing" — active Spotify should be dropped, canceled Netflix should pass through
        let result = GmailSignalEngine.testDeduplicateCandidates(candidates, existingNames: ["Netflix", "Spotify"])

        let resultNames = result.map(\.name)
        XCTAssertTrue(resultNames.contains("Netflix"), "Canceled candidate should pass through dedup even when matching existing name")
        XCTAssertFalse(resultNames.contains("Spotify"), "Active duplicate of existing name should be dropped")
        XCTAssertTrue(resultNames.contains("HBO Max"), "New active candidate should pass through")
    }

    /// Active candidate for an existing name should still be dropped (no lifecycle change).
    /// Canceled candidate with cost == 0 should survive the pipeline cost filter.
    /// This tests that the dedup output retains zero-cost canceled candidates.
    func testDedup_CanceledCandidateWithZeroCost_SurvivesCostFilter() {
        var canceledCandidate = SubscriptionCandidate(
            name: "Netflix",
            cost: 0,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.95
        )
        canceledCandidate.chargeType = .recurringSubscription
        canceledCandidate.subscriptionStatus = .canceled

        var activeCandidate = SubscriptionCandidate(
            name: "Spotify",
            cost: 9.99,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.9
        )
        activeCandidate.chargeType = .recurringSubscription
        activeCandidate.subscriptionStatus = .active

        let candidates = [canceledCandidate, activeCandidate]
        let deduped = GmailSignalEngine.testDeduplicateCandidates(candidates, existingNames: [])

        // Apply the same filter the pipeline uses: cost > 0 || subscriptionStatus != .active
        let filtered = deduped.filter { $0.cost > 0 || $0.subscriptionStatus != .active }

        XCTAssertTrue(filtered.contains(where: { $0.name == "Netflix" }),
                       "Canceled candidate with $0 cost should survive the cost filter")
        XCTAssertTrue(filtered.contains(where: { $0.name == "Spotify" }),
                       "Active candidate with cost > 0 should also survive")
    }

    /// Active candidate with cost == 0 should still be filtered out.
    func testDedup_ActiveCandidateWithZeroCost_FilteredOut() {
        var activeZeroCost = SubscriptionCandidate(
            name: "FreeService",
            cost: 0,
            billingCycle: .monthly,
            category: .other,
            confidence: 0.5
        )
        activeZeroCost.chargeType = .recurringSubscription
        activeZeroCost.subscriptionStatus = .active

        let deduped = GmailSignalEngine.testDeduplicateCandidates([activeZeroCost], existingNames: [])
        let filtered = deduped.filter { $0.cost > 0 || $0.subscriptionStatus != .active }

        XCTAssertTrue(filtered.isEmpty, "Active candidate with $0 cost should be filtered out")
    }

    // MARK: - Effective Lifecycle Confidence Tests

    /// Low AI confidence + high lifecycle confidence → effective confidence is high → cancel threshold passes.
    func testEffectiveConfidence_LowAI_HighLifecycle_CancelApplied() {
        var candidate = SubscriptionCandidate(
            name: "Netflix",
            cost: 15.99,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.55 // low AI confidence
        )
        candidate.subscriptionStatus = .canceled
        candidate.lifecycleConfidence = 0.95 // high deterministic confidence

        XCTAssertEqual(candidate.effectiveLifecycleConfidence, 0.95,
                       "Should use lifecycleConfidence when available")
        XCTAssertTrue(candidate.effectiveLifecycleConfidence >= 0.85,
                      "Cancel threshold should pass with high lifecycle confidence despite low AI confidence")
    }

    /// Low AI confidence + high lifecycle confidence → reactivation threshold passes.
    func testEffectiveConfidence_LowAI_HighLifecycle_ReactivationApplied() {
        var candidate = SubscriptionCandidate(
            name: "Spotify",
            cost: 9.99,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.60 // low AI confidence
        )
        candidate.subscriptionStatus = .active
        candidate.lifecycleConfidence = 0.92 // high deterministic confidence

        XCTAssertEqual(candidate.effectiveLifecycleConfidence, 0.92)
        XCTAssertTrue(candidate.effectiveLifecycleConfidence >= 0.85,
                      "Reactivation threshold should pass with high lifecycle confidence")
    }

    /// Both AI and lifecycle confidence low → threshold should NOT pass.
    func testEffectiveConfidence_BothLow_NoChange() {
        var candidate = SubscriptionCandidate(
            name: "GitHub",
            cost: 4.0,
            billingCycle: .monthly,
            category: .development,
            confidence: 0.50
        )
        candidate.subscriptionStatus = .canceled
        candidate.lifecycleConfidence = 0.60 // low deterministic confidence too

        XCTAssertEqual(candidate.effectiveLifecycleConfidence, 0.60)
        XCTAssertFalse(candidate.effectiveLifecycleConfidence >= 0.85,
                       "Both low → threshold should NOT pass, status should NOT change")
    }

    /// Nil lifecycle confidence → falls back to AI confidence (regression check).
    func testEffectiveConfidence_NilLifecycle_FallsBackToAI() {
        let candidate = SubscriptionCandidate(
            name: "Vercel",
            cost: 20.0,
            billingCycle: .monthly,
            category: .development,
            confidence: 0.90
        )
        // lifecycleConfidence is nil by default

        XCTAssertNil(candidate.lifecycleConfidence)
        XCTAssertEqual(candidate.effectiveLifecycleConfidence, 0.90,
                       "Should fall back to AI confidence when lifecycleConfidence is nil")
        XCTAssertTrue(candidate.effectiveLifecycleConfidence >= 0.85,
                      "High AI confidence should still pass the threshold as before")
    }

    func testDedup_ActiveDuplicateStillDropped() {
        var activeCandidate = SubscriptionCandidate(
            name: "Netflix",
            cost: 15.99,
            billingCycle: .monthly,
            category: .streaming,
            confidence: 0.9
        )
        activeCandidate.chargeType = .recurringSubscription
        activeCandidate.subscriptionStatus = .active

        let result = GmailSignalEngine.testDeduplicateCandidates([activeCandidate], existingNames: ["Netflix"])
        XCTAssertTrue(result.isEmpty, "Active recurring duplicate of existing sub should be dropped")
    }
}

// MARK: - Body-Aware Cancellation Detection Tests

final class BodyCancellationTests: XCTestCase {

    /// Body-only cancellation phrase should produce a high score.
    func testBodyOnlyCancellation_HighScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Update from Netflix",
            snippet: "Your account details",
            bodyText: "Your subscription has been canceled effective immediately. We're sorry to see you go."
        )
        XCTAssertGreaterThanOrEqual(score, 0.95,
            "Body-only cancellation phrase should score >= 0.95")
    }

    /// Body-only false positive ("cancel anytime") should score 0.
    func testBodyOnlyFalsePositive_ZeroScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Welcome to Spotify Premium",
            snippet: "Enjoy your music",
            bodyText: "You can cancel anytime from your account settings. No questions asked."
        )
        XCTAssertEqual(score, 0,
            "Body-only 'cancel anytime' false positive should score 0")
    }

    /// Body cancel with subject false positive — false positive overrides.
    func testBodyCancelWithSubjectFalsePositive_ZeroScore() {
        let score = GmailSignalEngine.detectCancellationSignal(
            subject: "Easy to cancel — your subscription details",
            snippet: "",
            bodyText: "Your subscription has been canceled."
        )
        XCTAssertEqual(score, 0,
            "False positive in subject should override body cancellation signal")
    }

    /// resolveLifecycle with body-only cancel signal results in canceled status.
    func testResolveLifecycle_BodyOnlyCancel_ResultsCanceled() {
        let emails: [(date: Date, subject: String, snippet: String, bodyExcerpt: String?)] = [
            (Date(timeIntervalSinceNow: -60*86400), "Your receipt from Hulu", "Payment of $7.99", nil),
            (Date(timeIntervalSinceNow: -10*86400), "Account update from Hulu", "Important changes to your account",
             "We're writing to confirm that your subscription has been canceled. Your access will continue until the end of your billing period.")
        ]

        let result = GmailSignalEngine.resolveLifecycle(
            emails: emails,
            aiStatus: .active,
            aiStatusDate: nil
        )
        XCTAssertEqual(result.status, .canceled,
            "Body-only cancellation signal should result in canceled status")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85)
    }
}

// MARK: - Sender Lifecycle Ranking Tests

final class SenderRankingTests: XCTestCase {

    /// A low-volume sender with high cancellation signal should rank above a high-volume sender with no signal.
    func testRanking_LifecycleSignalBeatsHighVolume() {
        let highVolume = SenderSummary(
            senderName: "Marketing Corp",
            senderDomain: "marketing.com",
            queryDomain: "marketing.com",
            emailCount: 50,
            amounts: [9.99],
            latestSubject: "Your monthly newsletter",
            latestDate: Date(),
            latestSnippet: "Check out our latest deals"
        )

        let lowVolumeCanceled = SenderSummary(
            senderName: "Netflix",
            senderDomain: "netflix.com",
            queryDomain: "netflix.com",
            emailCount: 1,
            amounts: [],
            latestSubject: "Your subscription has been canceled",
            latestDate: Date(timeIntervalSinceNow: -86400),
            latestSnippet: "We've canceled your Netflix membership"
        )

        let highVolumeScore = GmailSignalEngine.senderLifecycleScore(for: highVolume)
        let lowVolumeScore = GmailSignalEngine.senderLifecycleScore(for: lowVolumeCanceled)

        XCTAssertEqual(highVolumeScore, 0, "Marketing sender should have 0 lifecycle score")
        XCTAssertGreaterThanOrEqual(lowVolumeScore, 0.80,
            "Cancellation sender should have high lifecycle score")

        // Simulate the ranking sort
        let senders = [highVolume, lowVolumeCanceled]
        let ranked = senders.sorted { a, b in
            let aScore = GmailSignalEngine.senderLifecycleScore(for: a)
            let bScore = GmailSignalEngine.senderLifecycleScore(for: b)
            let aHasSignal = aScore >= 0.80
            let bHasSignal = bScore >= 0.80
            if aHasSignal != bHasSignal { return aHasSignal }
            if aHasSignal && bHasSignal && aScore != bScore { return aScore > bScore }
            if a.emailCount != b.emailCount { return a.emailCount > b.emailCount }
            return a.latestDate > b.latestDate
        }

        XCTAssertEqual(ranked.first?.senderName, "Netflix",
            "Low-volume cancellation sender should rank above high-volume no-signal sender")
    }

    /// Sender with body-only cancellation signal in timeline should get high lifecycle score.
    func testRanking_BodyOnlyCancellationSignalBoostsSender() {
        var sender = SenderSummary(
            senderName: "Hulu",
            senderDomain: "hulu.com",
            queryDomain: "hulu.com",
            emailCount: 2,
            amounts: [7.99],
            latestSubject: "Account update",
            latestDate: Date(),
            latestSnippet: "Important changes"
        )
        sender.recentEmails = [
            EmailSummary(
                date: Date(),
                subject: "Account update",
                snippet: "Important changes",
                bodyExcerpt: "Your subscription has been canceled effective today."
            )
        ]

        let score = GmailSignalEngine.senderLifecycleScore(for: sender)
        XCTAssertGreaterThanOrEqual(score, 0.80,
            "Body-only cancellation signal in timeline should give high lifecycle score")
    }
}

// MARK: - P3 Quality Validation Suite

/// Data-driven validation of lifecycle detection against 40+ realistic email scenarios.
/// Tests the deterministic engine (detectCancellationSignal, resolveLifecycle, classifyChargeType)
/// that was modified in P0–P2. Computes precision/recall/false-positive metrics.
final class LifecycleQualityValidationTests: XCTestCase {

    // MARK: - Scenario Definitions

    struct Scenario {
        let id: Int
        let service: String
        let emails: [(date: Date, subject: String, snippet: String, bodyExcerpt: String?)]
        let expectedStatus: SubscriptionStatus
        let category: String // "active", "canceled", "reactivated", "false_positive", "body_only"
    }

    private func d(_ daysAgo: Int) -> Date { Date(timeIntervalSinceNow: -Double(daysAgo) * 86400) }

    private lazy var scenarios: [Scenario] = [
        // ——— ACTIVE SUBSCRIPTIONS (expectedStatus = .active) ———
        Scenario(id: 1, service: "Netflix", emails: [
            (d(60), "Your receipt from Netflix", "Payment of $15.99 received", nil),
            (d(30), "Your receipt from Netflix", "Payment of $15.99 received", nil),
            (d(1), "Your receipt from Netflix", "Payment of $15.99 received", nil),
        ], expectedStatus: .active, category: "active"),

        Scenario(id: 2, service: "Spotify", emails: [
            (d(30), "Your Spotify Premium receipt", "Payment of $9.99. Cancel anytime from settings.", nil),
            (d(1), "Your Spotify Premium receipt", "Payment of $9.99", nil),
        ], expectedStatus: .active, category: "false_positive"),

        Scenario(id: 3, service: "GitHub", emails: [
            (d(90), "Your GitHub Pro invoice", "Invoice for $4.00 charged to Visa", nil),
            (d(60), "Your GitHub Pro invoice", "Invoice for $4.00", nil),
            (d(30), "Your GitHub Pro invoice", "Invoice for $4.00", nil),
        ], expectedStatus: .active, category: "active"),

        Scenario(id: 4, service: "Vercel", emails: [
            (d(15), "Payment confirmation from Vercel", "Your payment of $20.00 was successful", nil),
        ], expectedStatus: .active, category: "active"),

        Scenario(id: 5, service: "AWS", emails: [
            (d(5), "Your AWS billing statement", "Monthly charge of $47.23", nil),
        ], expectedStatus: .active, category: "active"),

        Scenario(id: 6, service: "Notion", emails: [
            (d(20), "Notion Plus renewal", "Your subscription renewal for $8.00", nil),
        ], expectedStatus: .active, category: "active"),

        Scenario(id: 7, service: "1Password", emails: [
            (d(365), "Annual renewal for 1Password", "Your annual plan of $35.88 has been renewed", nil),
        ], expectedStatus: .active, category: "active"),

        Scenario(id: 8, service: "Figma", emails: [
            (d(14), "Figma billing", "Auto-pay successful for $12.00", nil),
        ], expectedStatus: .active, category: "active"),

        // ——— FALSE POSITIVE: "cancel anytime" and marketing ———
        Scenario(id: 9, service: "Disney+", emails: [
            (d(10), "Welcome to Disney+", "You can cancel anytime from your account. Enjoy watching!", nil),
            (d(3), "Your Disney+ receipt", "Payment of $7.99", nil),
        ], expectedStatus: .active, category: "false_positive"),

        Scenario(id: 10, service: "YouTube Premium", emails: [
            (d(30), "YouTube Premium receipt", "Payment of $13.99", "Thank you for being a member. Easy to cancel from settings at any time. No cancellation fee applies."),
        ], expectedStatus: .active, category: "false_positive"),

        Scenario(id: 11, service: "Dropbox", emails: [
            (d(45), "Dropbox Plus billing", "Monthly charge of $11.99", "Manage your plan — cancel before your next billing date to avoid charges. Cancel anytime."),
        ], expectedStatus: .active, category: "false_positive"),

        Scenario(id: 12, service: "Headspace", emails: [
            (d(5), "Headspace welcome", "Start your journey. Free to cancel within 7 days.", nil),
        ], expectedStatus: .active, category: "false_positive"),

        Scenario(id: 13, service: "NordVPN", emails: [
            (d(20), "How to cancel your NordVPN plan", "Here's our cancellation policy and step-by-step guide.", nil),
        ], expectedStatus: .active, category: "false_positive"),

        // ——— CANCELED SUBSCRIPTIONS (expectedStatus = .canceled) ———
        Scenario(id: 14, service: "Hulu", emails: [
            (d(90), "Your Hulu receipt", "Payment of $7.99", nil),
            (d(60), "Your Hulu receipt", "Payment of $7.99", nil),
            (d(15), "Your Hulu subscription has been canceled", "We're sorry to see you go", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 15, service: "HBO Max", emails: [
            (d(45), "HBO Max billing", "Payment of $15.99", nil),
            (d(10), "Cancellation confirmed", "Your HBO Max subscription has been canceled", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 16, service: "Adobe CC", emails: [
            (d(30), "Adobe Creative Cloud invoice", "Monthly charge of $54.99", nil),
            (d(5), "Adobe membership canceled", "Your Creative Cloud membership has been canceled effective today", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 17, service: "Gym Plus", emails: [
            (d(60), "Gym Plus monthly billing", "Auto-pay of $29.99 processed", nil),
            (d(8), "Membership canceled", "Your gym membership has been canceled effective immediately", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 18, service: "ExpressVPN", emails: [
            (d(90), "ExpressVPN payment", "Payment of $8.32", nil),
            (d(3), "Account closed", "Your ExpressVPN account has been successfully closed", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 19, service: "Calm", emails: [
            (d(40), "Calm annual receipt", "Payment of $69.99", nil),
            (d(12), "We've canceled your Calm subscription", "Your premium access ends on March 15", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 20, service: "Audible", emails: [
            (d(25), "Audible membership billing", "Monthly charge $14.95", nil),
            (d(7), "You have canceled your Audible membership", "Your Audible membership has been canceled", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 21, service: "Crunchyroll", emails: [
            (d(35), "Crunchyroll Premium billing", "Payment of $7.99", nil),
            (d(4), "Successfully unsubscribed from Crunchyroll", "You have been unsubscribed from Crunchyroll Premium", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 22, service: "Paramount+", emails: [
            (d(60), "Paramount+ receipt", "Payment of $5.99", nil),
            (d(2), "Subscription ended", "Your Paramount+ subscription has expired", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        Scenario(id: 23, service: "LinkedIn Premium", emails: [
            (d(30), "LinkedIn Premium receipt", "Payment of $29.99", nil),
            (d(6), "Your plan has been canceled", "Your LinkedIn Premium plan has been canceled", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        // ——— BODY-ONLY CANCELLATIONS (P2 contribution) ———
        Scenario(id: 24, service: "Peacock", emails: [
            (d(45), "Peacock Premium receipt", "Payment of $5.99", nil),
            (d(8), "Update from Peacock", "Important changes to your account",
             "We're writing to confirm that your subscription has been canceled. Your access continues until the end of your billing period."),
        ], expectedStatus: .canceled, category: "body_only"),

        Scenario(id: 25, service: "Strava", emails: [
            (d(30), "Strava Summit receipt", "Payment of $7.99", nil),
            (d(5), "Account notification", "Changes to your Strava account",
             "This email confirms that your Strava Summit subscription has been canceled effective today. You can resubscribe at any time."),
        ], expectedStatus: .canceled, category: "body_only"),

        Scenario(id: 26, service: "Duolingo", emails: [
            (d(60), "Duolingo Super receipt", "Payment of $6.99", nil),
            (d(3), "Account update from Duolingo", "Your account has been updated",
             "We have processed your cancellation request. Your Duolingo Super membership canceled as requested. You'll still have access until April 1."),
        ], expectedStatus: .canceled, category: "body_only"),

        // ——— CANCEL THEN REACTIVATE (expectedStatus = .active) ———
        Scenario(id: 27, service: "Netflix (reactivated)", emails: [
            (d(90), "Your receipt from Netflix", "Payment of $15.99", nil),
            (d(45), "Subscription canceled", "Your Netflix subscription has been canceled", nil),
            (d(5), "Your receipt from Netflix", "Payment of $15.99 received. Welcome back!", nil),
        ], expectedStatus: .active, category: "reactivated"),

        Scenario(id: 28, service: "Spotify (reactivated)", emails: [
            (d(60), "Spotify Premium receipt", "Payment of $9.99", nil),
            (d(30), "Cancellation confirmed", "Your Spotify subscription has been canceled", nil),
            (d(3), "Spotify Premium receipt", "Payment of $9.99 received", nil),
        ], expectedStatus: .active, category: "reactivated"),

        Scenario(id: 29, service: "Hulu (reactivated)", emails: [
            (d(120), "Hulu receipt", "Payment of $7.99", nil),
            (d(60), "Your Hulu subscription has been canceled", "We're sorry to see you go", nil),
            (d(10), "Hulu receipt", "Auto-pay of $7.99 processed", nil),
        ], expectedStatus: .active, category: "reactivated"),

        Scenario(id: 30, service: "Disney+ (reactivated)", emails: [
            (d(90), "Disney+ receipt", "Payment of $7.99", nil),
            (d(50), "Membership canceled", "Your Disney+ membership has been canceled", nil),
            (d(7), "Disney+ billing", "Recurring payment of $7.99 received", nil),
        ], expectedStatus: .active, category: "reactivated"),

        // ——— EDGE CASES ———
        // Service terminated
        Scenario(id: 31, service: "Quibi", emails: [
            (d(200), "Quibi receipt", "Payment of $4.99", nil),
            (d(180), "Service terminated", "Quibi is shutting down. Your account has been deactivated.", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        // Very old cancel, no recent emails
        Scenario(id: 32, service: "Tidal", emails: [
            (d(300), "Tidal HiFi receipt", "Payment of $9.99", nil),
            (d(250), "Subscription canceled", "Your Tidal subscription has been canceled", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        // Multiple cancellation emails (reinforcement)
        Scenario(id: 33, service: "Apple Music", emails: [
            (d(60), "Apple Music receipt", "Payment of $10.99", nil),
            (d(10), "Cancellation confirmed", "Your Apple Music subscription will end on Feb 28", nil),
            (d(9), "Your plan has been canceled", "Reminder: your Apple Music plan is now canceled", nil),
        ], expectedStatus: .canceled, category: "canceled"),

        // Body has "cancel anytime" but subject has real cancel
        Scenario(id: 34, service: "Grammarly", emails: [
            (d(30), "Grammarly Premium invoice", "Payment of $12.00", nil),
            (d(5), "Subscription canceled", "Your Grammarly Premium is canceled",
             "We've processed your cancellation. Cancel anytime policy applies — you won't be charged again."),
        ], expectedStatus: .canceled, category: "canceled"),

        // Subject ambiguous but body is clear cancel
        Scenario(id: 35, service: "Evernote", emails: [
            (d(45), "Evernote Professional billing", "Monthly charge of $14.99", nil),
            (d(7), "Important update about your Evernote account", "Please review the changes below",
             "After careful consideration, we have processed your request. Your subscription has been canceled as of today."),
        ], expectedStatus: .canceled, category: "body_only"),

        // Single email with no lifecycle signal — AI defers
        Scenario(id: 36, service: "Notion AI", emails: [
            (d(15), "Notion AI add-on billing", "Payment of $8.00", nil),
        ], expectedStatus: .active, category: "active"),

        // Cancel + body false positive should still count as cancel (cancel in subject wins)
        Scenario(id: 37, service: "Canva", emails: [
            (d(30), "Canva Pro receipt", "Payment of $12.99", nil),
            (d(5), "Cancellation confirmed for Canva Pro", "Your Canva Pro is canceled",
             "You can cancel anytime in the future if you resubscribe."),
        ], expectedStatus: .canceled, category: "canceled"),

        // No emails at all (empty timeline)
        Scenario(id: 38, service: "EmptyService", emails: [], expectedStatus: .active, category: "active"),
    ]

    // MARK: - Quality Metrics Test

    func testLifecycleDetectionQuality() {
        var tp = 0 // true positive: expected cancel, got cancel
        var fp = 0 // false positive: expected active, got cancel
        var tn = 0 // true negative: expected active, got active
        var fn = 0 // false negative: expected cancel, got active

        var reactivationTP = 0
        var reactivationFN = 0
        var bodyOnlyDetected = 0
        var bodyOnlyTotal = 0

        var errors: [(id: Int, service: String, expected: String, predicted: String, confidence: Double)] = []

        for scenario in scenarios {
            let result = GmailSignalEngine.resolveLifecycle(
                emails: scenario.emails.map { ($0.0, $0.1, $0.2, $0.3) },
                aiStatus: .active, // default AI assumption
                aiStatusDate: nil
            )

            let predictedStatus = result.confidence >= 0.80 ? result.status : .active

            if scenario.category == "body_only" {
                bodyOnlyTotal += 1
            }

            if scenario.expectedStatus == .canceled {
                if predictedStatus == .canceled {
                    tp += 1
                    if scenario.category == "body_only" { bodyOnlyDetected += 1 }
                } else {
                    fn += 1
                    errors.append((scenario.id, scenario.service, "canceled", predictedStatus.rawValue, result.confidence))
                }
            } else { // expected active (includes reactivated + false_positive)
                if predictedStatus == .active {
                    tn += 1
                    if scenario.category == "reactivated" { reactivationTP += 1 }
                } else {
                    fp += 1
                    if scenario.category == "reactivated" { reactivationFN += 1 }
                    errors.append((scenario.id, scenario.service, "active", predictedStatus.rawValue, result.confidence))
                }
            }
        }

        let cancelRecall = tp + fn > 0 ? Double(tp) / Double(tp + fn) : 1.0
        let cancelPrecision = tp + fp > 0 ? Double(tp) / Double(tp + fp) : 1.0
        let fpRate = tn + fp > 0 ? Double(fp) / Double(tn + fp) : 0.0
        let reactivationRecall = reactivationTP + reactivationFN > 0
            ? Double(reactivationTP) / Double(reactivationTP + reactivationFN) : 1.0

        // Print metrics report
        NSLog("═══ P3 LIFECYCLE QUALITY REPORT ═══")
        NSLog("Scenarios: %d | TP: %d | FP: %d | TN: %d | FN: %d", scenarios.count, tp, fp, tn, fn)
        NSLog("Cancel recall:    %.2f (target >= 0.90)", cancelRecall)
        NSLog("Cancel precision: %.2f (target >= 0.95)", cancelPrecision)
        NSLog("FP rate:          %.2f (target <= 0.05)", fpRate)
        NSLog("Reactivation recall: %.2f", reactivationRecall)
        NSLog("Body-only detected:  %d/%d", bodyOnlyDetected, bodyOnlyTotal)

        if !errors.isEmpty {
            NSLog("─── ERRORS ───")
            for err in errors {
                NSLog("#%d %@: expected=%@ predicted=%@ conf=%.2f", err.id, err.service, err.expected, err.predicted, err.confidence)
            }
        }
        NSLog("═══════════════════════════════════")

        // Assert target thresholds
        XCTAssertGreaterThanOrEqual(cancelRecall, 0.90, "Cancel recall must be >= 0.90")
        XCTAssertGreaterThanOrEqual(cancelPrecision, 0.95, "Cancel precision must be >= 0.95")
        XCTAssertLessThanOrEqual(fpRate, 0.05, "False positive rate must be <= 0.05")
        XCTAssertGreaterThanOrEqual(reactivationRecall, 0.90, "Reactivation recall must be >= 0.90")
    }

    // MARK: - Cancellation Signal Coverage Test

    /// Validates that each cancellation scenario has a detectable signal.
    func testCancellationSignalCoverage() {
        let cancelScenarios = scenarios.filter { $0.expectedStatus == .canceled }
        var detected = 0

        for scenario in cancelScenarios {
            var maxScore: Double = 0
            for email in scenario.emails {
                let score = GmailSignalEngine.detectCancellationSignal(
                    subject: email.subject, snippet: email.snippet, bodyText: email.bodyExcerpt
                )
                maxScore = max(maxScore, score)
            }
            if maxScore >= 0.80 { detected += 1 }
        }

        let coverage = cancelScenarios.isEmpty ? 1.0 : Double(detected) / Double(cancelScenarios.count)
        NSLog("Cancel signal coverage: %d/%d (%.0f%%)", detected, cancelScenarios.count, coverage * 100)
        XCTAssertGreaterThanOrEqual(coverage, 0.90, "At least 90%% of cancel scenarios should have detectable signal")
    }

    // MARK: - False Positive Resistance Test

    /// Validates that false-positive scenarios do NOT trigger cancellation.
    func testFalsePositiveResistance() {
        let fpScenarios = scenarios.filter { $0.category == "false_positive" }
        var falseAlarms = 0

        for scenario in fpScenarios {
            var maxScore: Double = 0
            for email in scenario.emails {
                let score = GmailSignalEngine.detectCancellationSignal(
                    subject: email.subject, snippet: email.snippet, bodyText: email.bodyExcerpt
                )
                maxScore = max(maxScore, score)
            }
            if maxScore >= 0.80 { falseAlarms += 1 }
        }

        NSLog("False positive resistance: %d/%d triggered (0 expected)", falseAlarms, fpScenarios.count)
        XCTAssertEqual(falseAlarms, 0, "No false-positive scenario should trigger cancellation signal")
    }

    // MARK: - P2 Body-Only Contribution Test

    /// Validates that body-only cancellation scenarios are detected (P2 contribution).
    func testP2BodyOnlyContribution() {
        let bodyScenarios = scenarios.filter { $0.category == "body_only" }
        var subjectSnippetOnly = 0
        var withBody = 0

        for scenario in bodyScenarios {
            for email in scenario.emails {
                // Score without body
                let scoreNoBod = GmailSignalEngine.detectCancellationSignal(
                    subject: email.subject, snippet: email.snippet
                )
                // Score with body
                let scoreWithBody = GmailSignalEngine.detectCancellationSignal(
                    subject: email.subject, snippet: email.snippet, bodyText: email.bodyExcerpt
                )
                if scoreNoBod >= 0.80 { subjectSnippetOnly += 1 }
                if scoreWithBody >= 0.80 && scoreNoBod < 0.80 { withBody += 1 }
            }
        }

        NSLog("P2 body-only contribution: %d emails detected only via body (not subject/snippet)", withBody)
        XCTAssertGreaterThan(withBody, 0, "P2 body-aware detection should find at least some body-only cancellations")
    }

    // MARK: - Sender Ranking Contribution Test

    /// Validates that lifecycle-priority ranking preserves low-volume cancellation senders.
    func testP2SenderRankingContribution() {
        // Create 31 senders: 30 high-volume no-signal + 1 low-volume with cancel signal
        var senders: [SenderSummary] = []

        for i in 0..<30 {
            senders.append(SenderSummary(
                senderName: "HighVol-\(i)",
                senderDomain: "highvol\(i).com",
                queryDomain: "highvol\(i).com",
                emailCount: 20 + i,
                amounts: [9.99],
                latestSubject: "Your receipt",
                latestDate: Date(timeIntervalSinceNow: -Double(i) * 86400),
                latestSnippet: "Payment received"
            ))
        }

        // Low-volume cancel sender (would be dropped by old emailCount sort)
        senders.append(SenderSummary(
            senderName: "CancelTarget",
            senderDomain: "canceltarget.com",
            queryDomain: "canceltarget.com",
            emailCount: 1,
            amounts: [],
            latestSubject: "Your subscription has been canceled",
            latestDate: Date(timeIntervalSinceNow: -86400),
            latestSnippet: "We've canceled your membership"
        ))

        // Old ranking: just emailCount desc → cancel sender is #31 (dropped by prefix(30))
        let oldRanked = senders.sorted { $0.emailCount > $1.emailCount }.prefix(30).map(\.senderName)
        XCTAssertFalse(oldRanked.contains("CancelTarget"), "Old ranking should drop the cancel sender")

        // New ranking: lifecycle-priority
        let newRanked = senders.sorted { a, b in
            let aScore = GmailSignalEngine.senderLifecycleScore(for: a)
            let bScore = GmailSignalEngine.senderLifecycleScore(for: b)
            let aHas = aScore >= 0.80
            let bHas = bScore >= 0.80
            if aHas != bHas { return aHas }
            if aHas && bHas && aScore != bScore { return aScore > bScore }
            if a.emailCount != b.emailCount { return a.emailCount > b.emailCount }
            return a.latestDate > b.latestDate
        }.prefix(30).map(\.senderName)

        XCTAssertTrue(newRanked.contains("CancelTarget"),
            "New lifecycle-priority ranking should preserve the cancel sender in top 30")
    }
}
