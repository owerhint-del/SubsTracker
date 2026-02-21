import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct SubsTrackerEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

// MARK: - Timeline Provider

struct SubsTrackerProvider: TimelineProvider {
    func placeholder(in context: Context) -> SubsTrackerEntry {
        SubsTrackerEntry(date: .now, data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SubsTrackerEntry) -> Void) {
        let entry = SubsTrackerEntry(date: .now, data: WidgetData.load())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SubsTrackerEntry>) -> Void) {
        let data = WidgetData.load()
        let entry = SubsTrackerEntry(date: .now, data: data)

        // Refresh every 30 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget Configuration

struct SubsTrackerWidget: Widget {
    let kind = "SubsTrackerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SubsTrackerProvider()) { entry in
            SubsTrackerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("SubsTracker")
        .description("Monthly spending and upcoming renewals at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
