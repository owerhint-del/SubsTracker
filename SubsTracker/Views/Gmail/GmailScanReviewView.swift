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

                Text("Found \(scanVM.candidates.count) Subscriptions")
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

            // Subscription list
            List {
                ForEach(Array(scanVM.candidates.enumerated()), id: \.element.id) { index, candidate in
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
                            Text(candidate.name)
                                .fontWeight(.medium)

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
            }
        }
        .frame(width: 600, height: 500)
    }

    private func confidenceColor(_ candidate: SubscriptionCandidate) -> Color {
        if candidate.confidence >= 0.9 { return .green }
        if candidate.confidence >= 0.7 { return .orange }
        return .red
    }
}
