import SwiftUI
import SwiftData

@main
struct SubsTrackerApp: App {
    @State private var subscriptionVM = SubscriptionViewModel()
    @StateObject private var manager = SubscriptionManager.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Subscription.self,
            UsageRecord.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // If the store is corrupted (e.g. schema changed), fall back to in-memory
            // so the app remains launchable. Data will be lost but app won't crash.
            print("SwiftData error: \(error). Falling back to in-memory store.")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create even in-memory ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(subscriptionVM: subscriptionVM)
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(width: 500, height: 650)
        }
        #endif
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var subscriptionVM: SubscriptionViewModel
    @StateObject private var manager = SubscriptionManager.shared
    @AppStorage("currencyCode") private var currencyCode = "USD"
    @AppStorage("refreshInterval") private var refreshInterval = 30
    @AppStorage("lastRefreshAt") private var lastRefreshAt: Double = 0

    enum NavigationItem: Hashable {
        case dashboard
        case claudeUsage
        case openAIUsage
        case subscription(Subscription)
    }

    @State private var selectedNavItem: NavigationItem? = .dashboard
    @State private var gmailScanVM = GmailScanViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailView
        }
        .overlay(alignment: .bottom) {
            if gmailScanVM.isScanning {
                ScanProgressBanner(progress: gmailScanVM.currentProgress)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: gmailScanVM.isScanning)
        .onAppear {
            subscriptionVM.loadSubscriptions(context: modelContext)
            manager.updateWidgetData(context: modelContext)
            Task {
                // Request notification permission only when enabled in settings
                if NotificationService.shared.isEnabled {
                    await NotificationService.shared.requestPermissionIfNeeded()
                }
                NotificationService.shared.pruneOldKeys()

                // Respect refreshInterval: 0 = never auto-refresh
                if refreshInterval > 0 {
                    let elapsed = Date().timeIntervalSince1970 - lastRefreshAt
                    let intervalSeconds = Double(refreshInterval) * 60
                    if elapsed >= intervalSeconds {
                        await manager.refreshAll(context: modelContext)
                        subscriptionVM.loadSubscriptions(context: modelContext)
                        lastRefreshAt = Date().timeIntervalSince1970
                    }
                }

                // Always schedule notifications from local data on startup,
                // regardless of whether auto-refresh ran (handles interval-not-elapsed case)
                await manager.scheduleNotifications(context: modelContext)

                await gmailScanVM.autoScanIfNeeded(context: modelContext)
                subscriptionVM.loadSubscriptions(context: modelContext)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedNavItem) {
            Section("Overview") {
                Label("Dashboard", systemImage: "chart.pie")
                    .tag(NavigationItem.dashboard)
            }

            Section("AI Usage") {
                Label("Claude Code", systemImage: "brain.head.profile")
                    .tag(NavigationItem.claudeUsage)

                Label("OpenAI", systemImage: "cpu")
                    .tag(NavigationItem.openAIUsage)
            }

            Section("Subscriptions") {
                ForEach(subscriptionVM.subscriptions) { sub in
                    Label {
                        HStack {
                            Text(sub.name)
                            Spacer()
                            Text(CurrencyFormatter.format(sub.monthlyCost, code: currencyCode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: sub.displayIcon)
                    }
                    .tag(NavigationItem.subscription(sub))
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            subscriptionVM.deleteSubscription(sub, context: modelContext)
                        }
                    }
                }

                Button {
                    subscriptionVM.showingAddSheet = true
                } label: {
                    Label("Add Subscription", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $subscriptionVM.showingAddSheet) {
            AddSubscriptionView(viewModel: subscriptionVM)
        }
    }

    // MARK: - Detail

    // Shared ViewModels so data isn't re-fetched on every sidebar click
    @State private var usageVM = UsageViewModel()

    @ViewBuilder
    private var detailView: some View {
        switch selectedNavItem {
        case .dashboard, .none:
            DashboardView()
        case .claudeUsage:
            ClaudeUsageView(viewModel: usageVM)
        case .openAIUsage:
            OpenAIUsageView(viewModel: usageVM)
        case .subscription(let sub):
            SubscriptionDetailView(subscription: sub)
        }
    }
}

// Make Subscription conform to Hashable for navigation
extension Subscription: Hashable {
    static func == (lhs: Subscription, rhs: Subscription) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
