//
//  CalendarView.swift
//  ChurnApp
//
//  Calendar tab — schedule of direct deposits grouped by month.
//
//  NOTE ON SCOPE: the original UI doc specs a vertical Gantt chart with
//  colored bars and connectors linking consecutive direct deposits to the
//  same bank. That is explicitly out of scope for this build (see
//  CLAUDE.md, "Explicitly out of scope"). This is the simple flat/grouped
//  list stand-in instead — a native `List` with monthly `Section`s. The one
//  piece of the original scheme worth keeping is flagging `isFirstToBank`
//  deposits, since "did this actually post as a real DD" is a genuinely
//  useful thing to check at a glance; that doesn't require any Gantt/bar
//  machinery to show.
//

import CoreData
import SwiftUI

struct CalendarView: View {

    /// All direct deposits, oldest first. Grouping into months happens in
    /// `groupedByMonth` below rather than in the fetch request itself —
    /// Core Data has no notion of "group by calendar month" server-side.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DirectDeposit.scheduledDate, ascending: true)]
    )
    private var deposits: FetchedResults<DirectDeposit>

    /// Upcoming/All toggle. Kept as a simple two-case filter rather than a
    /// real date-range picker — this is the v1 stand-in, not a full
    /// calendar app.
    @State private var filter: Filter = .upcoming

    private enum Filter: String, CaseIterable, Identifiable {
        case upcoming = "Upcoming"
        case all = "All"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Group {
                if deposits.isEmpty {
                    EmptyStateView(
                        systemImageName: "calendar",
                        title: "No Direct Deposits Scheduled",
                        message: "Direct deposits you schedule against an account will show up here."
                    )
                } else if filteredDeposits.isEmpty {
                    // All deposits are in the past and the user is filtered
                    // to "Upcoming" — distinguish this from the true-empty
                    // state above so it's clear switching to "All" would help.
                    EmptyStateView(
                        systemImageName: "calendar.badge.checkmark",
                        title: "No Upcoming Deposits",
                        message: "Every scheduled deposit is in the past. Switch to \"All\" to see the full history."
                    )
                } else {
                    List {
                        ForEach(groupedByMonth, id: \.month) { group in
                            Section {
                                ForEach(group.deposits, id: \.id) { deposit in
                                    DirectDepositRow(deposit: deposit)
                                }
                            } header: {
                                Text(group.monthTitle)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                // Only worth showing once there's more than one deposit to
                // filter — an empty/near-empty list doesn't need the control.
                if !deposits.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }
            }
        }
    }

    // MARK: - Filtering & grouping

    private var filteredDeposits: [DirectDeposit] {
        switch filter {
        case .all:
            return Array(deposits)
        case .upcoming:
            let startOfToday = Calendar.current.startOfDay(for: .now)
            return deposits.filter { $0.scheduledDate >= startOfToday }
        }
    }

    private struct MonthGroup {
        let month: Date
        let monthTitle: String
        let deposits: [DirectDeposit]
    }

    /// Buckets `filteredDeposits` by calendar month, preserving chronological
    /// order (the fetch is already sorted ascending, so a simple ordered
    /// walk is enough — no need to re-sort dictionary keys afterward).
    private var groupedByMonth: [MonthGroup] {
        var order: [Date] = []
        var buckets: [Date: [DirectDeposit]] = [:]

        for deposit in filteredDeposits {
            let components = Calendar.current.dateComponents([.year, .month], from: deposit.scheduledDate)
            let monthStart = Calendar.current.date(from: components) ?? deposit.scheduledDate
            if buckets[monthStart] == nil {
                buckets[monthStart] = []
                order.append(monthStart)
            }
            buckets[monthStart]?.append(deposit)
        }

        return order.map { month in
            MonthGroup(month: month, monthTitle: Self.monthFormatter.string(from: month), deposits: buckets[month] ?? [])
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}

// MARK: - DirectDepositRow

/// A single scheduled/posted deposit: date, destination bank/person, amount,
/// and status — plus a "First DD" flag when relevant.
private struct DirectDepositRow: View {

    let deposit: DirectDeposit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(deposit.scheduledDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.subheadline.weight(.semibold))

                    if deposit.isFirstToBank {
                        GenericStatusBadge(text: "First DD", color: .purple, systemImageName: "sparkles")
                    }
                }

                // Bank/person destination. `account` and `person` are both
                // nullify-on-delete relationships, so either can be nil if
                // the parent record was removed independently of this
                // deposit — fall back to placeholder text rather than
                // crashing or showing a blank row.
                Text(destinationLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let notes = deposit.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                MoneyText(amount: deposit.amountDecimal, size: .small)
                GenericStatusBadge(
                    text: deposit.statusValue.displayName,
                    color: statusColor,
                    systemImageName: statusSymbolName
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var destinationLine: String {
        let bank = deposit.account?.bankName ?? "Unassigned Account"
        let person = deposit.person?.name ?? "Unassigned Person"
        return "\(bank) · \(person)"
    }

    /// No existing status→color mapping for `DirectDepositStatus` in
    /// `Models/Enums.swift` (unlike `AccountStatus.color`), so this picks a
    /// sensible one inline rather than growing the enum for a single view's
    /// sake: scheduled = blue (matches "active/in progress" elsewhere in the
    /// app), posted = green (money landed), skipped = gray (inert).
    private var statusColor: Color {
        switch deposit.statusValue {
        case .scheduled: .blue
        case .posted: .green
        case .skipped: .gray
        }
    }

    private var statusSymbolName: String {
        switch deposit.statusValue {
        case .scheduled: "clock"
        case .posted: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }
}

// MARK: - Previews

#Preview("Populated") {
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Empty") {
    // A fresh, unseeded in-memory store (not `.preview`, which is
    // pre-populated with sample data) to exercise the true empty state.
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Dark mode") {
    CalendarView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
