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
        ("direct debit", 0.7)
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
                evidence: evidence
            )
        }
    }
}
