//
//  CalendarView.swift
//  ChurnApp
//
//  Calendar tab — schedule of Paychecks grouped by month.
//
//  ROUND 3 REWRITE: this tab used to show only persisted `Paycheck` rows
//  (round 2). The spec now asks for a "projected, effectively-open-ended"
//  schedule — real paychecks plus generated future occurrences, so the user
//  can see where their next several paydays are headed even before they log
//  them. See CLAUDE.md, "Round 3 changes" → "Calendar becomes a projected,
//  effectively-open-ended list".
//
//  HOW PROJECTION WORKS (read this before changing the generation logic):
//  - For each `Person` with a `nextPaycheckDate` set and a non-`.irregular`
//    `payFrequency`, we generate `projectionCount` (12, see below) future
//    occurrences starting at `nextPaycheckDate` and stepping forward by
//    `payFrequency` each time. **A real `Paycheck` on record is NOT
//    required** — round 4 fixed a bug where projection only ran for a
//    person who already had at least one real paycheck to repeat, which
//    defeated the entire point of `Person` setup (income profile) being
//    enough on its own to forecast a schedule. See CLAUDE.md, "Round 4
//    changes" → "Calendar projection must not require an existing real
//    `Paycheck`."
//  - **If the person has at least one real `Paycheck`**
//    (`person.paychecksArray.first`), each occurrence repeats that
//    paycheck's *split pattern* (which accounts, which amounts) verbatim —
//    "same amounts" is the simplest reading of "if none of the allocations
//    change" from the spec, and avoids guessing at a scaling factor
//    nothing in the schema informs. Promotion-end awareness (the one rule
//    worth re-reading twice): a split is dropped from a *projected*
//    occurrence when its account's `actualBonusDate != nil` — the bonus
//    already posted, so there's no more reason to keep feeding that
//    account. Dropping a split from the generated list, rather than
//    re-summing it elsewhere, is enough on its own to "redirect" that
//    money into the projected remainder — the remainder is computed as
//    total minus whatever splits remain, exactly like
//    `Paycheck.unallocatedAmountDecimal` does for real rows.
//  - **If the person has zero real paychecks**, there's no split pattern
//    to repeat yet, so every occurrence uses `person.paycheckAmountDecimal`
//    as the total with **no explicit splits** — 100% of it is the
//    projected remainder. The remainder is attributed to the person's own
//    home account when they have one set (same default
//    `AddEditPaycheckView` uses when creating a real paycheck for them),
//    purely for display; projection never blocks on a remainder account
//    existing.
//  - Real, persisted `Paycheck`s are never touched by any of this — this
//    whole function only ever produces `ProjectedPaycheck` values, which
//    are display-only until materialized. See "Historical immutability"
//    in CLAUDE.md's round 4 section for the invariant this preserves.
//  - Why 12 occurrences (not a fixed time window): pay frequency varies
//    from weekly to monthly per person, so a fixed multi-month window would
//    show very different list lengths for a weekly vs. monthly earner. A
//    fixed *count* per person keeps the projected horizon proportionate
//    (~3 months out for weekly, ~1 year out for monthly) and keeps the list
//    bounded regardless of frequency — `List` has no way to render a truly
//    infinite feed, so this is the practical stand-in the spec calls for,
//    not the final Gantt-chart visualization (still out of scope).
//  - Projections are generated on the fly every time `body` evaluates and
//    are **never written to Core Data** — only tapping "Create this
//    paycheck" on one turns it into a real, persisted `Paycheck` +
//    `DirectDeposit` rows.
//  - ROUND 5 FIX — materializing a projection must retire it. Once a
//    projected occurrence is turned into a real `Paycheck` (via
//    `materialize(_:)` below), this generation loop has no memory of that —
//    it re-derives the same `projectionCount` occurrences from
//    `person.paycheckAmountDecimal`/`nextPaycheckDate` every time `body`
//    re-evaluates, so without a guard the slot the user just materialized
//    would get re-projected and show up a second time, dashed "Projected"
//    badge and all, right alongside the real row it came from. Fix: after
//    generating a person's occurrences, drop any whose date already has a
//    matching real `Paycheck` for that same person — see
//    `isAlreadyReal(payDate:person:)`. The match uses day tolerance, not
//    exact-date equality, because `advance(_:by:)` below is itself an
//    approximation (the semimonthly flat 15-day step is the clearest
//    example) — a real paycheck logged a day or two off from the
//    theoretical projected date is still "this slot," not a coincidentally
//    nearby unrelated paycheck. Reuses
//    `AutomaticNotificationService.ddMatchToleranceDays` rather than
//    inventing a second tolerance constant — that service documents the
//    identical rationale (approximate stepping vs. a real logged date) for
//    the same underlying projection math.
//

import CoreData
import SwiftUI

struct CalendarView: View {

    /// All paychecks, oldest first. Grouping into months happens in
    /// `groupedByMonth` below rather than in the fetch request itself —
    /// Core Data has no notion of "group by calendar month" server-side.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Paycheck.payDate, ascending: true)]
    )
    private var paychecks: FetchedResults<Paycheck>

    /// Drives both "who is this new paycheck for" and the projection
    /// generation below.
    // Round 4: active-only -- this feeds the *projection* loop below only.
    // Archiving a person must stop generating new future projected
    // paychecks for them, but their real, persisted Paycheck rows are
    // fetched separately (see `paychecks` below) and are never filtered by
    // this predicate, so their history stays fully visible.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Person.name, ascending: true)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var people: FetchedResults<Person>

    @Environment(\.managedObjectContext) private var viewContext

    @State private var isPresentingAdd = false
    @State private var personForNewPaycheck: Person?
    @State private var isChoosingPerson = false

    /// The projected occurrence the user tapped, pending confirmation.
    @State private var projectionPendingConfirmation: ProjectedPaycheck?
    /// Set once a projected occurrence has been materialized into a real,
    /// saved `Paycheck` — presenting this drives the edit sheet.
    @State private var materializedPaycheck: Paycheck?

    /// How many future occurrences to generate per person. See the file
    /// header comment for why this is a fixed count rather than a fixed
    /// time window.
    private static let projectionCount = 12

    @Environment(AppTabSelection.self) private var tabSelection

    var body: some View {
        @Bindable var tabSelection = tabSelection

        NavigationStack(path: $tabSelection.calendarPath) {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groupedByMonth, id: \.month) { group in
                            Section(group.monthTitle) {
                                ForEach(group.entries) { entry in
                                    row(for: entry)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                // A paycheck needs a Person to attach to (`Paycheck.person`
                // is non-optional) — hide the toolbar action entirely rather
                // than show a button that would have nothing to do when no
                // person exists yet. The empty state below carries the
                // equivalent "go set up a person first" messaging in that
                // case, so nothing is silently lost.
                if !entries.isEmpty && !people.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            presentAdd()
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresentingAdd) {
                if let personForNewPaycheck {
                    AddEditPaycheckView(person: personForNewPaycheck)
                }
            }
            .sheet(item: $materializedPaycheck) { paycheck in
                AddEditPaycheckView(person: paycheck.person, paycheck: paycheck)
            }
            .confirmationDialog(
                "Add a paycheck for which person?",
                isPresented: $isChoosingPerson,
                titleVisibility: .visible
            ) {
                ForEach(people, id: \.id) { person in
                    Button(person.name) {
                        personForNewPaycheck = person
                        isPresentingAdd = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Create this paycheck?",
                isPresented: Binding(
                    get: { projectionPendingConfirmation != nil },
                    set: { if !$0 { projectionPendingConfirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Create this Paycheck") {
                    if let projection = projectionPendingConfirmation {
                        materializedPaycheck = materialize(projection)
                    }
                    projectionPendingConfirmation = nil
                }
                Button("Cancel", role: .cancel) {
                    projectionPendingConfirmation = nil
                }
            } message: {
                Text("This is an upcoming paycheck projected from the split pattern of the last one. Creating it saves a real paycheck you can confirm or adjust.")
            }
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func row(for entry: CalendarEntry) -> some View {
        switch entry {
        case .real(let paycheck):
            NavigationLink {
                PaycheckDetailView(paycheck: paycheck)
            } label: {
                PaycheckRow(paycheck: paycheck)
            }

        case .projected(let projection):
            // Not a NavigationLink — a projected entry has no real Paycheck
            // to push a detail view for. Tapping it instead offers to
            // materialize it (see the confirmationDialog above).
            Button {
                projectionPendingConfirmation = projection
            } label: {
                ProjectedPaycheckRow(projection: projection)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Materializing a projection into a real Paycheck

    /// Turns a projected occurrence into a real, saved `Paycheck` +
    /// `DirectDeposit` rows, pre-filled with the projected amounts, then
    /// hands it back so the caller can open the normal edit flow on it.
    ///
    /// Saved immediately (rather than left as an unsaved, in-context draft)
    /// so a cancelled edit sheet doesn't leave a half-formed object sitting
    /// around confusing other `@FetchRequest`s on this same context — Core
    /// Data surfaces unsaved inserted objects to fetch requests immediately,
    /// so an unsaved draft here would flash into the "real paychecks" list
    /// above before the user ever confirmed anything in the edit sheet.
    private func materialize(_ projection: ProjectedPaycheck) -> Paycheck {
        let paycheck = Paycheck(context: viewContext)
        paycheck.id = UUID()
        paycheck.payDate = projection.payDate
        paycheck.totalAmountDecimal = projection.totalAmount
        paycheck.createdAt = Date()
        paycheck.updatedAt = Date()
        paycheck.person = projection.person
        paycheck.remainderAccount = projection.remainderAccount

        for split in projection.splits {
            let deposit = DirectDeposit(context: viewContext)
            deposit.id = UUID()
            deposit.scheduledDate = projection.payDate
            deposit.amountDecimal = split.amount
            deposit.statusValue = .scheduled
            deposit.sequenceNumberInSeries = split.sequenceNumberInSeries
            deposit.isFirstToBank = false
            deposit.createdAt = Date()
            deposit.updatedAt = Date()
            deposit.account = split.account
            deposit.person = projection.person
            deposit.paycheck = paycheck
        }

        do {
            try viewContext.save()
        } catch {
            assertionFailure("Failed to materialize projected paycheck: \(error)")
        }
        return paycheck
    }

    // MARK: - Empty state

    /// Exact copy "No Paychecks Scheduled" per CLAUDE.md, unchanged from
    /// round 2. Reachable only when there's no Person at all, or every
    /// Person is missing `nextPaycheckDate`/has `.irregular` frequency —
    /// as of round 4, a Person with income-profile data set but zero real
    /// paychecks logged still projects a schedule (see `projectedPaychecks`
    /// below), so this state is rarer than it used to be. The action below
    /// only appears once a Person exists to attach the new paycheck to.
    private var emptyState: some View {
        Group {
            if people.isEmpty {
                EmptyStateView(
                    systemImageName: "calendar",
                    title: "No Paychecks Scheduled",
                    message: "Add a person in Settings first, then log a paycheck to start routing it to your accounts."
                )
            } else {
                EmptyStateView(
                    systemImageName: "calendar",
                    title: "No Paychecks Scheduled",
                    message: "Log a paycheck to start routing it across the accounts you're churning.",
                    actionTitle: "Add Paycheck"
                ) {
                    presentAdd()
                }
            }
        }
    }

    private func presentAdd() {
        if people.count == 1 {
            personForNewPaycheck = people.first
            isPresentingAdd = true
        } else if people.count > 1 {
            isChoosingPerson = true
        }
        // people.isEmpty: no-op — both the toolbar button and the empty
        // state's action are hidden in that case, so this is unreachable,
        // but guarding here too keeps the function safe if that ever changes.
    }

    // MARK: - Projection generation

    /// One future, not-yet-real paycheck for a person, generated from their
    /// most recent real paycheck's split pattern. See the file header
    /// comment for the full generation rules.
    /// `fileprivate`, not `private`: `ProjectedPaycheckRow` below (a sibling
    /// top-level type in this same file, not an extension of `CalendarView`)
    /// needs to read this type too, and `private` on a nested type is
    /// scoped to the enclosing declaration, not the whole file.
    fileprivate struct ProjectedPaycheck: Identifiable {
        let id: String
        let person: Person
        let payDate: Date
        let totalAmount: Decimal
        /// Splits still active in this projection — an account whose bonus
        /// already posted (`actualBonusDate != nil`) is simply omitted here,
        /// which is all that's needed to redirect its amount into
        /// `remainderAmount` below.
        let splits: [ProjectedSplit]
        let remainderAccount: Account?

        var remainderAmount: Decimal {
            totalAmount - splits.reduce(Decimal(0)) { $0 + $1.amount }
        }
    }

    fileprivate struct ProjectedSplit: Identifiable {
        let id = UUID()
        let account: Account
        let amount: Decimal
        let sequenceNumberInSeries: Int16
    }

    /// Generates every person's projected occurrences, unsorted (sorting
    /// happens once everything is merged with real paychecks in
    /// `groupedByMonth`).
    private var projectedPaychecks: [ProjectedPaycheck] {
        var results: [ProjectedPaycheck] = []

        for person in people {
            guard let start = person.nextPaycheckDate else { continue }
            // `.irregular` reports `paychecksPerYear == 0` deliberately (see
            // Enums.swift) precisely so callers must special-case it rather
            // than produce a bogus forecast — an irregular earner has no
            // cadence to step forward by, so they only ever show real rows.
            guard person.payFrequencyValue.paychecksPerYear > 0 else { continue }

            // Two modes, chosen once per person up front (not required to
            // repeat a real paycheck any more — see the file header comment
            // and CLAUDE.md's round 4 section). `lastReal == nil` is the
            // exact case that used to be skipped entirely, which is why a
            // freshly-set-up second person's schedule never appeared.
            let lastReal = person.paychecksArray.first

            // NOTE: reads only `lastReal`'s *own* stored fields
            // (`totalAmountDecimal`, its `directDepositsArray` amounts,
            // `remainderAccount`) — never live `Person`/`Account` data — so
            // this never risks redrawing a real Paycheck from current data.
            // The `else` branch below reads `person.paycheckAmountDecimal`
            // live, but only to seed *projected* (not-yet-real) entries,
            // which is exactly what's supposed to track a raise going
            // forward.
            let pattern: [(account: Account, amount: Decimal)] = lastReal?.directDepositsArray.compactMap { deposit in
                guard let account = deposit.account else { return nil }
                return (account, deposit.amountDecimal)
            } ?? []

            let totalAmount = lastReal?.totalAmountDecimal ?? person.paycheckAmountDecimal
            // Real paycheck on record: keep its own remainder-account
            // choice. No real paycheck yet: fall back to the person's own
            // home account, same default `AddEditPaycheckView` uses when
            // first creating a real paycheck for them — display-only, never
            // required for projection to proceed.
            let remainderAccount = lastReal?.remainderAccount ?? person.accountsArray.first(where: { $0.isHomeAccount })

            var payDate = start
            for occurrence in 0..<Self.projectionCount {
                var splits: [ProjectedSplit] = []
                for (sequence, entry) in pattern.enumerated() {
                    // Promotion-end awareness: skip any account whose bonus
                    // already posted. Its amount isn't tracked separately —
                    // simply leaving it out of `splits` is enough, since
                    // `remainderAmount` above is computed as
                    // total-minus-remaining-splits.
                    guard entry.account.actualBonusDate == nil else { continue }
                    splits.append(
                        ProjectedSplit(
                            account: entry.account,
                            amount: entry.amount,
                            sequenceNumberInSeries: Int16(sequence)
                        )
                    )
                }
                // When there's no real paycheck yet, `pattern` is empty, so
                // `splits` stays empty too — 100% of `totalAmount` falls
                // through to `remainderAmount`, exactly as the round 4 fix
                // requires.

                results.append(
                    ProjectedPaycheck(
                        id: "\(person.id.uuidString)-\(occurrence)",
                        person: person,
                        payDate: payDate,
                        totalAmount: totalAmount,
                        splits: splits,
                        remainderAccount: remainderAccount
                    )
                )

                payDate = Self.advance(payDate, by: person.payFrequencyValue)
            }
        }

        // Round 5 fix: drop any generated occurrence that's already been
        // materialized into a real Paycheck (see the file header comment).
        // Filtering once at the end, rather than guarding inside the loop
        // above, keeps the generation math itself untouched and makes the
        // "what got removed and why" logic a single, easy-to-read pass.
        return results.filter { !isAlreadyReal(payDate: $0.payDate, person: $0.person) }
    }

    /// True when a real, persisted `Paycheck` already exists for this person
    /// within `AutomaticNotificationService.ddMatchToleranceDays` of
    /// `payDate` — i.e. this projected slot has already been materialized
    /// and must not be projected again. Compares against `paychecks`
    /// (this view's own real-paycheck fetch), not `person.paychecksArray`,
    /// so a paycheck inserted-but-not-yet-saved this session (there isn't
    /// one mid-materialize, but this keeps the source of truth singular)
    /// still counts — both ultimately read the same context.
    private func isAlreadyReal(payDate: Date, person: Person) -> Bool {
        let calendar = Calendar.current
        return paychecks.contains { paycheck in
            guard paycheck.person.id == person.id else { return false }
            let days = calendar.dateComponents([.day], from: paycheck.payDate, to: payDate).day ?? Int.max
            return abs(days) <= AutomaticNotificationService.ddMatchToleranceDays
        }
    }

    /// Steps a date forward by one pay period for the given frequency.
    /// `.semimonthly` has no clean fixed-day interval (real semimonthly pay
    /// dates are usually "the 1st and 16th" or "15th and last day", which
    /// varies by employer and isn't captured anywhere in the schema) — a
    /// flat 15-day step is a deliberate, documented approximation good
    /// enough for a projected preview list, not a payroll-accurate
    /// calendar. `.irregular` is unreachable here (`projectedPaychecks`
    /// already filters it out before calling this).
    private static func advance(_ date: Date, by frequency: PayFrequency) -> Date {
        let calendar = Calendar.current
        switch frequency {
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .biweekly:
            return calendar.date(byAdding: .weekOfYear, value: 2, to: date) ?? date
        case .semimonthly:
            return calendar.date(byAdding: .day, value: 15, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .irregular:
            return date
        }
    }

    // MARK: - Grouping

    /// One row in the merged, sortable list — either a real, persisted
    /// `Paycheck` or a generated `ProjectedPaycheck`.
    private enum CalendarEntry: Identifiable {
        case real(Paycheck)
        case projected(ProjectedPaycheck)

        var id: String {
            switch self {
            case .real(let paycheck): "real-\(paycheck.id.uuidString)"
            case .projected(let projection): "projected-\(projection.id)"
            }
        }

        var payDate: Date {
            switch self {
            case .real(let paycheck): paycheck.payDate
            case .projected(let projection): projection.payDate
            }
        }
    }

    private var entries: [CalendarEntry] {
        let real = paychecks.map(CalendarEntry.real)
        let projected = projectedPaychecks.map(CalendarEntry.projected)
        return (real + projected).sorted { $0.payDate < $1.payDate }
    }

    private struct MonthGroup {
        let month: Date
        let monthTitle: String
        let entries: [CalendarEntry]
    }

    /// Buckets entries by calendar month, preserving chronological order
    /// (`entries` is already sorted ascending, so a simple ordered walk is
    /// enough — no need to re-sort dictionary keys afterward).
    private var groupedByMonth: [MonthGroup] {
        var order: [Date] = []
        var buckets: [Date: [CalendarEntry]] = [:]

        for entry in entries {
            let components = Calendar.current.dateComponents([.year, .month], from: entry.payDate)
            let monthStart = Calendar.current.date(from: components) ?? entry.payDate
            if buckets[monthStart] == nil {
                buckets[monthStart] = []
                order.append(monthStart)
            }
            buckets[monthStart]?.append(entry)
        }

        return order.map { month in
            MonthGroup(month: month, monthTitle: Self.monthFormatter.string(from: month), entries: buckets[month] ?? [])
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}

// MARK: - PaycheckRow

/// One real, persisted paycheck: date, person, total, and a compact
/// allocation badge — green "Fully Allocated" / orange "Partial" / red
/// "Over-Allocated", driven straight off `unallocatedAmountDecimal`.
/// Unchanged from round 2.
private struct PaycheckRow: View {

    let paycheck: Paycheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(paycheck.payDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))

                Text(paycheck.person.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(splitCountLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                MoneyText(amount: paycheck.totalAmountDecimal, size: .small)
                GenericStatusBadge(
                    text: allocationText,
                    color: allocationColor,
                    systemImageName: allocationSymbolName
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var splitCountLabel: String {
        let count = paycheck.directDepositsArray.count
        return count == 1 ? "1 split" : "\(count) splits"
    }

    private var remainder: Decimal { paycheck.unallocatedAmountDecimal }

    private var allocationText: String {
        if remainder < 0 { "Over-Allocated" }
        else if remainder == 0 { "Fully Allocated" }
        else { "Partial" }
    }

    private var allocationColor: Color {
        if remainder < 0 { .red }
        else if remainder == 0 { .green }
        else { .orange }
    }

    private var allocationSymbolName: String {
        if remainder < 0 { "exclamationmark.triangle.fill" }
        else if remainder == 0 { "checkmark.circle.fill" }
        else { "circle.lefthalf.filled" }
    }
}

// MARK: - ProjectedPaycheckRow

/// A generated, not-yet-real occurrence. Visually distinguished from a real
/// `PaycheckRow` with a dashed border, reduced opacity, and an explicit
/// "Projected" badge — clear at a glance without being heavy-handed, so a
/// merged list of real + projected rows still reads as one continuous
/// schedule rather than two disconnected sections.
private struct ProjectedPaycheckRow: View {

    fileprivate let projection: CalendarView.ProjectedPaycheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(projection.payDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))

                Text(projection.person.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(splitCountLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                MoneyText(amount: projection.totalAmount, size: .small)
                GenericStatusBadge(
                    text: "Projected",
                    color: .secondary,
                    systemImageName: "clock.arrow.circlepath"
                )
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .opacity(0.75)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.secondary)
        )
        .contentShape(Rectangle())
    }

    private var splitCountLabel: String {
        let count = projection.splits.count
        return count == 1 ? "1 split (upcoming)" : "\(count) splits (upcoming)"
    }
}

// MARK: - Previews

#Preview("Populated (real + projected)") {
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
}

#Preview("Projection with a promotion that already ended") {
    // Same seeded store as above, but with the first sample account's bonus
    // marked as posted — its split should drop out of every projected
    // occurrence and fall through to the remainder instead. Exercises the
    // promotion-end-awareness rule from CLAUDE.md's round 3 section.
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []
    if let account = accounts.first(where: { !$0.directDepositsArray.isEmpty }) {
        account.actualBonusDate = Date()
    }

    return CalendarView()
        .environment(\.managedObjectContext, context)
        .environment(AppTabSelection())
}

#Preview("Empty, no person yet") {
    // A fresh, unseeded in-memory store (not `.preview`, which is
    // pre-populated with sample data) to exercise the true empty state
    // with no Person to attach a paycheck to.
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
        .environment(AppTabSelection())
}

#Preview("Empty, with a person") {
    // A person exists but hasn't set `nextPaycheckDate` yet (income amount
    // and frequency alone aren't enough to project from — a starting date
    // is required too), so there's nothing to project and no real paycheck
    // logged either. The empty state's "Add Paycheck" action should be live
    // in this state. Contrast with "Projected only, zero real paychecks"
    // below, which is the same setup *plus* a `nextPaycheckDate` — that one
    // must show a full projected schedule, not this empty state.
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    let person = Person(context: context)
    person.id = UUID()
    person.name = "Morgan"
    person.payFrequency = PayFrequency.biweekly.rawValue
    person.paycheckAmount = NSDecimalNumber(string: "2100.00")
    person.maxConcurrentDirectDeposits = 3
    person.createdAt = Date()
    person.updatedAt = Date()

    return CalendarView()
        .environment(\.managedObjectContext, context)
        .environment(AppTabSelection())
}

#Preview("Projected only, zero real paychecks (round 4 fix)") {
    // The exact bug scenario from CLAUDE.md's round 4 section: a person
    // with a full income profile (amount, next date, frequency) but zero
    // real `Paycheck` rows logged. Before the fix, `projectedPaychecks`
    // skipped this person entirely (nothing to repeat a split pattern
    // from) — the Calendar showed nothing for them even though setup was
    // complete. Now it projects `projectionCount` occurrences using
    // `person.paycheckAmountDecimal` as each total, 100% unsplit into the
    // remainder (dashed "Projected" rows, no split-count badge above "0
    // splits (upcoming)"). Also gives them a home account so the remainder
    // shows a concrete destination rather than "no destination set."
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    let person = Person(context: context)
    person.id = UUID()
    person.name = "Jordan"
    person.payFrequency = PayFrequency.biweekly.rawValue
    person.paycheckAmount = NSDecimalNumber(string: "2450.00")
    person.nextPaycheckDate = Calendar.current.date(byAdding: .day, value: 5, to: Date())
    person.maxConcurrentDirectDeposits = 3
    person.createdAt = Date()
    person.updatedAt = Date()

    let homeAccount = Account(context: context)
    homeAccount.id = UUID()
    homeAccount.bankName = "Ally"
    homeAccount.accountNumberLast4 = "9042"
    homeAccount.accountType = AccountType.checking.rawValue
    homeAccount.openingDate = Date()
    homeAccount.bonusAmount = NSDecimalNumber(string: "0")
    homeAccount.bonusStructure = BonusStructure.lumpSum.rawValue
    homeAccount.bonusRequirements = ""
    homeAccount.accountStatus = AccountStatus.open.rawValue
    homeAccount.eligibilityMonths = 12
    homeAccount.isArchived = false
    homeAccount.isHomeAccount = true
    homeAccount.isChurnAccount = false
    homeAccount.createdAt = Date()
    homeAccount.updatedAt = Date()
    homeAccount.person = person

    return CalendarView()
        .environment(\.managedObjectContext, context)
        .environment(AppTabSelection())
}

#Preview("Materialized slot doesn't double-project (round 5 fix)") {
    // The exact reported bug: a person whose `nextPaycheckDate` lines up
    // with a real, already-logged `Paycheck` (as it would immediately after
    // tapping a projected entry's "Create this Paycheck"). Before the fix,
    // `projectedPaychecks` had no way to know that slot was now real, so it
    // kept generating a projected occurrence for the same date — the
    // Calendar showed both the real row and a dashed "Projected" row for
    // what should read as a single upcoming paycheck. Also seeds a second
    // real paycheck a couple of days off the theoretical next-next
    // occurrence to exercise the day-tolerance matching, not just an exact
    // date match. Confirm in the canvas: exactly one entry per pay period,
    // no dashed duplicate sitting next to the real one.
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    let person = Person(context: context)
    person.id = UUID()
    person.name = "Taylor"
    person.payFrequency = PayFrequency.biweekly.rawValue
    person.paycheckAmount = NSDecimalNumber(string: "2200.00")
    let nextDate = Calendar.current.date(byAdding: .day, value: 5, to: Date()) ?? Date()
    person.nextPaycheckDate = nextDate
    person.maxConcurrentDirectDeposits = 3
    person.createdAt = Date()
    person.updatedAt = Date()

    let homeAccount = Account(context: context)
    homeAccount.id = UUID()
    homeAccount.bankName = "Ally"
    homeAccount.accountNumberLast4 = "9042"
    homeAccount.accountType = AccountType.checking.rawValue
    homeAccount.openingDate = Date()
    homeAccount.bonusAmount = NSDecimalNumber(string: "0")
    homeAccount.bonusStructure = BonusStructure.lumpSum.rawValue
    homeAccount.bonusRequirements = ""
    homeAccount.accountStatus = AccountStatus.open.rawValue
    homeAccount.eligibilityMonths = 12
    homeAccount.isArchived = false
    homeAccount.isHomeAccount = true
    homeAccount.isChurnAccount = false
    homeAccount.createdAt = Date()
    homeAccount.updatedAt = Date()
    homeAccount.person = person

    // The "materialized" paycheck for the very next projected slot, dated
    // exactly at `nextPaycheckDate` — the same date `materialize(_:)` would
    // have written had the user actually tapped the first projected row.
    let realPaycheck = Paycheck(context: context)
    realPaycheck.id = UUID()
    realPaycheck.payDate = nextDate
    realPaycheck.totalAmountDecimal = Decimal(2200)
    realPaycheck.createdAt = Date()
    realPaycheck.updatedAt = Date()
    realPaycheck.person = person
    realPaycheck.remainderAccount = homeAccount

    // A second real paycheck 2 days off the theoretical next-next
    // occurrence (14 days later, biweekly) — within
    // `AutomaticNotificationService.ddMatchToleranceDays` (4), so it should
    // also suppress its slot despite not landing on the exact stepped date.
    let secondOccurrenceDate = Calendar.current.date(byAdding: .day, value: 14, to: nextDate) ?? nextDate
    let offsetDate = Calendar.current.date(byAdding: .day, value: 2, to: secondOccurrenceDate) ?? secondOccurrenceDate
    let secondRealPaycheck = Paycheck(context: context)
    secondRealPaycheck.id = UUID()
    secondRealPaycheck.payDate = offsetDate
    secondRealPaycheck.totalAmountDecimal = Decimal(2200)
    secondRealPaycheck.createdAt = Date()
    secondRealPaycheck.updatedAt = Date()
    secondRealPaycheck.person = person
    secondRealPaycheck.remainderAccount = homeAccount

    return CalendarView()
        .environment(\.managedObjectContext, context)
        .environment(AppTabSelection())
}

#Preview("Materialize flow (tap a projected entry)") {
    // Same populated store as above — open this preview in Xcode's canvas,
    // tap a dashed "Projected" row, and confirm "Create this Paycheck" to
    // watch it turn into a real row and open the edit sheet.
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
}

#Preview("Dark mode") {
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
        .preferredColorScheme(.dark)
}
