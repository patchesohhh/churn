//
//  HomeView.swift
//  ChurnApp
//
//  The Home tab: a dashboard that answers "how am I doing, and what needs
//  attention right now" in a single scroll. Built directly from the "Home
//  Screen Layout" spec in `docs/project notes/UI Summary (initial).txt`,
//  simplified per CLAUDE.md's condensed version.
//
//  Per CLAUDE.md's hybrid architecture, this view fetches its own data via
//  `@FetchRequest` and feeds plain arrays into `CalculationService` directly
//  — no `ChurningStore` exists yet, and a dashboard that's the only consumer
//  of these numbers doesn't justify adding one. If a second view (e.g.
//  Calendar) ends up needing the same YTD/pending/all-time figures, that's
//  the trigger to extract `ChurningStore` — not before.
//

import CoreData
import SwiftUI

struct HomeView: View {

    // MARK: - Fetches

    /// All non-archived accounts. Home needs every status at once (earnings
    /// math spans all of them, Active Promotions/Maintaining each filter a
    /// different subset), so one broad fetch beats several narrower ones.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.openingDate, ascending: false)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var accounts: FetchedResults<Account>

    /// Only *scheduled* (not yet posted/skipped) deposits, soonest first —
    /// exactly what the "Next Paychecks" preview needs, across both people.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DirectDeposit.scheduledDate, ascending: true)],
        predicate: NSPredicate(format: "status == %@", DirectDepositStatus.scheduled.rawValue)
    )
    private var upcomingDeposits: FetchedResults<DirectDeposit>

    @Environment(\.managedObjectContext) private var viewContext

    @State private var isPresentingAddAccount = false

    // MARK: - Derived data

    private var activePromotions: [Account] {
        accounts.filter {
            let status = $0.accountStatusValue
            return (status == .open || status == .prospecting) && $0.actualBonusDate == nil
        }
    }

    private var maintainingAccounts: [Account] {
        accounts.filter { $0.accountStatusValue == .maintaining }
    }

    private var nextPaychecks: [DirectDeposit] {
        Array(upcomingDeposits.prefix(3))
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    EmptyStateView(
                        systemImageName: "banknote",
                        title: "No Accounts Yet",
                        message: "Add a bank account to start tracking a bonus.",
                        actionTitle: "Add Account"
                    ) {
                        isPresentingAddAccount = true
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            earningsCarousel

                            if !activePromotions.isEmpty {
                                activePromotionsSection
                            }

                            if !nextPaychecks.isEmpty {
                                nextPaychecksSection
                            }

                            if !maintainingAccounts.isEmpty {
                                maintainingSection
                            }
                        }
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    quickActionsMenu
                }
            }
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(account: account)
            }
            .sheet(isPresented: $isPresentingAddAccount) {
                AddEditAccountView(account: nil)
            }
        }
    }

    // MARK: - 1. Earnings carousel

    /// Swipeable page-style carousel of the three headline money metrics, per
    /// the source doc's "Earnings Carousel (Top)" spec. `TabView(.page)`
    /// reads closer to the original intent than a static HStack, and is
    /// still fully native.
    private var earningsCarousel: some View {
        TabView {
            StatCard(
                label: "YTD Earnings",
                amount: CalculationService.ytdEarnings(accounts: Array(accounts)),
                subtitle: "Money earned this year",
                valueColor: .green
            )
            .padding(.horizontal)

            StatCard(
                label: "Pending Bonuses",
                amount: CalculationService.pendingBonusesTotal(accounts: Array(accounts)),
                subtitle: "Still being worked on",
                valueColor: .orange
            )
            .padding(.horizontal)

            StatCard(
                label: "All-Time Earnings",
                amount: CalculationService.allTimeEarnings(accounts: Array(accounts)),
                subtitle: "Lifetime churning total"
            )
            .padding(.horizontal)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        // Fixed height: `TabView` won't size itself to a `StatCard`'s
        // intrinsic height the way a plain VStack would, and the page dots
        // need a little breathing room below the card.
        .frame(height: 150)
    }

    // MARK: - 2. Active promotions

    /// Accounts still working toward a bonus that hasn't posted — the "needs
    /// attention" list, prioritized right under the earnings headline per the
    /// source doc's rationale.
    private var activePromotionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(
                title: "Active Promotions",
                subtitle: "\(activePromotions.count) in progress"
            )
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(activePromotions, id: \.id) { account in
                        NavigationLink(value: account) {
                            AccountCard(account: account, compact: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 3. Next paychecks mini-preview

    private var nextPaychecksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(
                title: "Next Paychecks",
                actionTitle: "View full schedule"
            ) {
                // TODO: navigate to the Calendar tab once it's wired up by
                // the concurrently-built Calendar feature / tab-bar
                // integration pass. Intentionally a no-op for now.
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                ForEach(nextPaychecks, id: \.id) { deposit in
                    NextPaycheckRow(deposit: deposit)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - 4. Maintaining (collapsed by default)

    /// Accounts whose bonus already posted and are just waiting out the
    /// fee-free window before closing. Collapsed by default via native
    /// `DisclosureGroup` — progressive disclosure, per the source doc's
    /// rationale ("don't clutter home screen with non-urgent items").
    private var maintainingSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(maintainingAccounts, id: \.id) { account in
                    MaintainingRow(account: account)
                }
            }
            .padding(.top, 8)
        } label: {
            SectionHeaderView(
                title: "Maintaining",
                subtitle: "\(maintainingAccounts.count) waiting out the clock"
            )
        }
        .padding(.horizontal)
    }

    // MARK: - 5. Quick actions

    /// Native `Menu` behind a `+` toolbar button — a clean fit for a small
    /// set of dashboard-level actions without a custom floating-button
    /// overlay.
    private var quickActionsMenu: some View {
        Menu {
            Button {
                isPresentingAddAccount = true
            } label: {
                Label("Add Account", systemImage: "plus.circle")
            }

            Button {
                // TODO: wire once a "log bonus received" flow exists —
                // likely just editing an account's actualBonusDate. Out of
                // scope for this pass; Accounts feature owns that form.
            } label: {
                Label("Log Bonus Received", systemImage: "checkmark.circle")
            }

            Button {
                // TODO: wire once a dedicated DD-update flow exists (or link
                // into AccountDetailView's DD editor once that lands).
            } label: {
                Label("Update Direct Deposit", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Label("Quick Actions", systemImage: "plus")
        }
    }
}

// MARK: - Next paycheck row

/// One row in the Next Paychecks preview: date, amount, and which
/// account/bank the deposit is routed to.
private struct NextPaycheckRow: View {

    let deposit: DirectDeposit

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(deposit.account?.bankName ?? "Unassigned")
                    .font(.subheadline.weight(.semibold))
                if let personName = deposit.person?.name {
                    Text(personName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(amount: deposit.amountDecimal, size: .small)
                Text(deposit.scheduledDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Visual indicator that this DD series is about to complete —
            // last deposit in its account's series, per the source doc's
            // "visual indicator if a DD series is about to complete" note.
            if let account = deposit.account {
                let progress = CalculationService.directDepositProgress(for: account)
                if progress.total > 0 && progress.completed == progress.total - 1 {
                    Image(systemName: "flag.checkered.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Final deposit in this series")
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Maintaining row

/// One row in the collapsed Maintaining section: bank name + days until
/// safe to close.
private struct MaintainingRow: View {

    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.bankName)
                    .font(.subheadline.weight(.semibold))
                MoneyText(amount: account.bonusAmountDecimal, size: .small, color: .green)
            }

            Spacer()

            if let safeToCloseDate {
                let days = CalculationService.daysUntil(safeToCloseDate)
                GenericStatCardDaysLabel(days: days)
            } else {
                Text("No waiting window set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The data model has no dedicated "safe to close" date — the closest
    /// available field is `eligibilityMonths` (how long the bank blocks a
    /// *new* bonus after closing). As a pragmatic stand-in until a real
    /// field is added, this approximates "safe to close" as
    /// `actualBonusDate + eligibilityMonths`, since that's the only
    /// "how many months to wait" figure this account carries. Flagged here
    /// (and in the Home agent's report) as a simplification, not a modeled
    /// business rule.
    private var safeToCloseDate: Date? {
        guard let postedDate = account.actualBonusDate else { return nil }
        return Calendar.current.date(byAdding: .month, value: Int(account.eligibilityMonths), to: postedDate)
    }
}

/// Small "N days" pill used only by `MaintainingRow`. Kept private/local
/// rather than promoted to `Components/` since it's a one-line label, not a
/// reusable card.
private struct GenericStatCardDaysLabel: View {
    let days: Int

    var body: some View {
        Text(days > 0 ? "\(days)d" : "Ready")
            .font(.caption.weight(.semibold))
            .foregroundStyle(days > 0 ? .secondary : Color.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - Previews

#Preview("Populated") {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Empty") {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Dark mode") {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
