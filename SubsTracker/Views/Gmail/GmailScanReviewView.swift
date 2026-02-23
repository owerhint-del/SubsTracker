import SwiftUI
import SwiftData

struct GmailScanReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Binding var scanVM: GmailScanViewModel
    var subscriptionVM: SubscriptionViewModel
    @AppStorage("currencyCode") private var currencyCode = "USD"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }

                Spacer()

                Text("Found \(scanVM.candidates.count) Charges")
                    .font(.headline)

                Spacer()

                Button("Add Selected (\(scanVM.selectedCount))") {
                    scanVM.addSelectedSubscriptions(viewModel: subscriptionVM, context: modelContext)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanVM.selectedCount == 0)
            }
            .padding()

            Divider()

            // Select controls
            HStack {
                Button("Select All") { scanVM.selectAll() }
                    .controlSize(.small)
                Button("Deselect All") { scanVM.deselectAll() }
                    .controlSize(.small)
                Spacer()
                Text("\(scanVM.selectedCount) of \(scanVM.candidates.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Sectioned list
            List {
                // Section 1: Recurring Subscriptions
                let recurring = filteredCandidates(for: .recurring)
                if !recurring.isEmpty {
                    Section {
                        ForEach(recurring, id: \.element.id) { index, candidate in
                            candidateRow(candidate: candidate, index: index)
                        }
                    } header: {
                        sectionHeader(
                            title: "Recurring Subscriptions",
                            icon: "arrow.triangle.2.circlepath",
                            count: recurring.count
                        )
                    }
                }

                // Section 2: Variable Top-ups
                let topups = filteredCandidates(for: .topups)
                if !topups.isEmpty {
                    Section {
                        ForEach(topups, id: \.element.id) { index, candidate in
                            candidateRow(candidate: candidate, index: index)
                        }
                    } header: {
                        sectionHeader(
                            title: "Variable API Top-ups",
                            icon: "gauge.with.dots.needle.33percent",
                            count: topups.count
                        )
                    }
                }

                // Section 3: One-time / Add-on Purchases
                let oneTime = filteredCandidates(for: .oneTime)
                if !oneTime.isEmpty {
                    Section {
                        ForEach(oneTime, id: \.element.id) { index, candidate in
                            candidateRow(candidate: candidate, index: index)
                        }
                    } header: {
                        sectionHeader(
                            title: "One-time & Add-on Purchases",
                            icon: "bag",
                            count: oneTime.count
                        )
                    }
                }

                // Section 4: Refunds (dimmed, deselected by default)
                let refunds = filteredCandidates(for: .refunds)
                if !refunds.isEmpty {
                    Section {
                        ForEach(refunds, id: \.element.id) { index, candidate in
                            candidateRow(candidate: candidate, index: index)
                                .opacity(0.5)
                        }
                    } header: {
                        sectionHeader(
                            title: "Refunds (excluded)",
                            icon: "arrow.uturn.backward",
                            count: refunds.count
                        )
                    }
                }
            }
        }
        .frame(width: 650, height: 550)
    }

    // MARK: - Section Filtering

    private enum SectionType {
        case recurring, topups, oneTime, refunds
    }

    private func filteredCandidates(for section: SectionType) -> [(offset: Int, element: SubscriptionCandidate)] {
        Array(scanVM.candidates.enumerated()).filter { _, candidate in
            switch section {
            case .recurring:
                return candidate.chargeType.isRecurring || candidate.chargeType == .unknown
            case .topups:
                return candidate.chargeType == .usageTopup
            case .oneTime:
                return candidate.chargeType == .addonCredits || candidate.chargeType == .oneTimePurchase
            case .refunds:
                return candidate.chargeType == .refundOrReversal
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("(\(count))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Candidate Row

    private func candidateRow(candidate: SubscriptionCandidate, index: Int) -> some View {
        HStack(spacing: 12) {
            // Checkbox
            Image(systemName: candidate.isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(candidate.isSelected ? .blue : .secondary)
                .font(.title3)
                .onTapGesture {
                    scanVM.toggleSelection(at: index)
                }

            // Category icon
            Image(systemName: candidate.category.iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            // Name + details
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.name)
                        .fontWeight(.medium)

                    // Charge type badge
                    chargeTypeBadge(candidate.chargeType)
                }

                HStack(spacing: 8) {
                    Text(CurrencyFormatter.format(candidate.cost, code: currencyCode))
                        .font(.caption)
                    Text("/")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(candidate.billingCycle.displayName.lowercased())
                        .font(.caption)

                    if let date = candidate.renewalDate {
                        Text("renews \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    // Cost source badge
                    Text(candidate.costSourceLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(candidate.isEstimated ? Color.yellow.opacity(0.15) : Color.blue.opacity(0.15))
                        .foregroundStyle(candidate.isEstimated ? .orange : .blue)
                        .clipShape(Capsule())

                    if let evidence = candidate.evidence, !evidence.isEmpty {
                        Text(evidence)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if let notes = candidate.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Confidence badge
            Text(candidate.confidenceLabel)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(confidenceColor(candidate).opacity(0.15))
                .foregroundStyle(confidenceColor(candidate))
                .clipShape(Capsule())

            // Source count
            if candidate.sourceEmailCount > 1 {
                Text("\(candidate.sourceEmailCount) emails")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func chargeTypeBadge(_ type: ChargeType) -> some View {
        Text(type.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(chargeTypeColor(type).opacity(0.12))
            .foregroundStyle(chargeTypeColor(type))
            .clipShape(Capsule())
    }

    private func chargeTypeColor(_ type: ChargeType) -> Color {
        switch type {
        case .recurringSubscription: return .blue
        case .usageTopup: return .purple
        case .addonCredits: return .teal
        case .oneTimePurchase: return .indigo
        case .refundOrReversal: return .red
        case .unknown: return .gray
        }
    }

    private func confidenceColor(_ candidate: SubscriptionCandidate) -> Color {
        if candidate.confidence >= 0.9 { return .green }
        if candidate.confidence >= 0.7 { return .orange }
        return .red
    }
}
