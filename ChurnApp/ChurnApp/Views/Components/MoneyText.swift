//
//  MoneyText.swift
//  ChurnApp
//
//  Every dollar amount in the app should render through this view rather
//  than hand-formatting a `Decimal` at each call site — one place to get
//  the `NumberFormatter` / currency style right, and one place to change it
//  (e.g. if the app ever needs multi-currency support).
//

import CoreData
import SwiftUI

/// Displays a `Decimal` as localized currency, e.g. "$1,234.56".
///
/// Money is always `Decimal` here — never `Double` — matching the typed
/// `...Decimal` accessors on the Core Data entities (see CLAUDE.md). Callers
/// should pass `account.bonusAmountDecimal`, not the raw `NSDecimalNumber`.
struct MoneyText: View {

    /// Preset sizes used across the app so dashboard/list/detail money all
    /// look consistent without every call site picking its own font.
    enum Size {
        /// Hero numbers — earnings carousel headline figures.
        case large
        /// Default — list rows, card values.
        case medium
        /// De-emphasized — subtitles, secondary figures next to a larger one.
        case small

        var font: Font {
            switch self {
            case .large: .system(.largeTitle, design: .rounded, weight: .bold)
            case .medium: .system(.body, design: .rounded, weight: .semibold)
            case .small: .system(.footnote, design: .rounded, weight: .medium)
            }
        }
    }

    let amount: Decimal
    var size: Size = .medium
    /// Overrides the default (primary) color — e.g. green for a posted
    /// bonus, red for a negative adjustment. `nil` keeps the default text
    /// color so callers don't have to think about color unless the status
    /// actually calls for one.
    var color: Color? = nil

    var body: some View {
        Text(amount, format: .currency(code: currencyCode))
            .font(size.font)
            .foregroundStyle(color ?? .primary)
            // Currency digits should never line-wrap or shrink unpredictably
            // mid-row; this keeps a StatCard's value visually stable even
            // when the surrounding layout is tight.
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Locale's currency, falling back to USD. The app is US-only for this
    /// build (no multi-currency accounts in the data model), but driving it
    /// off `Locale.current` rather than hardcoding "USD" costs nothing and
    /// means formatting still adapts to grouping/decimal separators for
    /// other US-locale variants.
    private var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }
}

// MARK: - Previews

#Preview("Sizes") {
    VStack(alignment: .leading, spacing: 16) {
        MoneyText(amount: 1234.56, size: .large)
        MoneyText(amount: 1234.56, size: .medium)
        MoneyText(amount: 1234.56, size: .small)
    }
    .padding()
}

#Preview("Colors") {
    VStack(alignment: .leading, spacing: 16) {
        MoneyText(amount: 300, size: .medium, color: .green)
        MoneyText(amount: 0, size: .medium)
        MoneyText(amount: -45.99, size: .medium, color: .red)
    }
    .padding()
}

#Preview("Real account data") {
    // Pull from the seeded preview store rather than hand-writing another
    // fixture, so this reflects the actual shape/precision of stored money.
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []

    return VStack(alignment: .leading, spacing: 12) {
        ForEach(accounts, id: \.id) { account in
            MoneyText(amount: account.bonusAmountDecimal, size: .medium)
        }
    }
    .padding()
}

#Preview("Dark mode") {
    VStack(alignment: .leading, spacing: 16) {
        MoneyText(amount: 1234.56, size: .large)
        MoneyText(amount: 300, size: .medium, color: .green)
    }
    .padding()
    .preferredColorScheme(.dark)
}
