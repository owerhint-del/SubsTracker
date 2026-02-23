import Foundation

enum AppGroupConstants {
    /// App Group identifier shared between the main app and widget extension.
    /// When widget is disabled (Personal Team mode), UserDefaults(suiteName:) returns nil
    /// and widget data operations silently no-op. This is the expected fallback.
    static let suiteName = "group.com.owerhintdel.substracker"
}
