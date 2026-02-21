import SwiftUI
import SwiftData

struct SubscriptionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: SubscriptionViewModel

    var body: some View {
        List(selection: $viewModel.selectedSubscription) {
            if viewModel.filteredSubscriptions.isEmpty {
                ContentUnavailableView(
                    "No Subscriptions",
                    systemImage: "creditcard",
                    description: Text("Add your first subscription with the + button")
                )
            } else {
                ForEach(viewModel.groupedSubscriptions, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.items) { subscription in
                            SubscriptionRowView(subscription: subscription)
                                .tag(subscription)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        viewModel.deleteSubscription(subscription, context: modelContext)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search subscriptions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showingAddSheet = true
                } label: {
                    Label("Add Subscription", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showingAddSheet) {
            AddSubscriptionView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.loadSubscriptions(context: modelContext)
        }
    }
}
