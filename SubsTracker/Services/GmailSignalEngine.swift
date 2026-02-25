import Foundation

/// Pure deterministic parsing engine for Gmail subscription detection.
/// No SwiftData, UserDefaults, or UI dependencies — fully testable.
enum GmailSignalEngine {

    // MARK: - Name Normalization

    /// Normalizes a service name for dedup comparison.
    /// Lowercases, strips punctuation, drops corporate suffixes (Inc, LLC, Ltd, etc.).
    static func normalizeName(_ name: String) -> String {
        var result = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop corporate suffixes
        let suffixes = [
            "inc.", "inc", "llc", "ltd.", "ltd", "corp.", "corp",
            "co.", "co", "pbc", "gmbh", "s.a.", "pty", "limited"
        ]
        for suffix in suffixes {
            if result.hasSuffix(" \(suffix)") {
                result = String(result.dropLast(suffix.count + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Also handle comma-separated: "Anthropic, PBC"
            if result.hasSuffix(", \(suffix)") {
                result = String(result.dropLast(suffix.count + 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip remaining punctuation (keep letters, numbers, spaces)
        result = result.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map { String($0) }
            .joined()

        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Returns true if two names are equivalent after normalization.
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizeName(a)
        let nb = normalizeName(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    // MARK: - Amount + Currency Extraction

    struct ExtractedAmount: Equatable {
        let value: Double
        let currency: String  // ISO code: USD, EUR, GBP, etc.
        let source: String    // "subject", "snippet", or "body"
    }

    /// Currency symbol → ISO code mapping
    private static let symbolToCurrency: [(String, String)] = [
        ("$", "USD"), ("€", "EUR"), ("£", "GBP"), ("¥", "JPY"),
        ("₹", "INR"), ("₽", "RUB"), ("₴", "UAH"), ("R$", "BRL"),
        ("A$", "AUD"), ("C$", "CAD"), ("zł", "PLN")
    ]

    /// ISO codes used in suffix patterns (e.g. "15.99 USD")
    private static let isoCodes: Set<String> = [
        "USD", "EUR", "GBP", "CAD", "AUD", "JPY", "INR",
        "UAH", "PLN", "BRL", "RUB", "CHF", "SEK", "NOK", "DKK", "NZD"
    ]

    /// Extracts all amounts with currency from a text, tagged with source label.
    static func extractAmounts(from text: String, source: String) -> [ExtractedAmount] {
        guard !text.isEmpty else { return [] }
        var results: [ExtractedAmount] = []

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Pattern 1: Symbol-prefix amounts — $19.99, €10, £5.50, ₹500
        let symbolPattern = try! NSRegularExpression(
            pattern: #"([$€£¥₹₽₴]|R\$|A\$|C\$|zł)\s?([\d,]+(?:\.\d{1,2})?)"#
        )
        for match in symbolPattern.matches(in: text, range: fullRange) {
            let symbol = nsText.substring(with: match.range(at: 1))
            let numStr = nsText.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: "")
            if let val = Double(numStr), val > 0, val < 100_000 {
                let currency = symbolToCurrency.first { $0.0 == symbol }?.1 ?? "USD"
                results.append(ExtractedAmount(value: val, currency: currency, source: source))
            }
        }

        // Pattern 2: Suffix ISO amounts — 15.99 USD, 200 EUR
        let suffixPattern = try! NSRegularExpression(
            pattern: #"\b(\d+(?:\.\d{1,2})?)\s+(USD|EUR|GBP|CAD|AUD|JPY|INR|UAH|PLN|BRL|RUB|CHF|SEK|NOK|DKK|NZD)\b"#
        )
        for match in suffixPattern.matches(in: text, range: fullRange) {
            let numStr = nsText.substring(with: match.range(at: 1))
            let code = nsText.substring(with: match.range(at: 2))
            if let val = Double(numStr), val > 0, val < 100_000 {
                results.append(ExtractedAmount(value: val, currency: code, source: source))
            }
        }

        return results
    }

    /// Extracts amounts from subject, snippet, and optional body text.
    /// Returns deduplicated amounts sorted by source priority (subject > snippet > body).
    static func extractAllAmounts(
        subject: String,
        snippet: String,
        bodyText: String? = nil
    ) -> [ExtractedAmount] {
        var all: [ExtractedAmount] = []
        all.append(contentsOf: extractAmounts(from: subject, source: "subject"))
        all.append(contentsOf: extractAmounts(from: snippet, source: "snippet"))
        if let body = bodyText {
            all.append(contentsOf: extractAmounts(from: body, source: "body"))
        }

        // Deduplicate by value (keep the highest-priority source)
        let sourcePriority = ["subject": 0, "snippet": 1, "body": 2]
        var seen: [Double: ExtractedAmount] = [:]
        for amount in all {
            let priority = sourcePriority[amount.source] ?? 3
            if let existing = seen[amount.value] {
                let existingPriority = sourcePriority[existing.source] ?? 3
                if priority < existingPriority {
                    seen[amount.value] = amount
                }
            } else {
                seen[amount.value] = amount
            }
        }

        return Array(seen.values).sorted {
            let p1 = sourcePriority[$0.source] ?? 3
            let p2 = sourcePriority[$1.source] ?? 3
            return p1 < p2
        }
    }

    // MARK: - Billing Signal Score

    /// Keywords that indicate billing/subscription emails (weighted).
    private static let billingKeywords: [(pattern: String, weight: Double)] = [
        ("receipt", 1.0),
        ("invoice", 1.0),
        ("payment confirmation", 1.0),
        ("payment received", 0.9),
        ("your payment", 0.9),
        ("billing statement", 0.9),
        ("charged", 0.8),
        ("amount due", 0.8),
        ("subscription", 0.7),
        ("renewal", 0.7),
        ("renewed", 0.7),
        ("your plan", 0.6),
        ("membership", 0.6),
        ("recurring", 0.5),
        ("monthly charge", 0.9),
        ("annual charge", 0.9),
        ("auto-pay", 0.7),
        ("autopay", 0.7),
        ("direct debit", 0.7),
        ("recurring payment", 0.8)
    ]

    /// Computes a billing signal score (0.0 – 1.0) for text from email subject/snippet.
    /// Higher scores indicate stronger billing evidence.
    static func billingSignalScore(subject: String, snippet: String) -> Double {
        let combinedText = "\(subject) \(snippet)".lowercased()
        var maxWeight: Double = 0

        for (keyword, weight) in billingKeywords {
            if combinedText.contains(keyword) {
                maxWeight = max(maxWeight, weight)
            }
        }

        return maxWeight
    }

    // MARK: - Payment Processor Detection

    struct ProcessorSplit: Equatable {
        let isProcessor: Bool       // true if sender is a payment processor
        let processorName: String   // e.g. "Stripe", "PayPal"
        let serviceName: String?    // extracted real service name, if found
    }

    /// Known payment processor domains
    private static let processorDomains: [String: String] = [
        "stripe.com": "Stripe",
        "paddle.com": "Paddle",
        "paypal.com": "PayPal",
        "gumroad.com": "Gumroad",
        "fastspring.com": "FastSpring",
        "chargebee.com": "Chargebee",
        "recurly.com": "Recurly",
        "braintreegateway.com": "Braintree",
        "braintreepayments.com": "Braintree",
        "2checkout.com": "2Checkout",
        "lemonsqueezy.com": "Lemon Squeezy"
    ]

    /// Detects if a sender domain is a payment processor and extracts the real service name from the subject.
    static func detectProcessor(domain: String, subject: String) -> ProcessorSplit {
        let lowerDomain = domain.lowercased()

        guard let processorName = processorDomains[lowerDomain] else {
            return ProcessorSplit(isProcessor: false, processorName: "", serviceName: nil)
        }

        // Try to extract real service name from subject patterns:
        // "Your receipt from ServiceName"
        // "Invoice for ServiceName"
        // "Payment to ServiceName"
        let nsSubject = subject as NSString
        let subjectRange = NSRange(location: 0, length: nsSubject.length)

        let patterns = [
            #"(?:receipt|invoice|payment|charge).*(?:from|for|to)\s+(.+?)(?:\s*[-#|]|\s*$)"#,
            #"^(.+?)\s+(?:receipt|invoice|payment)"#
        ]

        for patternStr in patterns {
            if let regex = try? NSRegularExpression(pattern: patternStr, options: .caseInsensitive),
               let match = regex.firstMatch(in: subject, range: subjectRange) {
                let extracted = nsSubject.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !extracted.isEmpty, extracted.count < 50 {
                    return ProcessorSplit(isProcessor: true, processorName: processorName, serviceName: extracted)
                }
            }
        }

        return ProcessorSplit(isProcessor: true, processorName: processorName, serviceName: nil)
    }

    // MARK: - Body Text Extraction (HTML → plain text)

    /// Strips HTML tags and decodes common entities to produce plain text.
    /// Lightweight — no WebKit dependency.
    static func stripHTML(_ html: String) -> String {
        var text = html

        // Replace <br>, <p>, <div> with newlines
        let blockTags = try! NSRegularExpression(pattern: #"<\s*(?:br|p|div|tr|li)[^>]*>"#, options: .caseInsensitive)
        text = blockTags.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "\n")

        // Remove all remaining HTML tags
        let tagPattern = try! NSRegularExpression(pattern: #"<[^>]+>"#)
        text = tagPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "")

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&#x27;", "'"), ("&#x2F;", "/"),
            ("&dollar;", "$"), ("&#36;", "$")
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }

        // Decode numeric entities: &#123; and &#x1F;
        let numericEntity = try! NSRegularExpression(pattern: #"&#(\d+);"#)
        text = numericEntity.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: " ")

        let hexEntity = try! NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);"#)
        text = hexEntity.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: " ")

        // Collapse whitespace
        let multiSpace = try! NSRegularExpression(pattern: #"[ \t]+"#)
        text = multiSpace.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: " ")

        let multiNewline = try! NSRegularExpression(pattern: #"\n{3,}"#)
        text = multiNewline.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "\n\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sender Summary Enhancement

    /// Determines if a sender group is "high-signal" (likely a real subscription)
    /// but missing a concrete amount — making it a candidate for body fetch.
    static func needsBodyFetch(
        emailCount: Int,
        amounts: [Double],
        billingScore: Double
    ) -> Bool {
        // High-signal: multiple emails or strong billing keywords, but no amounts found
        let hasNoAmount = amounts.isEmpty
        let isHighSignal = emailCount >= 2 || billingScore >= 0.7
        return hasNoAmount && isHighSignal
    }

    // MARK: - Charge Type Classification (Local Fallback / Validation)

    /// Keyword groups for local charge type classification.
    private static let recurringSignals: [(String, Double)] = [
        ("subscription", 0.9), ("renewal", 0.9), ("renewed", 0.9),
        ("recurring", 0.8), ("monthly charge", 0.9), ("annual charge", 0.9),
        ("auto-pay", 0.8), ("autopay", 0.8), ("membership", 0.7),
        ("your plan", 0.6), ("billing period", 0.8), ("next billing", 0.8),
        ("monthly plan", 0.8), ("annual plan", 0.8), ("yearly plan", 0.8),
        ("direct debit", 0.7)
    ]

    private static let topUpSignals: [(String, Double)] = [
        ("top up", 0.9), ("top-up", 0.9), ("topup", 0.9),
        ("credits", 0.7), ("tokens", 0.7), ("usage", 0.6),
        ("pay as you go", 0.8), ("pay-as-you-go", 0.8),
        ("prepaid", 0.7), ("balance", 0.5), ("added funds", 0.8),
        ("api usage", 0.8), ("metered", 0.7)
    ]

    private static let addonSignals: [(String, Double)] = [
        ("add-on", 0.8), ("addon", 0.8), ("add on", 0.8),
        ("one-time", 0.7), ("one time", 0.7), ("single purchase", 0.8),
        ("upgrade", 0.6), ("license", 0.6), ("lifetime", 0.8),
        ("purchased", 0.5)
    ]

    private static let refundSignals: [(String, Double)] = [
        ("refund", 0.95), ("refunded", 0.95), ("reversal", 0.9),
        ("chargeback", 0.9), ("credit applied", 0.8), ("money back", 0.8),
        ("cancelled charge", 0.85), ("returned", 0.6)
    ]

    private static let antiSignals: Set<String> = [
        "marketing", "newsletter", "promo", "promotion",
        "trial", "free trial", "welcome", "getting started",
        "verify your email", "confirm your email",
        "password reset", "security alert", "sign in",
        "shipping", "delivery", "tracking", "order shipped"
    ]

    /// Classifies a charge type from email text using keyword signals.
    /// Returns (.unknown, 0) if no clear signal is found.
    static func classifyChargeType(subject: String, snippet: String, bodyText: String? = nil) -> (type: ChargeType, confidence: Double) {
        let combinedText = "\(subject) \(snippet) \(bodyText ?? "")".lowercased()

        // Check anti-signals first — if strong marketing signal, return unknown
        let antiCount = antiSignals.filter { combinedText.contains($0) }.count
        if antiCount >= 2 { return (.unknown, 0) }

        // Check refund first — overrides everything
        let refundScore = maxSignalScore(in: combinedText, signals: refundSignals)
        if refundScore >= 0.8 { return (.refundOrReversal, refundScore) }

        // Score all categories
        let recurringScore = maxSignalScore(in: combinedText, signals: recurringSignals)
        let topUpScore = maxSignalScore(in: combinedText, signals: topUpSignals)
        let addonScore = maxSignalScore(in: combinedText, signals: addonSignals)

        // Pick the highest-scoring category
        let scores: [(ChargeType, Double)] = [
            (.recurringSubscription, recurringScore),
            (.usageTopup, topUpScore),
            (.addonCredits, addonScore)
        ]

        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0.4 else {
            return (.unknown, 0)
        }

        return best
    }

    /// Returns the maximum signal weight found in the text.
    private static func maxSignalScore(in text: String, signals: [(String, Double)]) -> Double {
        var maxScore: Double = 0
        for (keyword, weight) in signals {
            if text.contains(keyword) {
                maxScore = max(maxScore, weight)
            }
        }
        return maxScore
    }

    /// Validates an AI-assigned charge type against local signals.
    /// If the AI and local agree, boost confidence. If they disagree, prefer AI but lower confidence.
    static func validateChargeType(
        aiType: ChargeType,
        subject: String,
        snippet: String,
        bodyText: String? = nil
    ) -> (type: ChargeType, confidence: Double) {
        let local = classifyChargeType(subject: subject, snippet: snippet, bodyText: bodyText)

        // If local has no opinion, trust AI
        if local.type == .unknown { return (aiType, 0.7) }

        // If they agree, boost confidence
        if local.type == aiType { return (aiType, min(1.0, local.confidence + 0.1)) }

        // Refund override: local refund detection overrides AI
        if local.type == .refundOrReversal && local.confidence >= 0.8 {
            return (.refundOrReversal, local.confidence)
        }

        // Disagree: trust AI but lower confidence
        return (aiType, 0.5)
    }

    // MARK: - Cancellation Signal Detection

    /// Keywords that indicate a subscription was canceled (weighted).
    private static let cancellationSignals: [(String, Double)] = [
        ("your subscription has been canceled", 0.99),
        ("your subscription has been cancelled", 0.99),
        ("subscription canceled", 0.97),
        ("subscription cancelled", 0.97),
        ("subscription has been canceled", 0.97),
        ("subscription has been cancelled", 0.97),
        ("cancellation confirmed", 0.97),
        ("cancellation confirmation", 0.97),
        ("membership canceled", 0.95),
        ("membership cancelled", 0.95),
        ("subscription ended", 0.95),
        ("account closed", 0.90),
        ("successfully unsubscribed", 0.88),
        ("your plan has been canceled", 0.95),
        ("your plan has been cancelled", 0.95),
        ("we've canceled your", 0.95),
        ("we've cancelled your", 0.95),
        ("you have canceled", 0.93),
        ("you have cancelled", 0.93),
        ("subscription has expired", 0.90),
        ("plan expired", 0.88),
        ("service terminated", 0.88),
        ("your account has been deactivated", 0.85)
    ]

    /// Phrases that look like cancellation but are NOT actual cancellation events.
    private static let cancellationFalsePositives: Set<String> = [
        "cancel anytime",
        "you can cancel",
        "easy to cancel",
        "cancellation policy",
        "how to cancel",
        "free to cancel",
        "cancel at any time",
        "cancel your subscription anytime",
        "cancel before",
        "cancel within",
        "no cancellation fee",
        "risk-free cancellation"
    ]

    /// Detects cancellation signal strength (0.0–1.0) from email subject/snippet/body.
    /// Subject/snippet signals take priority — a body false positive ("cancel anytime")
    /// does NOT suppress a clear cancel signal in the subject.
    static func detectCancellationSignal(subject: String, snippet: String, bodyText: String? = nil) -> Double {
        let headerText = "\(subject) \(snippet)".lowercased()

        // Phase 1: Check subject+snippet in isolation
        let headerHasFP = cancellationFalsePositives.contains { headerText.contains($0) }
        if !headerHasFP {
            var headerScore: Double = 0
            for (keyword, weight) in cancellationSignals {
                if headerText.contains(keyword) {
                    headerScore = max(headerScore, weight)
                }
            }
            // Strong header signal → return immediately (body FPs don't override subject signals)
            if headerScore >= 0.80 { return headerScore }
        }

        // Phase 2: Expand to body when header has no clear signal
        guard let body = bodyText, !body.isEmpty else {
            return headerHasFP ? 0 : 0
        }

        let fullText = "\(headerText) \(body.lowercased())"

        // Check FPs in full text
        for fp in cancellationFalsePositives {
            if fullText.contains(fp) { return 0 }
        }

        var maxScore: Double = 0
        for (keyword, weight) in cancellationSignals {
            if fullText.contains(keyword) {
                maxScore = max(maxScore, weight)
            }
        }
        return maxScore
    }

    // MARK: - Chronological Lifecycle Resolution

    struct LifecycleResult {
        let status: SubscriptionStatus
        let effectiveDate: Date?
        let confidence: Double
    }

    /// Resolves subscription lifecycle from a chronological email timeline.
    /// Compares the latest cancel event vs latest charge event to determine current status.
    /// Body excerpts are included in cancellation detection when available.
    static func resolveLifecycle(
        emails: [(date: Date, subject: String, snippet: String, bodyExcerpt: String?)],
        aiStatus: SubscriptionStatus,
        aiStatusDate: Date?
    ) -> LifecycleResult {
        guard !emails.isEmpty else {
            return LifecycleResult(status: aiStatus, effectiveDate: aiStatusDate, confidence: 0.5)
        }

        // Find the latest cancel event and latest charge event
        var latestCancel: (date: Date, score: Double)?
        var latestCharge: (date: Date, score: Double)?

        for email in emails {
            let cancelScore = detectCancellationSignal(subject: email.subject, snippet: email.snippet, bodyText: email.bodyExcerpt)
            if cancelScore >= 0.80 {
                if latestCancel == nil || email.date > latestCancel!.date {
                    latestCancel = (email.date, cancelScore)
                }
            }

            let billingScore = billingSignalScore(subject: email.subject, snippet: email.snippet)
            if billingScore >= 0.70 {
                if latestCharge == nil || email.date > latestCharge!.date {
                    latestCharge = (email.date, billingScore)
                }
            }
        }

        // Decision logic
        if let cancel = latestCancel {
            if let charge = latestCharge, charge.date > cancel.date {
                // Charge after cancel = reactivated
                return LifecycleResult(status: .active, effectiveDate: charge.date, confidence: 0.90)
            }
            // Cancel is newest event
            return LifecycleResult(status: .canceled, effectiveDate: cancel.date, confidence: cancel.score)
        }

        // No cancellation found — defer to AI status
        return LifecycleResult(status: aiStatus, effectiveDate: aiStatusDate, confidence: 0.6)
    }

    // MARK: - Gmail Query Builder

    /// Builds Gmail search queries for subscription/billing email detection.
    static func buildSearchQueries(lookbackMonths: Int) -> [String] {
        let timeFilter = "newer_than:\(lookbackMonths)m"
        return [
            // Billing and receipts
            "subject:(receipt OR invoice OR payment OR billing) \(timeFilter)",
            // Subscriptions and renewals
            "subject:(subscription OR renewal OR recurring OR membership) \(timeFilter)",
            // Financial transactions
            "subject:(charged OR \"amount due\" OR \"auto-pay\" OR \"direct debit\") \(timeFilter)",
            // API/usage top-ups
            "subject:(\"top up\" OR credits OR \"usage\" OR tokens OR prepaid) \(timeFilter)",
            // Refunds (we detect and exclude later)
            "subject:(refund OR reversal OR chargeback) \(timeFilter)",
            // Cancellations and lifecycle events
            "subject:(cancel OR cancelled OR canceled OR unsubscribe OR \"subscription ended\") \(timeFilter)"
        ]
    }

    // MARK: - AI Response Parsing (Pure Logic)

    /// Parses a JSON array of subscription objects from the AI response into SubscriptionCandidate array.
    /// Pure function — no network or state dependencies.
    static func parseCandidatesFromJSON(_ subscriptions: [[String: Any]]) -> [SubscriptionCandidate] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        return subscriptions.compactMap { sub -> SubscriptionCandidate? in
            guard let name = sub["service_name"] as? String, !name.isEmpty else { return nil }

            let cost = (sub["cost"] as? Double) ?? (sub["cost"] as? Int).map { Double($0) } ?? 0
            let cycleString = sub["billing_cycle"] as? String ?? "monthly"
            let categoryString = sub["category"] as? String ?? "Other"
            let confidence = sub["confidence"] as? Double ?? 0.5
            let notes = sub["notes"] as? String
            let renewalDateString = sub["renewal_date"] as? String
            let renewalDate = renewalDateString.flatMap { dateFormatter.date(from: $0) }

            let costSourceStr = sub["cost_source"] as? String ?? "estimated"
            let costSource = CostSource(rawValue: costSourceStr) ?? .estimated
            let isEstimated = sub["is_estimated"] as? Bool ?? (costSource == .estimated)
            let evidence = sub["evidence"] as? String

            let billingCycle = BillingCycle(rawValue: cycleString) ?? .monthly
            let category = SubscriptionCategory(rawValue: categoryString) ?? .other

            // Parse charge type from AI response
            let chargeTypeStr = sub["charge_type"] as? String ?? "unknown"
            let chargeType = ChargeType(rawValue: chargeTypeStr) ?? .unknown

            // Parse subscription status from AI response
            let statusStr = sub["subscription_status"] as? String ?? "active"
            let subscriptionStatus = SubscriptionStatus(rawValue: statusStr) ?? .active

            let statusDateStr = sub["status_effective_date"] as? String
            let statusEffectiveDate = statusDateStr.flatMap { dateFormatter.date(from: $0) }

            return SubscriptionCandidate(
                name: name,
                cost: cost,
                billingCycle: billingCycle,
                category: category,
                renewalDate: renewalDate,
                confidence: confidence,
                notes: notes,
                costSource: costSource,
                isEstimated: isEstimated,
                evidence: evidence,
                chargeType: chargeType,
                subscriptionStatus: subscriptionStatus,
                statusEffectiveDate: statusEffectiveDate
            )
        }
    }

    // MARK: - Deduplication (Pure Logic)

    /// Deduplicates candidates, filtering active recurring duplicates against existing subscription names.
    /// Lets through candidates with lifecycle changes (canceled/paused/expired) even when matching existing names.
    static func testDeduplicateCandidates(_ candidates: [SubscriptionCandidate], existingNames: [String]) -> [SubscriptionCandidate] {
        deduplicateCandidates(candidates, existingNames: existingNames)
    }

    /// Core dedup logic — used by both the scanner service and tests.
    static func deduplicateCandidates(_ candidates: [SubscriptionCandidate], existingNames: [String]) -> [SubscriptionCandidate] {
        let normalizedExisting = existingNames.map { normalizeName($0) }
        let filtered = candidates.filter { candidate in
            guard candidate.chargeType.isRecurring || candidate.chargeType == .unknown else { return true }
            // Let through candidates carrying a lifecycle change
            guard candidate.subscriptionStatus == .active else { return true }
            let normalizedCandidate = normalizeName(candidate.name)
            return !normalizedExisting.contains { existing in
                namesMatch(normalizedCandidate, existing)
            }
        }

        var grouped: [String: [SubscriptionCandidate]] = [:]
        for candidate in filtered {
            let key = "\(normalizeName(candidate.name))|\(candidate.chargeType.rawValue)"
            grouped[key, default: []].append(candidate)
        }

        return grouped.values.compactMap { group -> SubscriptionCandidate? in
            guard var best = group.max(by: { $0.confidence < $1.confidence }) else { return nil }
            best.sourceEmailCount = group.count
            if let mostRecentDate = group.compactMap({ $0.renewalDate }).max() {
                best.renewalDate = mostRecentDate
            }
            return best
        }
        .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Sender Lifecycle Score (for ranking)

    /// Computes the best cancellation signal score across a sender's emails (subject + snippet).
    /// Used to boost lifecycle-significant senders in ranking before the top-30 cap.
    static func senderLifecycleScore(for sender: SenderSummary) -> Double {
        var maxScore: Double = 0
        // Check latest subject/snippet
        maxScore = max(maxScore, detectCancellationSignal(subject: sender.latestSubject, snippet: sender.latestSnippet))
        // Check timeline emails
        for email in sender.recentEmails {
            let score = detectCancellationSignal(subject: email.subject, snippet: email.snippet, bodyText: email.bodyExcerpt)
            maxScore = max(maxScore, score)
        }
        return maxScore
    }
}
