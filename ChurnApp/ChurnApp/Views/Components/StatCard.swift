//
//  StatCard.swift
//  ChurnApp
//
//  A labeled stat tile for dashboard-style summaries — the Home earnings
//  carousel ("YTD Earnings", "Pending Bonuses", "All-Time Earnings", etc.).
//  Two flavors: `StatCard` for money (backed by MoneyText, the common case)
//  and `GenericStatCard` for a non-money value (e.g. "3 accounts").
//

import CoreData
import SwiftUI

/// Money-valued stat tile. This is the one most feature views want — it
/// wraps `MoneyText` so currency formatting stays centralized.
struct StatCard: View {

    let label: String
    let amount: Decimal
    var subtitle: String? = nil
    /// Positive/negative/status-based tint, forwarded straight to `MoneyText`.
    var valueColor: Color? = nil
    /// Small up/down indicator next to the subtitle, e.g. "+12% vs last month".
    var trend: Trend? = nil

    enum Trend {
        case up, down, neutral

        var systemImageName: String {
            switch self {
            case .up: "arrow.up.right"
            case .down: "arrow.down.right"
            case .neutral: "minus"
            }
        }

        var color: Color {
            switch self {
            case .up: .green
            case .down: .red
            case .neutral: .secondary
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            MoneyText(amount: amount, size: .large, color: valueColor)

            if subtitle != nil || trend != nil {
                HStack(spacing: 4) {
                    if let trend {
                        Image(systemName: trend.systemImageName)
                            .foregroundStyle(trend.color)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // `.regularMaterial` gives the card native Liquid-Glass-era depth
        // (frosted, adapts to light/dark) without hand-rolling a shadow +
        // solid fill combo. `containerShape` keeps hit-testing/clipping
        // rectangular-rounded for whatever taps the card (e.g. NavigationLink).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Non-money stat tile — same chrome as `StatCard`, but for a plain value
/// (a count, a percentage, a date) that doesn't belong through `MoneyText`.
struct GenericStatCard: View {

    let label: String
    let value: String
    var subtitle: String? = nil
    var valueColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(valueColor ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Previews

#Preview("Money stat cards") {
    ScrollView(.horizontal) {
        HStack(spacing: 12) {
            StatCard(label: "YTD Earnings", amount: 850, subtitle: "vs $600 last year", trend: .up)
            StatCard(label: "Pending Bonuses", amount: 750, valueColor: .orange)
            StatCard(label: "All-Time Earnings", amount: 4230.50, subtitle: "12 accounts")
        }
        .padding()
    }
}

#Preview("Generic stat card") {
    HStack(spacing: 12) {
        GenericStatCard(label: "Active Accounts", value: "3", subtitle: "1 prospecting")
        GenericStatCard(label: "Days Until Bonus", value: "21", valueColor: .blue)
    }
    .padding()
}

#Preview("Real earnings data") {
    // Sums real seeded accounts rather than hardcoding a number, so the
    // preview breaks visibly if the accessor names ever drift.
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []
    let posted = accounts.filter { $0.hasBonusPosted }.reduce(Decimal(0)) { $0 + $1.bonusAmountDecimal }
    let pending = accounts.filter { !$0.hasBonusPosted && $0.accountStatusValue != .closed }
        .reduce(Decimal(0)) { $0 + $1.bonusAmountDecimal }

    return HStack(spacing: 12) {
        StatCard(label: "Earned", amount: posted, valueColor: .green)
        StatCard(label: "Pending", amount: pending, valueColor: .orange)
    }
    .padding()
}

#Preview("Dark mode") {
    HStack(spacing: 12) {
        StatCard(label: "YTD Earnings", amount: 850, trend: .up)
        GenericStatCard(label: "Active Accounts", value: "3")
    }
    .padding()
    .preferredColorScheme(.dark)
}
