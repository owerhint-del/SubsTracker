import Foundation
import SwiftData

@MainActor
@Observable
final class GmailScanViewModel {
    var isScanning = false
    var scanProgress = ScanProgress()
    var candidates: [SubscriptionCandidate] = []
    var errorMessage: String?
    var showingReview = false

    private let scanner = GmailScannerService.shared
    private static let lastScanDateKey = "lastGmailScanDate"

    // MARK: - Last Scan Date (shared via UserDefaults)

    var lastScanDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastScanDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastScanDateKey) }
    }

    var lastScanDateFormatted: String? {
        guard let date = lastScanDate else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Auto-Scan

    /// Runs a scan automatically if Gmail is connected, OpenAI key exists,
    /// and 3+ days have passed since the last scan. Auto-adds new subscriptions
    /// and updates existing ones with fresh renewal dates.
    func autoScanIfNeeded(context: ModelContext) async {
        guard GmailOAuthService.shared.isConnected else {
            NSLog("[AutoScan] Gmail not connected — skipping")
            return
        }

        let openAIKey = KeychainService.shared.retrieve(key: KeychainService.openAIAPIKey)
        guard let key = openAIKey, !key.isEmpty else {
            NSLog("[AutoScan] OpenAI key missing — skipping")
            return
        }

        if let lastDate = lastScanDate {
            let days = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
            guard days >= 3 else {
                NSLog("[AutoScan] Last scan was \(days) days ago — skipping (need 3+)")
                return
            }
        }

        NSLog("[AutoScan] Starting auto-scan...")
        isScanning = true
        errorMessage = nil

        do {
            // Fetch active subscription names so the AI skips them.
            // Canceled subs are excluded so the AI re-analyzes them (enables reactivation detection).
            let descriptor = FetchDescriptor<Subscription>()
            let existing = (try? context.fetch(descriptor)) ?? []
            let existingNames = existing.filter(\.isActive).map(\.name)

            let results = try await scanner.scanForSubscriptions(existingNames: existingNames)
            isScanning = false
            lastScanDate = Date()

            // Auto-scan: only process recurring subscriptions (user-chosen policy)
            let recurringOnly = results.filter { $0.chargeType.isRecurring || $0.chargeType == .unknown }
            NSLog("[AutoScan] Scan complete — found \(results.count) total, \(recurringOnly.count) recurring")

            if !recurringOnly.isEmpty {
                addOrUpdateSubscriptions(recurringOnly, context: context)
                NSLog("[AutoScan] Recurring subscriptions added/updated")
            }
        } catch {
            isScanning = false
            errorMessage = "Auto-scan failed: \(error.localizedDescription)"
            NSLog("[AutoScan] Error: %@", error.localizedDescription)
        }
    }

    /// Adds new subscriptions and updates existing ones (by name match).
    /// New subs get inserted; existing subs get their renewal date and cost refreshed.
    /// Canceled candidates auto-mark existing matches as canceled.
    private func addOrUpdateSubscriptions(_ candidates: [SubscriptionCandidate], context: ModelContext) {
        let descriptor = FetchDescriptor<Subscription>()
        let existing = (try? context.fetch(descriptor)) ?? []

        for candidate in candidates {
            if let match = existing.first(where: {
                GmailSignalEngine.namesMatch($0.name, candidate.name)
            }) {
                // If candidate is canceled with high confidence, mark existing sub as canceled
                if candidate.subscriptionStatus == .canceled && candidate.confidence >= 0.85 {
                    match.subscriptionStatus = .canceled
                    match.statusChangedAt = candidate.statusEffectiveDate ?? Date()
                    NSLog("[AutoScan] Marked '%@' as canceled", match.name)
                    continue
                }

                // If existing sub is canceled but incoming candidate is active → reactivation
                if match.subscriptionStatus == .canceled && candidate.subscriptionStatus == .active && candidate.confidence >= 0.85 {
                    match.subscriptionStatus = .active
                    match.statusChangedAt = candidate.statusEffectiveDate ?? Date()
                    NSLog("[AutoScan] Reactivated '%@'", match.name)
                }

                // Update existing subscription with fresh data from emails
                if let renewalDate = candidate.renewalDate {
                    match.renewalDate = renewalDate
                }
                if candidate.cost > 0 {
                    match.cost = candidate.cost
                    match.billingCycle = candidate.billingCycle.rawValue
                }
            } else {
                // Don't insert new canceled subscriptions
                if candidate.subscriptionStatus == .canceled { continue }

                // Insert new subscription
                let sub = Subscription(
                    name: candidate.name,
                    provider: .manual,
                    cost: candidate.cost,
                    billingCycle: candidate.billingCycle,
                    renewalDate: candidate.renewalDate ?? Date(),
                    category: candidate.category,
                    notes: candidate.notes
                )
                context.insert(sub)
            }
        }

        try? context.save()
    }

    // MARK: - Scan

    func startScan(context: ModelContext? = nil) async {
        isScanning = true
        errorMessage = nil
        candidates = []

        do {
            // Pass active subscription names so AI skips them (canceled subs excluded for reactivation detection)
            var existingNames: [String] = []
            if let context {
                let descriptor = FetchDescriptor<Subscription>()
                existingNames = ((try? context.fetch(descriptor)) ?? []).filter(\.isActive).map(\.name)
            }
            let results = try await scanner.scanForSubscriptions(existingNames: existingNames)
            candidates = results
            isScanning = false
            lastScanDate = Date()

            if results.isEmpty {
                errorMessage = "No charges found in your emails"
            } else {
                // Auto-deselect refunds and canceled subscriptions (shown for info but not saved by default)
                for i in candidates.indices {
                    if candidates[i].chargeType == .refundOrReversal {
                        candidates[i].isSelected = false
                    }
                    if candidates[i].subscriptionStatus == .canceled {
                        candidates[i].isSelected = false
                    }
                }
                showingReview = true
            }
        } catch let error as GmailOAuthError {
            isScanning = false
            switch error {
            case .apiError(let code, let message):
                if message.contains("SCOPE_INSUFFICIENT") || message.contains("insufficientPermissions") {
                    errorMessage = "Gmail permissions missing. Please disconnect and reconnect Gmail, then approve all permissions on Google's consent screen."
                } else {
                    errorMessage = "Gmail API error (\(code)). Try disconnecting and reconnecting."
                }
            default:
                errorMessage = error.localizedDescription
            }
        } catch {
            isScanning = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Progress (forwarded from scanner)

    var currentProgress: ScanProgress {
        scanner.progress
    }

    // MARK: - Filtered Views by Charge Type

    var recurringCandidates: [SubscriptionCandidate] {
        candidates.filter { $0.chargeType.isRecurring || $0.chargeType == .unknown }
    }

    var nonRecurringCandidates: [SubscriptionCandidate] {
        candidates.filter { $0.chargeType.isNonRecurring }
    }

    var canceledCandidates: [SubscriptionCandidate] {
        candidates.filter { $0.subscriptionStatus == .canceled && $0.chargeType != .refundOrReversal }
    }

    var refundCandidates: [SubscriptionCandidate] {
        candidates.filter { $0.chargeType == .refundOrReversal }
    }

    // MARK: - Selection

    func toggleSelection(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        candidates[index].isSelected.toggle()
    }

    func selectAll() {
        for i in candidates.indices {
            // Don't select refunds or canceled subscriptions
            if candidates[i].chargeType != .refundOrReversal
                && candidates[i].subscriptionStatus != .canceled {
                candidates[i].isSelected = true
            }
        }
    }

    func deselectAll() {
        for i in candidates.indices {
            candidates[i].isSelected = false
        }
    }

    var selectedCount: Int {
        candidates.filter(\.isSelected).count
    }

    // MARK: - Add to SwiftData (split by charge type)

    func addSelectedSubscriptions(viewModel: SubscriptionViewModel, context: ModelContext) {
        let selected = candidates.filter(\.isSelected)

        for candidate in selected {
            // Skip canceled recurring subscriptions — don't insert as active
            if candidate.subscriptionStatus == .canceled { continue }

            if candidate.chargeType.isRecurring || candidate.chargeType == .unknown {
                // Recurring → Subscription model
                viewModel.addSubscription(
                    name: candidate.name,
                    provider: .manual,
                    cost: candidate.cost,
                    billingCycle: candidate.billingCycle,
                    renewalDate: candidate.renewalDate ?? Date(),
                    category: candidate.category,
                    notes: candidate.notes,
                    context: context
                )
            } else if candidate.chargeType.isNonRecurring {
                // Non-recurring → OneTimePurchase model
                let purchase = OneTimePurchase(
                    name: candidate.name,
                    amount: candidate.cost,
                    date: candidate.renewalDate ?? Date(),
                    category: candidate.category,
                    notes: candidate.notes
                )
                context.insert(purchase)
            }
            // Refunds are skipped (not saved)
        }

        try? context.save()

        // Close review after adding
        showingReview = false
        candidates = []
    }
}
