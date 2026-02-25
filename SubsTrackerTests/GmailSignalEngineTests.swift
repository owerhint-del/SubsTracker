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
        let emails: [(date: Date, subject: String, snippet: String)] = [
            (Date(timeIntervalSinceNow: -60*86400), "Your receipt from Netflix", "Payment of $15.99", ""),
            (Date(timeIntervalSinceNow: -30*86400), "Subscription canceled", "Your Netflix subscription has been canceled", "")
        ].map { ($0.0, $0.1, $0.2) }

        let result = GmailSignalEngine.resolveLifecycle(
            emails: emails,
            aiStatus: .active,
            aiStatusDate: nil
        )
        XCTAssertEqual(result.status, .canceled, "Cancel after charge should result in canceled")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85)
    }

    func testCancelThenCharge_ResultsActive() {
        let emails: [(date: Date, subject: String, snippet: String)] = [
            (Date(timeIntervalSinceNow: -60*86400), "Subscription canceled", "Your subscription has been canceled", ""),
            (Date(timeIntervalSinceNow: -10*86400), "Your receipt from Netflix", "Payment of $15.99 received", "")
        ].map { ($0.0, $0.1, $0.2) }

        let result = GmailSignalEngine.resolveLifecycle(
            emails: emails,
            aiStatus: .canceled,
            aiStatusDate: nil
        )
        XCTAssertEqual(result.status, .active, "Charge after cancel should mean reactivated")
    }

    func testCancelAnytimeInTimeline_StaysActive() {
        let emails: [(date: Date, subject: String, snippet: String)] = [
            (Date(timeIntervalSinceNow: -30*86400), "Your receipt from Spotify", "Payment of $9.99. Cancel anytime from settings.", ""),
            (Date(timeIntervalSinceNow: -5*86400), "Your receipt from Spotify", "Payment of $9.99 received", "")
        ].map { ($0.0, $0.1, $0.2) }

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
