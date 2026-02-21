import SwiftUI

struct AddSubscriptionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SubscriptionViewModel

    @State private var name = ""
    @State private var provider: ServiceProvider = .manual
    @State private var cost: Double = 0
    @State private var billingCycle: BillingCycle = .monthly
    @State private var renewalDate = Date()
    @State private var category: SubscriptionCategory = .other
    @State private var notes = ""

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("Add Subscription")
                    .font(.headline)
                Spacer()
                Button("Save") { save() }
                    .disabled(name.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            Form {
                Section("Details") {
                    TextField("Service Name", text: $name)
                    Picker("Provider", selection: $provider) {
                        ForEach(ServiceProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    Picker("Category", selection: $category) {
                        ForEach(SubscriptionCategory.allCases) { c in
                            Label(c.rawValue, systemImage: c.iconSystemName).tag(c)
                        }
                    }
                }

                Section("Billing") {
                    HStack {
                        Text("Cost")
                        TextField("0.00", value: $cost, format: .currency(code: "USD"))
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Billing Cycle", selection: $billingCycle) {
                        ForEach(BillingCycle.allCases) { cycle in
                            Text(cycle.displayName).tag(cycle)
                        }
                    }
                    DatePicker("Next Renewal", selection: $renewalDate, displayedComponents: .date)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(height: 60)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 480)
    }

    private func save() {
        viewModel.addSubscription(
            name: name,
            provider: provider,
            cost: cost,
            billingCycle: billingCycle,
            renewalDate: renewalDate,
            category: category,
            notes: notes.isEmpty ? nil : notes,
            context: modelContext
        )
        dismiss()
    }
}
