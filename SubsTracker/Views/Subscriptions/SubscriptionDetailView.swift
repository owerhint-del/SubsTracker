import SwiftUI
import SwiftData

struct SubscriptionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var subscription: Subscription
    @AppStorage("currencyCode") private var currencyCode = "USD"
    @State private var isEditing = false

    // Editable fields
    @State private var editName: String = ""
    @State private var editCost: Double = 0
    @State private var editBillingCycle: BillingCycle = .monthly
    @State private var editRenewalDate: Date = Date()
    @State private var editCategory: SubscriptionCategory = .other
    @State private var editNotes: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header

                headerSection

                // Billing info
                billingSection

                // Usage info (for API-connected subscriptions)
                if subscription.isAPIConnected {
                    usageSection
                }

                // Notes
                if let notes = subscription.notes, !notes.isEmpty {
                    notesSection(notes)
                }
            }
            .padding()
        }
        .navigationTitle(subscription.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Save" : "Edit") {
                    if isEditing {
                        saveChanges()
                    } else {
                        startEditing()
                    }
                    isEditing.toggle()
                }
            }
        }
        .onAppear { prepareEditState() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 16) {
            Image(systemName: subscription.displayIcon)
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .frame(width: 60, height: 60)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Name", text: $editName)
                        .font(.title2)
                } else {
                    Text(subscription.name)
                        .font(.title2)
                        .fontWeight(.bold)
                }

                HStack(spacing: 8) {
                    Label(subscription.serviceProvider.displayName, systemImage: subscription.serviceProvider.iconSystemName)
                    if subscription.isAPIConnected {
                        Label("Connected", systemImage: "link.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var billingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Billing")
                .font(.headline)

            if isEditing {
                Form {
                    HStack {
                        Text("Cost")
                        TextField("0.00", value: $editCost, format: .currency(code: currencyCode))
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Cycle", selection: $editBillingCycle) {
                        ForEach(BillingCycle.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    Picker("Category", selection: $editCategory) {
                        ForEach(SubscriptionCategory.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    DatePicker("Next Renewal", selection: $editRenewalDate, displayedComponents: .date)
                }
                .formStyle(.grouped)
                .frame(height: 200)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(
                        title: "Cost",
                        value: CurrencyFormatter.format(subscription.cost, code: currencyCode),
                        icon: "dollarsign.circle",
                        color: .blue
                    )
                    StatCard(
                        title: "Monthly Equiv.",
                        value: CurrencyFormatter.format(subscription.monthlyCost, code: currencyCode),
                        icon: "calendar.badge.clock",
                        color: .purple
                    )
                    StatCard(
                        title: "Billing Cycle",
                        value: subscription.billing.displayName,
                        icon: "arrow.clockwise",
                        color: .orange
                    )
                    StatCard(
                        title: "Next Renewal",
                        value: subscription.renewalDate.formatted(date: .abbreviated, time: .omitted),
                        icon: "calendar",
                        color: .red
                    )
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage")
                .font(.headline)

            let records = subscription.usageRecords ?? []
            if records.isEmpty {
                ContentUnavailableView(
                    "No Usage Data",
                    systemImage: "chart.bar",
                    description: Text("Refresh to load usage data")
                )
                .frame(height: 100)
            } else {
                let totalTokens = records.reduce(0) { $0 + $1.totalTokens }
                let totalSessions = records.compactMap(\.sessionCount).reduce(0, +)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(
                        title: "Total Tokens",
                        value: formatTokenCount(totalTokens),
                        icon: "number",
                        color: .cyan
                    )
                    StatCard(
                        title: "Sessions",
                        value: "\(totalSessions)",
                        icon: "terminal",
                        color: .mint
                    )
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)

            if isEditing {
                TextEditor(text: $editNotes)
                    .frame(height: 80)
            } else {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Edit Helpers

    private func startEditing() {
        editName = subscription.name
        editCost = subscription.cost
        editBillingCycle = subscription.billing
        editRenewalDate = subscription.renewalDate
        editCategory = subscription.subscriptionCategory
        editNotes = subscription.notes ?? ""
    }

    // Pre-populate edit state on appear so it's never stale
    private func prepareEditState() {
        startEditing()
    }

    private func saveChanges() {
        subscription.name = editName
        subscription.cost = editCost
        subscription.billing = editBillingCycle
        subscription.subscriptionCategory = editCategory
        subscription.renewalDate = editRenewalDate
        subscription.notes = editNotes.isEmpty ? nil : editNotes
        try? modelContext.save()
    }
}
