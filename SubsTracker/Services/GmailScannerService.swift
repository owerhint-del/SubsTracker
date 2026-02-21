import Foundation

@MainActor
@Observable
final class GmailScannerService {
    static let shared = GmailScannerService()

    var progress = ScanProgress()

    private let gmail = GmailOAuthService.shared
    private let maxMessages = 200

    private init() {}

    // MARK: - Full Scan Pipeline

    func scanForSubscriptions(existingNames: [String] = []) async throws -> [SubscriptionCandidate] {
        // Phase 1: Search for billing/receipt emails
        progress = ScanProgress(phase: .searching)
        let messageIds = try await searchBillingEmails()
        NSLog("[Scanner] Phase 1 — found %d message IDs", messageIds.count)

        guard !messageIds.isEmpty else {
            NSLog("[Scanner] Phase 1 returned 0 messages — aborting")
            return []
        }

        // Phase 2: Fetch email headers only (no bodies)
        progress = ScanProgress(phase: .fetching, total: messageIds.count)
        let emails = try await fetchEmailMetadata(messageIds: messageIds)
        NSLog("[Scanner] Phase 2 — fetched %d email metadata", emails.count)

        guard !emails.isEmpty else {
            NSLog("[Scanner] Phase 2 returned 0 emails — aborting")
            return []
        }

        // Phase 3: Group by sender + extract amounts locally
        progress = ScanProgress(phase: .grouping)
        let senders = groupBySender(emails)
        NSLog("[Scanner] Phase 3 — grouped into %d senders", senders.count)
        #if DEBUG
        for sender in senders.prefix(5) {
            NSLog("[Scanner]   → %@ (%@) — %d emails, amounts: %@", sender.senderName, sender.senderDomain, sender.emailCount, sender.amounts.map { String(format: "$%.2f", $0) }.joined(separator: ", "))
        }
        #endif

        guard !senders.isEmpty else {
            NSLog("[Scanner] Phase 3 returned 0 senders — aborting")
            return []
        }

        // Phase 4: ONE AI call to clean up and categorize
        progress = ScanProgress(phase: .analyzing)
        let candidates = try await analyzeWithAI(senders: senders, existingNames: existingNames)
        NSLog("[Scanner] Phase 4 — AI returned %d candidates", candidates.count)

        // Phase 5: Deduplicate + filter zero-cost
        progress = ScanProgress(phase: .deduplicating)
        let final = deduplicateCandidates(candidates).filter { $0.cost > 0 }
        NSLog("[Scanner] Phase 5 — after dedup+filter: %d subscriptions", final.count)
        return final
    }

    // MARK: - Phase 1: Search Gmail

    private func searchBillingEmails() async throws -> [String] {
        let queries = [
            "subject:(invoice OR receipt OR \"billing statement\" OR \"your payment\") newer_than:6m",
            "subject:(subscription OR membership OR renewal OR \"your plan\") newer_than:6m",
            "subject:(charged OR \"amount due\" OR \"payment confirmation\" OR \"payment received\") newer_than:6m"
        ]

        var allMessageIds = Set<String>()

        for query in queries {
            do {
                let ids = try await searchMessages(query: query)
                NSLog("[Scanner] Query returned %d messages: %@", ids.count, String(query.prefix(60)))
                allMessageIds.formUnion(ids)
            } catch {
                NSLog("[Scanner] Query FAILED: %@ — error: %@", String(query.prefix(60)), error.localizedDescription)
                throw error
            }

            if allMessageIds.count >= maxMessages {
                break
            }
        }

        NSLog("[Scanner] Total unique message IDs: %d", allMessageIds.count)
        return Array(allMessageIds.prefix(maxMessages))
    }

    private func searchMessages(query: String) async throws -> [String] {
        var allIds: [String] = []
        var pageToken: String?

        repeat {
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: "100")
            ]
            if let token = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: token))
            }

            let data = try await gmail.authenticatedRequest(path: "/messages", queryItems: queryItems)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[Scanner] searchMessages: Failed to parse JSON response. Raw: %@", String(data: data, encoding: .utf8) ?? "nil")
                break
            }

            if let messages = json["messages"] as? [[String: Any]] {
                let ids = messages.compactMap { $0["id"] as? String }
                allIds.append(contentsOf: ids)
            } else {
                NSLog("[Scanner] searchMessages: No 'messages' key in response. Keys: %@", Array(json.keys).joined(separator: ", "))
                if let resultSize = json["resultSizeEstimate"] as? Int {
                    NSLog("[Scanner] searchMessages: resultSizeEstimate = %d", resultSize)
                }
            }

            pageToken = json["nextPageToken"] as? String

            if allIds.count >= maxMessages {
                break
            }
        } while pageToken != nil

        return allIds
    }

    // MARK: - Phase 2: Fetch Metadata Only (no bodies)

    private func fetchEmailMetadata(messageIds: [String]) async throws -> [EmailMetadata] {
        var emails: [EmailMetadata] = []

        for (index, messageId) in messageIds.enumerated() {
            progress.current = index + 1

            do {
                let data = try await gmail.authenticatedRequest(
                    path: "/messages/\(messageId)",
                    queryItems: [
                        URLQueryItem(name: "format", value: "metadata"),
                        URLQueryItem(name: "metadataHeaders", value: "From"),
                        URLQueryItem(name: "metadataHeaders", value: "Subject"),
                        URLQueryItem(name: "metadataHeaders", value: "Date")
                    ]
                )
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let payload = json["payload"] as? [String: Any] ?? [:]
                let headers = extractHeaders(from: payload)
                let snippet = json["snippet"] as? String ?? ""

                let from = headers["From"] ?? ""
                let subject = headers["Subject"] ?? ""
                let dateString = headers["Date"] ?? ""
                let date = parseRFC2822Date(dateString) ?? Date()

                guard !subject.isEmpty else { continue }

                emails.append(EmailMetadata(
                    id: messageId,
                    from: from,
                    subject: subject,
                    date: date,
                    snippet: snippet
                ))
            } catch {
                NSLog("[Scanner] Failed to fetch message %@: %@", messageId, error.localizedDescription)
                continue
            }

            // Light rate limiting
            if index % 50 == 49 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        return emails
    }

    // MARK: - Phase 3: Group by Sender + Extract Amounts

    // Known payment processors whose emails contain the actual service name in the subject
    private let paymentProcessorDomains: Set<String> = [
        "stripe.com", "paddle.com", "paypal.com", "gumroad.com",
        "fastspring.com", "chargebee.com", "recurly.com", "braintreegateway.com"
    ]

    private func groupBySender(_ emails: [EmailMetadata]) -> [SenderSummary] {
        // Regex for domain extraction from From header
        let angleRegex = try! NSRegularExpression(pattern: #"([^<]*)<[^@]+@([^>]+)>"#)
        let plainRegex = try! NSRegularExpression(pattern: #"[^@]+@(.+)"#)
        // Regex for amount extraction from subject/snippet
        let amountRegex = try! NSRegularExpression(pattern: #"[$€£¥]\s?[\d,]+(?:\.\d{1,2})?"#)
        let amountSuffixRegex = try! NSRegularExpression(pattern: #"\b(\d+(?:\.\d{1,2})?)\s*(?:USD|EUR|GBP|CAD|AUD|UAH|PLN|BRL|INR)\b"#)
        // Regex for extracting service name from receipt subjects: "Your receipt from ServiceName"
        let receiptNameRegex = try! NSRegularExpression(pattern: #"(?:receipt|invoice|payment).*?(?:from|for)\s+(.+?)(?:\s*#|\s*$)"#, options: .caseInsensitive)

        struct ParsedEmail {
            let groupKey: String       // domain or extracted service name
            let displayName: String
            let subject: String
            let snippet: String
            let date: Date
            let amounts: [Double]
        }

        var parsed: [ParsedEmail] = []

        for email in emails {
            let from = email.from
            let nsFrom = from as NSString
            var domain = ""
            var displayName = ""

            // Try "Name <email@domain>" format
            if let match = angleRegex.firstMatch(in: from, range: NSRange(location: 0, length: nsFrom.length)) {
                displayName = nsFrom.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                domain = nsFrom.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            } else if let match = plainRegex.firstMatch(in: from, range: NSRange(location: 0, length: nsFrom.length)) {
                domain = nsFrom.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let parts = domain.split(separator: ".")
                if let first = parts.first {
                    displayName = String(first).capitalized
                }
            }

            guard !domain.isEmpty else { continue }

            // For payment processors, extract actual service name from subject
            var groupKey = domain
            if paymentProcessorDomains.contains(domain) {
                let nsSubject = email.subject as NSString
                if let match = receiptNameRegex.firstMatch(in: email.subject, range: NSRange(location: 0, length: nsSubject.length)) {
                    let serviceName = nsSubject.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !serviceName.isEmpty {
                        groupKey = "via:\(serviceName.lowercased())"
                        displayName = serviceName
                    }
                }
            }

            // Extract dollar amounts from subject AND snippet
            var amounts: [Double] = []
            let textsToSearch = [email.subject, email.snippet]

            for text in textsToSearch {
                let nsText = text as NSString
                let textRange = NSRange(location: 0, length: nsText.length)

                // Pattern 1: $XX.XX
                for match in amountRegex.matches(in: text, range: textRange) {
                    let raw = nsText.substring(with: match.range)
                    let cleaned = raw
                        .replacingOccurrences(of: "[$€£¥\\s]", with: "", options: .regularExpression)
                        .replacingOccurrences(of: ",", with: "")
                    if let val = Double(cleaned), val > 0 {
                        amounts.append(val)
                    }
                }

                // Pattern 2: XX.XX USD
                for match in amountSuffixRegex.matches(in: text, range: textRange) {
                    let numStr = nsText.substring(with: match.range(at: 1))
                    if let val = Double(numStr), val > 0 {
                        amounts.append(val)
                    }
                }
            }

            parsed.append(ParsedEmail(
                groupKey: groupKey,
                displayName: displayName,
                subject: email.subject,
                snippet: email.snippet,
                date: email.date,
                amounts: amounts
            ))
        }

        // Group by key (domain or extracted service name)
        let grouped = Dictionary(grouping: parsed) { $0.groupKey }

        var summaries: [SenderSummary] = []
        for (key, group) in grouped {
            // Pick the most common display name
            let names = group.map(\.displayName).filter { !$0.isEmpty }
            let nameCounts = Dictionary(grouping: names) { $0 }.mapValues(\.count)
            let bestName = nameCounts.max(by: { $0.value < $1.value })?.key ?? key

            // Domain is either the key itself or extracted from the key
            let domain = key.hasPrefix("via:") ? key.replacingOccurrences(of: "via:", with: "") : key

            // Collect unique amounts
            let allAmounts = Array(Set(group.flatMap(\.amounts))).sorted()

            // Latest email
            let sorted = group.sorted { $0.date > $1.date }
            let latest = sorted.first!

            summaries.append(SenderSummary(
                senderName: bestName,
                senderDomain: domain,
                emailCount: group.count,
                amounts: allAmounts,
                latestSubject: latest.subject,
                latestDate: latest.date,
                latestSnippet: latest.snippet
            ))
        }

        // Sort by email count (most frequent = most likely active subscription)
        return summaries
            .sorted { $0.emailCount > $1.emailCount }
            .prefix(30)
            .map { $0 }
    }

    // MARK: - Phase 4: Single AI Call

    private func analyzeWithAI(senders: [SenderSummary], existingNames: [String]) async throws -> [SubscriptionCandidate] {
        guard let apiKey = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey),
              !apiKey.isEmpty else {
            throw GmailOAuthError.authFailed("OpenAI API key not configured")
        }

        // Build compact summary for the AI
        var summary = ""
        for (index, sender) in senders.enumerated() {
            let amountsStr = sender.amounts.isEmpty ? "no amounts in subject" : sender.amounts.map { String(format: "$%.2f", $0) }.joined(separator: ", ")
            let snippetStr = sender.latestSnippet.isEmpty ? "" : " — snippet: \"\(String(sender.latestSnippet.prefix(120)))\""
            let dateStr = sender.latestDate.formatted(date: .abbreviated, time: .omitted)
            summary += "\(index + 1). \(sender.senderName) (\(sender.senderDomain)) — \(sender.emailCount) emails — amounts: \(amountsStr) — latest: \"\(sender.latestSubject)\" (\(dateStr))\(snippetStr)\n"
        }

        #if DEBUG
        NSLog("[Scanner] AI input summary:\n%@", summary)
        #endif

        let existingList = existingNames.isEmpty ? "None" : existingNames.joined(separator: ", ")
        #if DEBUG
        NSLog("[Scanner] Existing names to skip: %@", existingList)
        #endif

        let systemPrompt = """
        You are a subscription detection assistant. You receive a summary of services that sent billing-related emails.

        For each, determine if this is an active PAID subscription and fill in the details.

        Respond with ONLY valid JSON:
        {"subscriptions": [{"service_name": "...", "cost": 15.99, "billing_cycle": "monthly", "category": "AI Services", "renewal_date": "2026-03-15", "confidence": 0.95, "notes": "..."}]}

        RULES:

        SERVICE NAME: Use the short brand name people use. "Vercel" not "Vercel Inc.", "Cursor" not "Cursor AI Editor". "Anthropic" not "Anthropic, PBC".

        COST AND BILLING CYCLE:
        - If an exact amount is provided in "amounts", use it.
        - If NO amount is found in the subject, look at the snippet text for dollar amounts.
        - If STILL no amount found, you MUST estimate the cost based on the service's standard pricing.
          Examples: Anthropic API → ~$100/mo, Vercel Pro → $20/mo, Railway → $5-20/mo, Linear → $10/mo per user.
          You know the pricing of most tech services. USE THAT KNOWLEDGE. Set confidence to 0.6-0.7 for estimated prices.
        - CRITICAL: A "receipt" or "invoice" email ALWAYS means a paid service. If subject says "Your receipt from X" — that is a PAID subscription. Include it.
        - billing_cycle: one of: weekly, monthly, annual. Determine from email frequency and subject/snippet text.
        - If emails come every month → "monthly". If once a year → "annual".
        - If original currency is not USD, convert to approximate USD and note original currency in notes.

        FILTERING:
        - SKIP ONLY: marketing emails, newsletters, free-tier notifications (NOT receipts!), and one-time purchases.
        - SKIP services already tracked: [\(existingList)]
        - DO NOT skip a service just because no dollar amount was found. Receipts without visible amounts are still paid services.

        OTHER FIELDS:
        - category: one of: AI Services, Streaming, SaaS, Development, Productivity, Other
        - confidence: 0.0-1.0 (lower if cost was estimated rather than extracted)
        - renewal_date: YYYY-MM-DD. Calculate from latest email date + billing cycle period.
        - notes: mention if cost was estimated vs extracted from email
        - If no paid subscriptions found, return {"subscriptions": []}
        """

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Here is a summary of services that sent billing-related emails in the past 6 months. Determine which are active paid subscriptions:\n\n\(summary)"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            NSLog("[Scanner] OpenAI API error: %@", errorBody)
            throw GmailOAuthError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "OpenAI error: \(errorBody)")
        }

        #if DEBUG
        // Log raw AI response for debugging
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            NSLog("[Scanner] AI raw response: %@", content)
        }
        #endif

        return parseOpenAIResponse(data)
    }

    private func parseOpenAIResponse(_ data: Data) -> [SubscriptionCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let subscriptions = parsed["subscriptions"] as? [[String: Any]] else {
            return []
        }

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

            let billingCycle = BillingCycle(rawValue: cycleString) ?? .monthly
            let category = SubscriptionCategory(rawValue: categoryString) ?? .other

            return SubscriptionCandidate(
                name: name,
                cost: cost,
                billingCycle: billingCycle,
                category: category,
                renewalDate: renewalDate,
                confidence: confidence,
                notes: notes
            )
        }
    }

    // MARK: - Phase 5: Deduplication

    private func deduplicateCandidates(_ candidates: [SubscriptionCandidate]) -> [SubscriptionCandidate] {
        var grouped: [String: [SubscriptionCandidate]] = [:]

        for candidate in candidates {
            let key = candidate.name.lowercased().trimmingCharacters(in: .whitespaces)
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

    // MARK: - Helpers

    private func extractHeaders(from payload: [String: Any]) -> [String: String] {
        let headers = payload["headers"] as? [[String: Any]] ?? []
        var result: [String: String] = [:]
        for header in headers {
            if let name = header["name"] as? String, let value = header["value"] as? String {
                result[name] = value
            }
        }
        return result
    }

    // Static formatters — DateFormatter is expensive to create, reuse across calls
    private static let rfc2822Formatters: [DateFormatter] = {
        let f1 = DateFormatter()
        f1.locale = Locale(identifier: "en_US_POSIX")
        f1.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let f2 = DateFormatter()
        f2.locale = Locale(identifier: "en_US_POSIX")
        f2.dateFormat = "dd MMM yyyy HH:mm:ss Z"

        let f3 = DateFormatter()
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"

        return [f1, f2, f3]
    }()
    private static let isoFormatter = ISO8601DateFormatter()

    private func parseRFC2822Date(_ dateString: String) -> Date? {
        let cleaned = dateString.trimmingCharacters(in: .whitespaces)
        for formatter in Self.rfc2822Formatters {
            if let date = formatter.date(from: cleaned) {
                return date
            }
        }
        return Self.isoFormatter.date(from: cleaned)
    }
}
