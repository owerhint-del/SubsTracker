import Foundation

/// Cached date formatters to avoid repeated allocation.
/// DateFormatter is expensive (~50-100 KB per instance with locale data).
enum SharedDateFormatter {
    /// Cached "yyyy-MM-dd" formatter — used by all parsedDate computed properties.
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Cached ISO8601 formatter with fractional seconds.
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Cached ISO8601 formatter without fractional seconds (fallback).
    static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
