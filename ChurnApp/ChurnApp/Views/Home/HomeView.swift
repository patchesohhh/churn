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
    // Round 4: active-only -- archiving the household's only person should
    // put Home back into first-run state (nobody active to route a paycheck
    // to), not leave it stuck showing the populated layout for a person who
    // no longer appears anywhere else in the app.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Person.createdAt, ascending: true)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
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

    /// Shared tab-selection object injected from `MyApp`/`ContentView` (see
    /// `AppTabSelection.swift`) — lets "View Full Schedule" below jump to the
    /// Calendar tab without a cross-tab `NavigationPath`, which SwiftUI's
    /// `TabView` doesn't support.
    @Environment(AppTabSelection.self) private var tabSelection

    @State private var isPresentingAddAccount = false
    @State private var isPresentingPersonSetup = false
    @State private var addPaycheckTarget: Person?
    @State private var isChoosingPaycheckPerson = false

    /// Tracks which item of `loopedCarouselItems` is currently snapped to
    /// center. Starts at index 3 — the first item (YTD Earnings) of the
    /// *middle* triplicated copy — so there's real content to scroll into on
    /// both the left (into copy 0) and right (into copy 2) before any
    /// looping reset needs to fire. See `earningsCarousel` for the looping
    /// mechanism itself.
    @State private var carouselPosition: Int? = 3

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

    /// The three headline money metrics, per the source doc's "Earnings
    /// Carousel (Top)" spec. Renders unconditionally — including at $0 with
    /// no data at all — so the first thing a brand-new user sees is "here's
    /// where your money shows up", not a wall about bank accounts.
    private var carouselBaseItems: [CarouselItem] {
        [
            CarouselItem(
                baseIndex: 0,
                label: "YTD Earnings",
                amount: CalculationService.ytdEarnings(accounts: Array(accounts)),
                subtitle: "Money earned this year",
                valueColor: .green
            ),
            CarouselItem(
                baseIndex: 1,
                label: "Pending Bonuses",
                amount: CalculationService.pendingBonusesTotal(accounts: Array(accounts)),
                subtitle: "Still being worked on",
                valueColor: .orange
            ),
            CarouselItem(
                baseIndex: 2,
                label: "All-Time Earnings",
                amount: CalculationService.allTimeEarnings(accounts: Array(accounts)),
                subtitle: "Lifetime churning total",
                valueColor: nil
            ),
        ]
    }

    /// The 3 base items, triplicated back-to-back into a 9-item array.
    /// SwiftUI's native `ScrollView` + `.scrollTargetBehavior(.viewAligned)`
    /// carousel (the mechanism CLAUDE.md's round 3 spec calls for, in place
    /// of round 1's `TabView(.page)`) has no built-in infinite-loop
    /// primitive — a `ScrollView` always has a hard start and end. The
    /// standard workaround is to give it extra real copies of the content on
    /// both sides so there's always something to scroll into, then silently
    /// snap the tracked position back to the equivalent spot in the middle
    /// copy once the user drifts into an outer copy (`normalizeCarouselLoop`
    /// below) — invisible to the user since it happens with animations
    /// disabled, but it's what makes "scroll past the last card" appear to
    /// wrap to the first.
    private var loopedCarouselItems: [CarouselItem] {
        (0..<3).flatMap { copy in
            carouselBaseItems.map { base in
                CarouselItem(
                    id: copy * carouselBaseItems.count + base.baseIndex,
                    baseIndex: base.baseIndex,
                    label: base.label,
                    amount: base.amount,
                    subtitle: base.subtitle,
                    valueColor: base.valueColor
                )
            }
        }
    }

    /// Native, center-aligned, looping, peeking carousel.
    ///
    /// Round 3's first attempt sized each card with a `GeometryReader`-
    /// computed `cardWidth` plus manual `.safeAreaPadding(.horizontal:)` to
    /// leave peeking room on both sides. That doesn't work: `.viewAligned`
    /// snaps an item's *leading* edge to the scroll view's leading content
    /// inset, not its center — equal leading/trailing safe-area padding
    /// doesn't change that alignment, it only changes how much of the
    /// neighboring items happen to be visible around whichever edge is
    /// actually anchored. The visible symptom matched exactly: the previous
    /// card's trailing ~2/3 hanging in on the left, current card jammed into
    /// the right third.
    ///
    /// The fix is Apple's documented pattern (WWDC22 "What's new in
    /// SwiftUI"): size each item with `.containerRelativeFrame(.horizontal:
    /// count:span:spacing:)` instead of a manual fixed width. That, combined
    /// with `.scrollTargetLayout()` + `.scrollTargetBehavior(.viewAligned)`,
    /// gives each item's *center* as its snap target (not its leading edge),
    /// which is what actually produces "one item centered, neighbors peek in
    /// symmetrically". `count: 5, span: 4` makes each card ~4/5 (80%) of the
    /// scroll view's width, matching the original 0.82 ratio closely enough
    /// to leave two even slivers peeking at both edges. No `GeometryReader`
    /// or manual `safeAreaPadding` needed anymore.
    private var earningsCarousel: some View {
        GeometryReader { geometry in
            // Symmetric leading/trailing inset — half of the "5th slice"
            // that `containerRelativeFrame(count: 5, span: 4)` below leaves
            // unused. Without this, the scroll content has zero inset, so
            // item 0's *leading* edge sits flush at x = 0 and `.viewAligned`
            // (whose snap point is the visible content region's center)
            // ends up centering on a region that starts at the screen edge
            // — i.e. the card reads as left-anchored, not centered. This is
            // the one piece round 3's `GeometryReader` math actually had
            // right; what round 3 got wrong was sizing the item with a
            // manual `.frame(width:)` instead of `containerRelativeFrame`.
            let sidePadding = geometry.size.width / 10

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(loopedCarouselItems) { item in
                        StatCard(
                            label: item.label,
                            amount: item.amount,
                            subtitle: item.subtitle,
                            valueColor: item.valueColor
                        )
                        .containerRelativeFrame(
                            .horizontal, count: 5, span: 4, spacing: 12
                        )
                    }
                }
                // Required for `.scrollTargetBehavior(.viewAligned)` below
                // to know where each item's snap point is.
                .scrollTargetLayout()
            }
            .safeAreaPadding(.horizontal, sidePadding)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $carouselPosition)
            .onChange(of: carouselPosition) { _, newPosition in
                normalizeCarouselLoop(newPosition)
            }
        }
        // Fixed height: a `GeometryReader`/`ScrollView` combo won't size
        // itself to a `StatCard`'s intrinsic height the way a plain `VStack`
        // would.
        .frame(height: 150)
    }

    /// Once the tracked scroll position drifts into the first copy (indices
    /// 0-2) or the last copy (indices 6-8) of `loopedCarouselItems`, jump it
    /// back to the equivalent index in the middle copy (indices 3-5) — same
    /// `baseIndex`, so the visible card doesn't change, only which physical
    /// copy is "current". Animations are explicitly disabled for this jump
    /// so it's invisible to the user; it just looks like the carousel kept
    /// scrolling in the same direction forever.
    private func normalizeCarouselLoop(_ position: Int?) {
        guard let position else { return }
        let itemCount = carouselBaseItems.count
        guard position < itemCount || position >= itemCount * 2 else { return }

        let normalizedIndex = position < itemCount ? position + itemCount : position - itemCount

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            carouselPosition = normalizedIndex
        }
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
                // Cross-tab navigation: a NavigationPath can't cross a
                // TabView's tab boundaries, so this goes through the shared
                // AppTabSelection instead (see the @Environment above).
                tabSelection.selected = .calendar
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

// MARK: - Earnings carousel item

/// One card's worth of data for `HomeView.earningsCarousel`. `id` is unique
/// per *physical* position in the triplicated 9-item array (0...8);
/// `baseIndex` (0...2) identifies which of the 3 real stat cards it's a copy
/// of — that's what `normalizeCarouselLoop` uses to jump between equivalent
/// positions across copies.
private struct CarouselItem: Identifiable {
    /// Defaulted since `carouselBaseItems` builds these without an `id` —
    /// only `loopedCarouselItems` (below) assigns real, unique ids.
    var id: Int = -1
    let baseIndex: Int
    let label: String
    let amount: Decimal
    let subtitle: String
    let valueColor: Color?
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
    // Also verifies the carousel's initial centered/peeking state: the
    // canvas is static so it can't show the loop/snap behavior in motion,
    // but this confirms one full card sits centered with slivers of its
    // neighbors visible at both edges on first render.
    HomeView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
}

#Preview("First run (no Person)") {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
        .environment(AppTabSelection())
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
        .environment(AppTabSelection())
}

#Preview("Dark mode") {
    HomeView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
        .preferredColorScheme(.dark)
}
