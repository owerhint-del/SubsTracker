import Foundation

/// Shared currency formatting utility used by both the main app and widget.
/// Caches NumberFormatter per currency code to avoid repeated allocation.
/// NumberFormatter is ~50-100 KB per instance due to locale data.
enum CurrencyFormatter {
    private static var cache: [String: NumberFormatter] = [:]

    /// Format a monetary amount using the given ISO 4217 currency code.
    /// Automatically picks precision: 0 decimals for >= $100, 2 for normal, 4 for tiny amounts (< $0.01).
    static func format(_ amount: Double, code: String) -> String {
        let formatter = cachedFormatter(for: code)

        // Adjust fraction digits per amount
        if amount >= 100 {
            formatter.maximumFractionDigits = 0
        } else if abs(amount) > 0 && abs(amount) < 0.01 {
            formatter.maximumFractionDigits = 4
        } else {
            formatter.maximumFractionDigits = 2
        }

        return formatter.string(from: NSNumber(value: amount)) ?? "\(Int(amount))"
    }

    private static func cachedFormatter(for code: String) -> NumberFormatter {
        if let existing = cache[code] {
            return existing
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        cache[code] = formatter
        return formatter
    }
}
