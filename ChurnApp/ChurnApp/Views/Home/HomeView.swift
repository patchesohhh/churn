//
//  HomeView.swift
//  ChurnApp
//
//  The Home tab: a dashboard that answers "how am I doing, and what needs
//  attention right now" in a single scroll. Built from the "Home Screen
//  Layout" spec in `docs/project notes/UI Summary (initial).txt`, then
//  reworked in round 2 per CLAUDE.md: this app is a paycheck-routing app
//  first, bonus-tracker second, so the earnings carousel now *always*
//  renders (even at $0) instead of being hidden behind a full-screen "add a
//  bank account" empty state on first launch — that used to make the app
//  read as being about bank data instead of money coming in.
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

    /// Every `Person` — used only to detect first-run ("no one has set up an
    /// income profile yet") and to resolve who "Add Paycheck" should target.
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Person.createdAt, ascending: true)])
    private var people: FetchedResults<Person>

    /// Upcoming paychecks (today or later), soonest first — round 2 moves
    /// this section from raw `DirectDeposit` rows to `Paycheck`, since a
    /// paycheck (with its computed allocation status) is the thing the user
    /// actually thinks in terms of now.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Paycheck.payDate, ascending: true)],
        predicate: NSPredicate(format: "payDate >= %@", Calendar.current.startOfDay(for: Date()) as NSDate)
    )
    private var upcomingPaychecks: FetchedResults<Paycheck>

    @Environment(\.managedObjectContext) private var viewContext

    @State private var isPresentingAddAccount = false
    @State private var isPresentingPersonSetup = false
    @State private var addPaycheckTarget: Person?
    @State private var isChoosingPaycheckPerson = false

    // MARK: - Derived data

    private var isFirstRun: Bool { people.isEmpty }

    private var activePromotions: [Account] {
        accounts.filter {
            let status = $0.accountStatusValue
            return (status == .open || status == .prospecting) && $0.actualBonusDate == nil
        }
    }

    private var maintainingAccounts: [Account] {
        accounts.filter { $0.accountStatusValue == .maintaining }
    }

    private var nextPaychecks: [Paycheck] {
        Array(upcomingPaychecks.prefix(3))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Always at the top, always rendered — never hidden
                    // behind a full-screen empty state. See CLAUDE.md round 2.
                    earningsCarousel

                    if isFirstRun {
                        firstRunCallToAction
                    }

                    if !activePromotions.isEmpty {
                        activePromotionsSection
                    } else if !isFirstRun {
                        activePromotionsEmptySection
                    }

                    nextPaychecksSection

                    if !maintainingAccounts.isEmpty {
                        maintainingSection
                    }
                }
                .padding(.vertical, 16)
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
            .navigationDestination(for: Paycheck.self) { paycheck in
                PaycheckDetailView(paycheck: paycheck)
            }
            .sheet(isPresented: $isPresentingAddAccount) {
                AddEditAccountView(account: nil)
            }
            .sheet(isPresented: $isPresentingPersonSetup) {
                NavigationStack {
                    PersonSetupView(person: nil)
                }
            }
            .sheet(item: $addPaycheckTarget) { person in
                AddEditPaycheckView(person: person, paycheck: nil)
            }
            .confirmationDialog(
                "Add Paycheck For",
                isPresented: $isChoosingPaycheckPerson,
                titleVisibility: .visible
            ) {
                ForEach(people, id: \.id) { person in
                    Button(person.name) {
                        addPaycheckTarget = person
                    }
                }
            }
        }
    }

    // MARK: - 1. Earnings carousel

    /// Swipeable page-style carousel of the three headline money metrics, per
    /// the source doc's "Earnings Carousel (Top)" spec. `TabView(.page)`
    /// reads closer to the original intent than a static HStack, and is
    /// still fully native. Renders unconditionally — including at $0 with no
    /// data at all — so the first thing a brand-new user sees is "here's
    /// where your money shows up", not a wall about bank accounts.
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

    // MARK: - First-run call to action

    /// Shown only when no `Person` exists yet at all. Framed around income
    /// ("set up your paycheck"), not bank accounts — opening a bank account
    /// is a downstream step of routing a paycheck, not the entry point.
    /// Deliberately a card within the scroll, not a full-screen takeover, so
    /// the earnings carousel above it stays visible.
    private var firstRunCallToAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(.green.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Your Paycheck")
                        .font(.headline)
                    Text("Add your income profile to start routing paychecks to bonus accounts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Add Paycheck") {
                isPresentingPersonSetup = true
            }
            .buttonStyle(.primary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
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

    /// Small, inline empty state for Active Promotions — not a full-screen
    /// takeover. Only shown once the user is past first-run (there's already
    /// a bigger CTA for that case).
    private var activePromotionsEmptySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Active Promotions")
                .padding(.horizontal)

            Text("No active promotions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    // MARK: - 3. Next paychecks mini-preview

    /// Round 2: `Paycheck`-based rather than raw `DirectDeposit`-based —
    /// shows date, person, total, and allocation status via
    /// `unallocatedAmountDecimal` rather than a single deposit row.
    private var nextPaychecksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(
                title: "Next Paychecks",
                actionTitle: nextPaychecks.isEmpty ? nil : "View full schedule"
            ) {
                // TODO: navigate to the Calendar tab once it's wired up by
                // the concurrently-built Calendar feature / tab-bar
                // integration pass. Intentionally a no-op for now.
            }
            .padding(.horizontal)

            if nextPaychecks.isEmpty {
                Text("No paychecks scheduled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 8) {
                    ForEach(nextPaychecks, id: \.id) { paycheck in
                        NavigationLink(value: paycheck) {
                            NextPaycheckRow(paycheck: paycheck)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
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
                startAddPaycheckFlow()
            } label: {
                Label("Add Paycheck", systemImage: "banknote")
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

    /// "Add Paycheck" needs an income profile (`Person`) to exist first,
    /// since a `Paycheck` requires one. No people yet → send the user to
    /// `PersonSetupView` instead. One person → target them directly. Two
    /// (or more) → ask which one via a confirmation dialog rather than
    /// guessing.
    private func startAddPaycheckFlow() {
        if let onlyPerson = people.count == 1 ? people.first : nil {
            addPaycheckTarget = onlyPerson
        } else if people.isEmpty {
            isPresentingPersonSetup = true
        } else {
            isChoosingPaycheckPerson = true
        }
    }
}

// MARK: - Next paycheck row

/// One row in the Next Paychecks preview: date, person, total, and whether
/// the paycheck is fully or partially allocated across accounts.
private struct NextPaycheckRow: View {

    let paycheck: Paycheck

    private var isFullyAllocated: Bool {
        paycheck.unallocatedAmountDecimal <= 0
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(paycheck.person.name)
                    .font(.subheadline.weight(.semibold))
                Text(paycheck.payDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(amount: paycheck.totalAmountDecimal, size: .small)
                allocationBadge
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "Fully allocated" / "Partially allocated" status derived from
    /// `unallocatedAmountDecimal` — round 2's computed-remainder model, never
    /// a stored flag. A negative remainder (over-allocated) is flagged red
    /// rather than treated the same as "fully allocated".
    private var allocationBadge: some View {
        Group {
            if paycheck.unallocatedAmountDecimal < 0 {
                Text("Over-allocated")
                    .foregroundStyle(.red)
            } else if isFullyAllocated {
                Text("Fully allocated")
                    .foregroundStyle(.secondary)
            } else {
                Text("Partially allocated")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
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

#Preview("First run (no Person)") {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Person exists, no accounts/paychecks") {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let person = Person(context: context)
    person.id = UUID()
    person.name = "Alex"
    person.payFrequency = PayFrequency.biweekly.rawValue
    person.paycheckAmount = NSDecimalNumber(decimal: 2400)
    person.maxConcurrentDirectDeposits = 2
    person.createdAt = Date()
    person.updatedAt = Date()
    try? context.save()

    return HomeView()
        .environment(\.managedObjectContext, context)
}

#Preview("Dark mode") {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
