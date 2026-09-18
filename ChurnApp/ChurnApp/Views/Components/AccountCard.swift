//
//  AccountCard.swift
//  ChurnApp
//
//  Card row summarizing a single Account — bank name, status badge, bonus
//  amount, and whichever date is currently most relevant. This is the
//  single most-reused component: both the Accounts tab (full list) and
//  Home (dense summary strip) build on it, so it supports a `compact` mode
//  rather than each screen rolling its own variant of the same layout.
//

import CoreData
import SwiftUI

struct AccountCard: View {

    let account: Account

    /// Dense mode: single-line, smaller type, for Home's "recent accounts"
    /// strip where several cards need to fit without scrolling forever.
    /// Full mode: multi-line, larger type, for the primary Accounts list.
    var compact: Bool = false

    /// Round 3: shows opening date, expected bonus date, and an
    /// elapsed-time progress bar in the full layout — the Accounts tab
    /// wants this richer per-row info, Home's compact strip doesn't have
    /// room for it. No effect in `compact` mode or on non-churn accounts
    /// (there's no bonus timeline to show progress toward).
    var showProgress: Bool = false

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .padding(compact ? 12 : 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Full layout

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.bankName)
                        .font(.headline)
                    Label(account.accountTypeValue.displayName, systemImage: account.accountTypeValue.systemImageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if account.isChurnAccount {
                    StatusBadge(status: account.accountStatusValue)
                } else {
                    GenericStatusBadge(text: "Home Account", color: .blue, systemImageName: "house.fill")
                }
            }

            if account.isChurnAccount {
                HStack(alignment: .firstTextBaseline) {
                    MoneyText(amount: account.bonusAmountDecimal, size: .medium, color: moneyColor)

                    Spacer()

                    if let keyDate {
                        Label(keyDate.formatted(date: .abbreviated, time: .omitted), systemImage: keyDateSymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showProgress {
                    timelineDetail
                }
            } else if let person = account.person {
                // Non-churn row: no bonus/timeline to show, so the second
                // line just surfaces the owner instead of leaving dead
                // space where the money/date row would otherwise sit.
                Label(person.name, systemImage: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Opening date, expected bonus date, and a simple elapsed-time bar
    /// between them. Native `ProgressView` — no custom drawing. Only shown
    /// when there's an `expectedBonusDate` to measure progress toward;
    /// without one there's nothing to show a bar for.
    @ViewBuilder
    private var timelineDetail: some View {
        if let expected = account.expectedBonusDate {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: elapsedFraction(from: account.openingDate, to: expected))
                    .tint(account.accountStatusValue.color)

                HStack {
                    Text("Opened \(account.openingDate.formatted(date: .abbreviated, time: .omitted))")
                    Spacer()
                    Text("Expected \(expected.formatted(date: .abbreviated, time: .omitted))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Fraction of the way from `start` to `end`, clamped to [0, 1]. `end`
    /// at or before `start` reports 1.0 (already "due") rather than dividing
    /// by zero/going negative.
    private func elapsedFraction(from start: Date, to end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        let elapsed = Date().timeIntervalSince(start)
        return min(max(elapsed / total, 0), 1)
    }

    // MARK: - Compact layout

    private var compactBody: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.bankName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let keyDate {
                    Text(keyDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            MoneyText(amount: account.bonusAmountDecimal, size: .small, color: moneyColor)
            StatusBadge(status: account.accountStatusValue)
        }
        // Compact rows still need a reasonable minimum width so the status
        // badge + money don't get crushed when several cards sit in an
        // `HStack` inside a horizontal ScrollView on Home.
        .frame(minWidth: 220)
    }

    // MARK: - Derived display data

    /// Green once the bonus has actually posted (real money, confirmed);
    /// otherwise the default text color, since a projected bonus is still
    /// just a number until `hasBonusPosted` is true.
    private var moneyColor: Color? {
        account.hasBonusPosted ? .green : nil
    }

    /// The single most relevant date for the account's current status:
    /// closed accounts show when they closed, posted bonuses show when they
    /// posted, everything else shows the expected bonus date (the thing the
    /// user is waiting on).
    private var keyDate: Date? {
        switch account.accountStatusValue {
        case .closed: account.closedDate ?? account.actualBonusDate
        case .maintaining: account.actualBonusDate ?? account.expectedBonusDate
        case .open, .prospecting: account.expectedBonusDate
        }
    }

    private var keyDateSymbol: String {
        switch account.accountStatusValue {
        case .closed: "xmark.circle"
        case .maintaining: "checkmark.circle"
        case .open, .prospecting: "calendar"
        }
    }
}

// MARK: - Previews

#Preview("Full — all statuses") {
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []

    return ScrollView {
        VStack(spacing: 12) {
            ForEach(accounts, id: \.id) { account in
                AccountCard(account: account)
            }
        }
        .padding()
    }
}

#Preview("Full with progress — churn + non-churn") {
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []

    return ScrollView {
        VStack(spacing: 12) {
            ForEach(accounts, id: \.id) { account in
                AccountCard(account: account, showProgress: true)
            }
        }
        .padding()
    }
}

#Preview("Compact — Home strip") {
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []

    return ScrollView(.horizontal) {
        HStack(spacing: 10) {
            ForEach(accounts, id: \.id) { account in
                AccountCard(account: account, compact: true)
            }
        }
        .padding()
    }
}

#Preview("Single card, dark mode") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?.first

    return Group {
        if let account {
            AccountCard(account: account)
                .padding()
        }
    }
    .preferredColorScheme(.dark)
}
