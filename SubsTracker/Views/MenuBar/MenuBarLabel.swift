import SwiftUI

/// The label shown in the macOS menu bar status area.
/// Shows icon + compact usage text when enabled, icon-only when disabled.
struct MenuBarLabel: View {
    var usageVM: UsageViewModel
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("currencyCode") private var currencyCode = "USD"

    var body: some View {
        let label = MenuBarLabelEngine.formatLabel(
            claudeUtilization: usageVM.claudeAPIUsage?.fiveHour?.utilization,
            claudeExtraDollars: claudeExtraDollars,
            openAICost: usageVM.hasOpenAIKey ? usageVM.openAITotalCost : nil,
            codexUtilization: usageVM.codexRateLimits?.sessionUtilization,
            currencyCode: currencyCode,
            isEnabled: menuBarEnabled
        )
        if label.isEmpty {
            Label("SubsTracker", systemImage: "chart.line.uptrend.xyaxis")
        } else {
            Label(label, systemImage: "chart.line.uptrend.xyaxis")
        }
    }

    private var claudeExtraDollars: Double? {
        guard let extra = usageVM.claudeAPIUsage?.extraUsage,
              extra.isEnabled, extra.usedDollars > 0 else { return nil }
        return extra.usedDollars
    }
}
