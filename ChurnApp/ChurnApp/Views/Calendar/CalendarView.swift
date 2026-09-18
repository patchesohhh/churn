//
//  CalendarView.swift
//  ChurnApp
//
//  Calendar tab — schedule of Paychecks grouped by month.
//
//  ROUND 2 REWRITE: this tab used to be a flat list of individual
//  DirectDeposit rows. The app's center of gravity moved to "route a
//  paycheck across accounts" (see CLAUDE.md round 2), so the tab now groups
//  by `Paycheck` instead — each row is one income event (date + person +
//  total), with its DirectDeposit splits and the computed remainder living
//  one tap away on PaycheckDetailView. Empty-state copy is specifically
//  "No Paychecks Scheduled" per CLAUDE.md.
//
//  NOTE ON SCOPE: still no vertical Gantt chart with bar connectors — that
//  remains explicitly out of scope (see CLAUDE.md, "Explicitly out of
//  scope"). This is the simple grouped-list stand-in.
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

    /// Drives the "who is this new paycheck for" decision below.
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Person.name, ascending: true)])
    private var people: FetchedResults<Person>

    @State private var isPresentingAdd = false
    @State private var personForNewPaycheck: Person?
    @State private var isChoosingPerson = false

    var body: some View {
        NavigationStack {
            Group {
                if paychecks.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groupedByMonth, id: \.month) { group in
                            Section(group.monthTitle) {
                                ForEach(group.paychecks, id: \.id) { paycheck in
                                    NavigationLink {
                                        PaycheckDetailView(paycheck: paycheck)
                                    } label: {
                                        PaycheckRow(paycheck: paycheck)
                                    }
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
                if !paychecks.isEmpty && !people.isEmpty {
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
        }
    }

    // MARK: - Empty state

    /// Exact copy "No Paychecks Scheduled" per CLAUDE.md. The action below
    /// only appears once a Person exists to attach the new paycheck to —
    /// with none, the copy instead points at setting one up first, rather
    /// than showing an action that would have to crash or silently no-op.
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

    // MARK: - Grouping

    private struct MonthGroup {
        let month: Date
        let monthTitle: String
        let paychecks: [Paycheck]
    }

    /// Buckets paychecks by calendar month, preserving chronological order
    /// (the fetch is already sorted ascending, so a simple ordered walk is
    /// enough — no need to re-sort dictionary keys afterward).
    private var groupedByMonth: [MonthGroup] {
        var order: [Date] = []
        var buckets: [Date: [Paycheck]] = [:]

        for paycheck in paychecks {
            let components = Calendar.current.dateComponents([.year, .month], from: paycheck.payDate)
            let monthStart = Calendar.current.date(from: components) ?? paycheck.payDate
            if buckets[monthStart] == nil {
                buckets[monthStart] = []
                order.append(monthStart)
            }
            buckets[monthStart]?.append(paycheck)
        }

        return order.map { month in
            MonthGroup(month: month, monthTitle: Self.monthFormatter.string(from: month), paychecks: buckets[month] ?? [])
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}

// MARK: - PaycheckRow

/// One paycheck: date, person, total, and a compact allocation badge —
/// green "Fully Allocated" / orange "Partial" / red "Over-Allocated",
/// driven straight off `unallocatedAmountDecimal`.
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

// MARK: - Previews

#Preview("Populated") {
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
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
    // "Add Paycheck" action should be live in this state.
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

#Preview("Dark mode") {
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
