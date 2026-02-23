import Foundation

@MainActor
@Observable
final class GmailScannerService {
    static let shared = GmailScannerService()

    var progress = ScanProgress()

    private let gmail = GmailOAuthService.shared
    private let maxBodyFetches = 15

    // Configurable scan parameters (read from UserDefaults at scan time)
    private var maxMessages: Int { UserDefaults.standard.integer(forKey: "maxScannedMessages").clamped(to: 100...2000, fallback: ScanConfig.defaultMaxMessages) }
    private var lookbackMonths: Int { UserDefaults.standard.integer(forKey: "lookbackMonths").clamped(to: 1...36, fallback: ScanConfig.defaultLookbackMonths) }
    private var includeSpamTrash: Bool {
        UserDefaults.standard.object(forKey: "includeSpamAndTrash") != nil
            ? UserDefaults.standard.bool(forKey: "includeSpamAndTrash")
            : ScanConfig.defaultIncludeSpamTrash
    }

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

        // Phase 3: Group by sender + extract amounts via GmailSignalEngine
        progress = ScanProgress(phase: .grouping)
        var senders = groupBySender(emails)
        NSLog("[Scanner] Phase 3 — grouped into %d senders", senders.count)
        #if DEBUG
        for sender in senders.prefix(5) {
            NSLog("[Scanner]   → %@ (%@) — %d emails, amounts: %@, billingScore: %.1f",
                  sender.senderName, sender.senderDomain, sender.emailCount,
                  sender.amounts.map { String(format: "$%.2f", $0) }.joined(separator: ", "),
                  sender.billingScore)
        }
        #endif

        guard !senders.isEmpty else {
            NSLog("[Scanner] Phase 3 returned 0 senders — aborting")
            return []
        }

        // Phase 3.5: Selective body fetch for high-signal senders without amounts
        let bodyFetchCandidates = senders.enumerated().filter { (_, sender) in
            GmailSignalEngine.needsBodyFetch(
                emailCount: sender.emailCount,
                amounts: sender.amounts,
                billingScore: sender.billingScore
            )
        }.prefix(maxBodyFetches)

        if !bodyFetchCandidates.isEmpty {
            NSLog("[Scanner] Phase 3.5 — fetching body for %d high-signal senders", bodyFetchCandidates.count)
            for (index, sender) in bodyFetchCandidates {
                if let bodyText = try? await fetchLatestMessageBody(for: sender) {
                    senders[index].bodyText = bodyText
                    // Re-extract amounts from body text
                    let bodyAmounts = GmailSignalEngine.extractAmounts(from: bodyText, source: "body")
                    if !bodyAmounts.isEmpty {
                        let newValues = bodyAmounts.map(\.value).filter { val in
                            !senders[index].amounts.contains(val)
                        }
                        senders[index] = SenderSummary(
                            senderName: senders[index].senderName,
                            senderDomain: senders[index].senderDomain,
                            queryDomain: senders[index].queryDomain,
                            emailCount: senders[index].emailCount,
                            amounts: senders[index].amounts + newValues,
                            latestSubject: senders[index].latestSubject,
                            latestDate: senders[index].latestDate,
                            latestSnippet: senders[index].latestSnippet,
                            billingScore: senders[index].billingScore,
                            bodyText: bodyText
                        )
                        NSLog("[Scanner]   → body fetch for %@ found amounts: %@",
                              sender.senderName, bodyAmounts.map { String(format: "$%.2f", $0.value) }.joined(separator: ", "))
                    }
                }
                // Rate limiting
                if bodyFetchCandidates.count > 5 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }

        // Phase 4: ONE AI call to clean up and categorize
        progress = ScanProgress(phase: .analyzing)
        let candidates = try await analyzeWithAI(senders: senders, existingNames: existingNames)
        NSLog("[Scanner] Phase 4 — AI returned %d candidates", candidates.count)

        // Phase 5: Deduplicate using normalized names + filter zero-cost
        progress = ScanProgress(phase: .deduplicating)
        var deduped = deduplicateCandidates(candidates, existingNames: existingNames)
        deduped = deduped.filter { $0.cost > 0 }

        // Auto-deselect estimated + low confidence candidates
        for i in deduped.indices {
            if deduped[i].isEstimated && deduped[i].confidence < 0.7 {
                deduped[i].isSelected = false
            }
        }

        NSLog("[Scanner] Phase 5 — after dedup+filter: %d subscriptions", deduped.count)
        return deduped
    }

    // MARK: - Phase 1: Search Gmail

    private func searchBillingEmails() async throws -> [String] {
        let queries = GmailSignalEngine.buildSearchQueries(lookbackMonths: lookbackMonths)
        NSLog("[Scanner] Using %d queries, lookback: %dm, maxMessages: %d, includeSpamTrash: %@",
              queries.count, lookbackMonths, maxMessages, includeSpamTrash ? "YES" : "NO")

        var allMessageIds = Set<String>()

        for query in queries {
            do {
                let ids = try await searchMessages(query: query, includeSpamTrash: includeSpamTrash)
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

    private func searchMessages(query: String, includeSpamTrash: Bool = false) async throws -> [String] {
        var allIds: [String] = []
        var pageToken: String?

        repeat {
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: "100")
            ]
            if includeSpamTrash {
                queryItems.append(URLQueryItem(name: "includeSpamTrash", value: "true"))
            }
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

    // MARK: - Phase 3: Group by Sender + Extract Amounts via Engine

    private func groupBySender(_ emails: [EmailMetadata]) -> [SenderSummary] {
        let angleRegex = try! NSRegularExpression(pattern: #"([^<]*)<[^@]+@([^>]+)>"#)
        let plainRegex = try! NSRegularExpression(pattern: #"[^@]+@(.+)"#)

        struct ParsedEmail {
            let groupKey: String
            let emailDomain: String    // real sender domain (e.g. stripe.com even for via: groups)
            let displayName: String
            let subject: String
            let snippet: String
            let date: Date
            let amounts: [GmailSignalEngine.ExtractedAmount]
            let billingScore: Double
        }

        var parsed: [ParsedEmail] = []

        for email in emails {
            let from = email.from
            let nsFrom = from as NSString
            var domain = ""
            var displayName = ""

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

            // Use engine for processor detection
            let processorSplit = GmailSignalEngine.detectProcessor(domain: domain, subject: email.subject)
            var groupKey = domain
            if processorSplit.isProcessor, let serviceName = processorSplit.serviceName {
                groupKey = "via:\(serviceName.lowercased())"
                displayName = serviceName
            }

            // Use engine for amount extraction
            let amounts = GmailSignalEngine.extractAllAmounts(
                subject: email.subject,
                snippet: email.snippet
            )

            // Use engine for billing signal scoring
            let billingScore = GmailSignalEngine.billingSignalScore(
                subject: email.subject,
                snippet: email.snippet
            )

            parsed.append(ParsedEmail(
                groupKey: groupKey,
                emailDomain: domain,
                displayName: displayName,
                subject: email.subject,
                snippet: email.snippet,
                date: email.date,
                amounts: amounts,
                billingScore: billingScore
            ))
        }

        let grouped = Dictionary(grouping: parsed) { $0.groupKey }

        var summaries: [SenderSummary] = []
        for (key, group) in grouped {
            let names = group.map(\.displayName).filter { !$0.isEmpty }
            let nameCounts = Dictionary(grouping: names) { $0 }.mapValues(\.count)
            let bestName = nameCounts.max(by: { $0.value < $1.value })?.key ?? key

            let displayDomain = key.hasPrefix("via:") ? key.replacingOccurrences(of: "via:", with: "") : key

            // For processor-split groups (via:*), queryDomain is the real sender domain (e.g. stripe.com).
            // For regular groups, queryDomain == displayDomain.
            let queryDomain: String
            if key.hasPrefix("via:") {
                queryDomain = group.first?.emailDomain ?? displayDomain
            } else {
                queryDomain = displayDomain
            }

            // Collect unique amounts (by value)
            let allAmounts = Array(Set(group.flatMap { $0.amounts.map(\.value) })).sorted()

            // Max billing score across all emails in group
            let maxBillingScore = group.map(\.billingScore).max() ?? 0

            let sorted = group.sorted { $0.date > $1.date }
            let latest = sorted.first!

            summaries.append(SenderSummary(
                senderName: bestName,
                senderDomain: displayDomain,
                queryDomain: queryDomain,
                emailCount: group.count,
                amounts: allAmounts,
                latestSubject: latest.subject,
                latestDate: latest.date,
                latestSnippet: latest.snippet,
                billingScore: maxBillingScore
            ))
        }

        return summaries
            .sorted { $0.emailCount > $1.emailCount }
            .prefix(30)
            .map { $0 }
    }

    // MARK: - Phase 3.5: Selective Body Fetch

    /// Fetches the latest message body for a sender group. Returns plain text or nil.
    /// Uses `queryDomain` which is the real sender email domain (important for processor-split groups).
    private func fetchLatestMessageBody(for sender: SenderSummary) async throws -> String? {
        // Use queryDomain — for processor splits this is the actual domain (e.g. stripe.com),
        // not the extracted service name
        let query = "from:\(sender.queryDomain) newer_than:\(lookbackMonths)m"
        let queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "1")
        ]

        let listData = try await gmail.authenticatedRequest(path: "/messages", queryItems: queryItems)
        guard let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let messages = listJson["messages"] as? [[String: Any]],
              let messageId = messages.first?["id"] as? String else {
            return nil
        }

        // Fetch full message
        let msgData = try await gmail.authenticatedRequest(
            path: "/messages/\(messageId)",
            queryItems: [URLQueryItem(name: "format", value: "full")]
        )
        guard let msgJson = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
              let payload = msgJson["payload"] as? [String: Any] else {
            return nil
        }

        // Extract body text: try text/plain first, then HTML
        if let bodyText = extractBodyText(from: payload) {
            // Limit to first 2000 chars for amount extraction
            return String(bodyText.prefix(2000))
        }

        return nil
    }

    /// Recursively extracts body text from Gmail payload parts.
    private func extractBodyText(from payload: [String: Any]) -> String? {
        let mimeType = payload["mimeType"] as? String ?? ""

        // Direct body
        if mimeType == "text/plain" || mimeType == "text/html" {
            if let body = payload["body"] as? [String: Any],
               let data = body["data"] as? String,
               let decoded = decodeBase64URL(data) {
                if mimeType == "text/html" {
                    return GmailSignalEngine.stripHTML(decoded)
                }
                return decoded
            }
        }

        // Multipart: recurse into parts
        if let parts = payload["parts"] as? [[String: Any]] {
            // Prefer text/plain over text/html
            for part in parts {
                if (part["mimeType"] as? String) == "text/plain" {
                    if let text = extractBodyText(from: part) {
                        return text
                    }
                }
            }
            for part in parts {
                if let text = extractBodyText(from: part) {
                    return text
                }
            }
        }

        return nil
    }

    /// Decodes Gmail's base64url-encoded body data.
    private func decodeBase64URL(_ base64url: String) -> String? {
        var base64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Phase 4: Single AI Call (Updated Schema)

    private func analyzeWithAI(senders: [SenderSummary], existingNames: [String]) async throws -> [SubscriptionCandidate] {
        guard let apiKey = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey),
              !apiKey.isEmpty else {
            throw GmailOAuthError.authFailed("OpenAI API key not configured")
        }

        // Build compact summary with billing scores
        var summary = ""
        for (index, sender) in senders.enumerated() {
            let amountsStr = sender.amounts.isEmpty ? "no amounts found" : sender.amounts.map { String(format: "$%.2f", $0) }.joined(separator: ", ")
            let snippetStr = sender.latestSnippet.isEmpty ? "" : " — snippet: \"\(String(sender.latestSnippet.prefix(120)))\""
            let dateStr = sender.latestDate.formatted(date: .abbreviated, time: .omitted)
            let bodyNote = sender.bodyText != nil ? " [body fetched]" : ""
            summary += "\(index + 1). \(sender.senderName) (\(sender.senderDomain)) — \(sender.emailCount) emails — amounts: \(amountsStr) — billing_score: \(String(format: "%.1f", sender.billingScore)) — latest: \"\(sender.latestSubject)\" (\(dateStr))\(snippetStr)\(bodyNote)\n"
        }

        #if DEBUG
        NSLog("[Scanner] AI input summary:\n%@", summary)
        #endif

        let existingList = existingNames.isEmpty ? "None" : existingNames.joined(separator: ", ")
        #if DEBUG
        NSLog("[Scanner] Existing names to skip: %@", existingList)
        #endif

        let systemPrompt = """
        You are a subscription and billing detection assistant. You receive a summary of services that sent billing-related emails.

        For each, classify the charge type and fill in the details.

        Respond with ONLY valid JSON:
        {"subscriptions": [{"service_name": "...", "cost": 15.99, "billing_cycle": "monthly", "category": "AI Services", "charge_type": "recurring_subscription", "renewal_date": "2026-03-15", "confidence": 0.95, "cost_source": "subject", "is_estimated": false, "evidence": "found $15.99 in subject", "notes": "..."}]}

        RULES:

        SERVICE NAME: Use the short brand name people use. "Vercel" not "Vercel Inc.", "Cursor" not "Cursor AI Editor". "Anthropic" not "Anthropic, PBC".

        CHARGE TYPE (REQUIRED — one of):
        - "recurring_subscription": Regular recurring charge (monthly/annual subscription). Examples: Netflix, Spotify, GitHub Pro, ChatGPT Plus.
        - "usage_topup": Variable/usage-based charge, API credits, token top-ups. Examples: OpenAI API credits, AWS usage, Twilio balance.
        - "addon_credits": One-time add-on or credit pack purchase. Examples: extra storage, one-time license, lifetime deal.
        - "one_time_purchase": Single purchase not expected to repeat. Examples: domain registration, hardware, one-off service.
        - "refund_or_reversal": Money returned — refund, chargeback, reversal. ALWAYS include these so we can filter them.
        - "unknown": Cannot determine charge type from available evidence.

        CLASSIFICATION SIGNALS:
        - Recurring: keywords like "subscription", "renewal", "monthly", "annual", "auto-pay", "membership", regular cadence.
        - Usage top-up: keywords like "top up", "credits", "tokens", "usage", "API", "pay-as-you-go", "prepaid", irregular amounts.
        - Refund: keywords like "refund", "reversal", "chargeback", "credit applied", "money back".
        - If a service sends BOTH subscription AND top-up emails, classify based on the DOMINANT pattern.

        COST AND BILLING CYCLE:
        - If an exact amount is provided in "amounts", use it and set cost_source to where it was found (subject/snippet/body).
        - If NO amount is found anywhere, you MAY estimate based on known pricing. Set cost_source to "estimated" and is_estimated to true.
        - For estimated prices, set confidence to 0.5-0.6 (not higher).
        - billing_cycle: one of: weekly, monthly, annual. Determine from email frequency and subject/snippet text.
        - If emails come every month → "monthly". If once a year → "annual".
        - If original currency is not USD, convert to approximate USD and note original currency in notes.

        COST SOURCE FIELDS (REQUIRED):
        - cost_source: one of "subject", "snippet", "body", "estimated" — where the cost came from.
        - is_estimated: true if cost was guessed/estimated, false if extracted from actual email data.
        - evidence: short string explaining why this charge was detected and where cost came from.

        FILTERING:
        - Include ALL paid charges you can identify: subscriptions, top-ups, one-time purchases, AND refunds.
        - SKIP: marketing emails, newsletters, free-tier notifications, shipping notifications, password resets.
        - SKIP services already tracked: [\(existingList)]
        - If evidence is weak (e.g. single email, no amount, low billing_score), include with low confidence (0.4-0.5).
        - Do NOT force-include services just because they sent a receipt-like email. Use the billing_score as a signal.

        OTHER FIELDS:
        - category: one of: AI Services, Streaming, SaaS, Development, Productivity, Other
        - confidence: 0.0-1.0.
          High (0.85-1.0): exact amount extracted + multiple billing emails.
          Medium (0.7-0.84): amount found but few emails, or strong pattern.
          Low (0.5-0.69): estimated cost or weak evidence.
          Very Low (<0.5): skip instead of including.
        - renewal_date: YYYY-MM-DD. Calculate from latest email date + billing cycle period.
        - notes: brief context about the charge
        - If no paid charges found, return {"subscriptions": []}
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
                ["role": "user", "content": "Here is a summary of services that sent billing-related emails in the past \(lookbackMonths) months. Classify each charge:\n\n\(summary)"]
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
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            NSLog("[Scanner] AI raw response: %@", content)
        }
        #endif

        return parseOpenAIResponse(data, senders: senders)
    }

    /// Parses the OpenAI response JSON into SubscriptionCandidate array with local charge type validation.
    private func parseOpenAIResponse(_ data: Data, senders: [SenderSummary]) -> [SubscriptionCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let subscriptions = parsed["subscriptions"] as? [[String: Any]] else {
            return []
        }

        var candidates = GmailSignalEngine.parseCandidatesFromJSON(subscriptions)

        // Post-AI validation: cross-check charge types with local keyword signals
        for i in candidates.indices {
            let candidate = candidates[i]
            // Find matching sender for subject/snippet context
            let matchingSender = senders.first { sender in
                GmailSignalEngine.namesMatch(sender.senderName, candidate.name)
            }

            if let sender = matchingSender {
                let validated = GmailSignalEngine.validateChargeType(
                    aiType: candidate.chargeType,
                    subject: sender.latestSubject,
                    snippet: sender.latestSnippet,
                    bodyText: sender.bodyText
                )
                candidates[i].chargeType = validated.type
                // Adjust confidence if validation disagrees
                if validated.confidence < candidates[i].confidence {
                    candidates[i].confidence = (candidates[i].confidence + validated.confidence) / 2
                }
            }
        }

        return candidates
    }

    // MARK: - Phase 5: Deduplication (Normalized Names)

    private func deduplicateCandidates(_ candidates: [SubscriptionCandidate], existingNames: [String] = []) -> [SubscriptionCandidate] {
        // First: filter out candidates that match existing subscriptions (recurring only)
        let normalizedExisting = existingNames.map { GmailSignalEngine.normalizeName($0) }
        let filtered = candidates.filter { candidate in
            // Only filter recurring against existing — non-recurring are always new
            guard candidate.chargeType.isRecurring || candidate.chargeType == .unknown else { return true }
            let normalizedCandidate = GmailSignalEngine.normalizeName(candidate.name)
            return !normalizedExisting.contains { existing in
                GmailSignalEngine.namesMatch(normalizedCandidate, existing)
            }
        }

        // Then: group by (normalized name + charge type) for smarter dedup
        // This allows "OpenAI subscription" and "OpenAI API top-up" to coexist
        var grouped: [String: [SubscriptionCandidate]] = [:]
        for candidate in filtered {
            let key = "\(GmailSignalEngine.normalizeName(candidate.name))|\(candidate.chargeType.rawValue)"
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

// MARK: - Int Clamping Helper

private extension Int {
    func clamped(to range: ClosedRange<Int>, fallback: Int) -> Int {
        if self == 0 { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
