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
//  - For each `Person` with a `nextPaycheckDate` set, a non-`.irregular`
//    `payFrequency`, and at least one real `Paycheck` on record (there's
//    nothing to repeat otherwise), we generate `projectionCount` (12, see
//    below) future occurrences starting at `nextPaycheckDate` and stepping
//    forward by `payFrequency` each time.
//  - Each occurrence repeats the *split pattern* (which accounts, which
//    amounts) of that person's most recent real `Paycheck`
//    (`person.paychecksArray.first`) verbatim — "same amounts" is the
//    simplest reading of "if none of the allocations change" from the spec,
//    and avoids guessing at a scaling factor nothing in the schema informs.
//  - Promotion-end awareness (the one rule worth re-reading twice): a split
//    is dropped from a *projected* occurrence when its account's
//    `actualBonusDate != nil` — the bonus already posted, so there's no
//    more reason to keep feeding that account. Dropping a split from the
//    generated list, rather than re-summing it elsewhere, is enough on its
//    own to "redirect" that money into the projected remainder — the
//    remainder is computed as total minus whatever splits remain, exactly
//    like `Paycheck.unallocatedAmountDecimal` does for real rows.
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
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Person.name, ascending: true)])
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

    var body: some View {
        NavigationStack {
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
    /// round 2. Only reachable now when there are zero real paychecks AND
    /// nothing to project — and generating a projection always requires an
    /// existing real paycheck to repeat the split pattern of (see
    /// `projectedPaychecks` below), so "no real paychecks" already implies
    /// "no projections" too. The action below only appears once a Person
    /// exists to attach the new paycheck to.
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
            // Nothing to repeat without a real paycheck on record.
            guard let lastReal = person.paychecksArray.first else { continue }

            let pattern: [(account: Account, amount: Decimal)] = lastReal.directDepositsArray.compactMap { deposit in
                guard let account = deposit.account else { return nil }
                return (account, deposit.amountDecimal)
            }

            let remainderAccount = lastReal.remainderAccount

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

                results.append(
                    ProjectedPaycheck(
                        id: "\(person.id.uuidString)-\(occurrence)",
                        person: person,
                        payDate: payDate,
                        totalAmount: lastReal.totalAmountDecimal,
                        splits: splits,
                        remainderAccount: remainderAccount
                    )
                )

                payDate = Self.advance(payDate, by: person.payFrequencyValue)
            }
        }

        return results
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
}

#Preview("Empty, no person yet") {
    // A fresh, unseeded in-memory store (not `.preview`, which is
    // pre-populated with sample data) to exercise the true empty state
    // with no Person to attach a paycheck to.
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Empty, with a person") {
    // A person exists but hasn't logged a paycheck yet — the empty state's
    // "Add Paycheck" action should be live in this state. Also exercises
    // "nothing to project": a person with no real paycheck yet has no
    // pattern to repeat, so projections stay empty too.
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
}

#Preview("Materialize flow (tap a projected entry)") {
    // Same populated store as above — open this preview in Xcode's canvas,
    // tap a dashed "Projected" row, and confirm "Create this Paycheck" to
    // watch it turn into a real row and open the edit sheet.
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Dark mode") {
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
