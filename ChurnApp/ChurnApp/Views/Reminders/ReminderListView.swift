//
//  ReminderListView.swift
//  ChurnApp
//
//  Reusable reminders list. Reminders aren't their own tab (see CLAUDE.md /
//  the UI doc) — they surface inside `AccountDetailView` for a single
//  account, and potentially on Home or a future "all reminders" screen.
//  To support both without duplicating the row/swipe-action logic, this view
//  takes a plain `[Reminder]` array rather than owning its own
//  `@FetchRequest`: the caller decides how the reminders were fetched
//  (`account.remindersArray` for one account, a cross-account
//  `@FetchRequest` elsewhere), and this view is just responsible for
//  rendering + completing/deleting/scheduling them.
//
//  Sorting/grouping: reminders are shown due-date ascending with overdue
//  ones flagged via `GenericStatusBadge`, matching `Reminder.isOverdue`.
//

import CoreData
import SwiftUI

struct ReminderListView: View {

    /// Reminders to display, in whatever order the caller wants — this view
    /// re-sorts them (overdue/soonest first) before rendering.
    let reminders: [Reminder]

    /// Shown when `reminders` is empty. Defaults suit an "all reminders"
    /// context; pass a more specific message when embedding for one account.
    var emptyTitle: String = "No Reminders"
    var emptyMessage: String = "You're all caught up — nothing needs your attention."

    /// Set by the presenter when there's an add action to offer from the
    /// empty state (e.g. "Add Reminder" inside `AccountDetailView`). Left
    /// nil to omit the action button.
    var onAddReminder: (() -> Void)? = nil

    @Environment(\.managedObjectContext) private var viewContext

    private var sortedReminders: [Reminder] {
        // Overdue-and-open first, then by soonest due date — the same
        // priority order a human would triage a to-do list in.
        reminders.sorted { lhs, rhs in
            if lhs.isOverdue != rhs.isOverdue {
                return lhs.isOverdue && !rhs.isOverdue
            }
            return lhs.dueDate < rhs.dueDate
        }
    }

    var body: some View {
        if reminders.isEmpty {
            EmptyStateView(
                systemImageName: "bell.slash",
                title: emptyTitle,
                message: emptyMessage,
                actionTitle: onAddReminder != nil ? "Add Reminder" : nil,
                action: onAddReminder
            )
        } else {
            List {
                ForEach(sortedReminders) { reminder in
                    ReminderRow(reminder: reminder)
                        .swipeActions(edge: .leading) {
                            Button {
                                toggleCompleted(reminder)
                            } label: {
                                Label(
                                    reminder.isCompleted ? "Mark Incomplete" : "Complete",
                                    systemImage: reminder.isCompleted ? "arrow.uturn.backward" : "checkmark"
                                )
                            }
                            .tint(reminder.isCompleted ? .gray : .green)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(reminder)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Actions

    private func toggleCompleted(_ reminder: Reminder) {
        reminder.isCompleted.toggle()
        reminder.completedDate = reminder.isCompleted ? Date() : nil

        Task {
            if reminder.isCompleted {
                // A completed reminder has nothing left to notify about.
                NotificationService.shared.cancel(for: reminder)
            } else {
                await NotificationService.shared.schedule(for: reminder)
            }
            PersistenceController.shared.saveContext()
        }

        // Save immediately too so the UI (and any dependent @FetchRequest)
        // reflects the toggle right away; the Task above re-saves once the
        // notification identifier settles, which is a harmless no-op save
        // if nothing else changed in between.
        try? viewContext.save()
    }

    private func delete(_ reminder: Reminder) {
        NotificationService.shared.cancel(for: reminder)
        viewContext.delete(reminder)
        try? viewContext.save()
    }
}

// MARK: - Row

private struct ReminderRow: View {
    @ObservedObject var reminder: Reminder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(reminder.isCompleted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .font(.body.weight(.medium))
                    .strikethrough(reminder.isCompleted)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)

                HStack(spacing: 6) {
                    Label(reminder.reminderTypeValue.displayName, systemImage: reminder.reminderTypeValue.systemImageName)
                    Text("·")
                    Text(reminder.account.bankName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(reminder.dueDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(reminder.isOverdue ? .red : .secondary)
            }

            Spacer()

            if reminder.isOverdue {
                GenericStatusBadge(text: "Overdue", color: .red, systemImageName: "exclamationmark.triangle.fill")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Previews

#Preview("Populated, some overdue") {
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []
    let allReminders = accounts.flatMap(\.remindersArray)

    return NavigationStack {
        ReminderListView(reminders: allReminders)
            .navigationTitle("Reminders")
    }
    .environment(\.managedObjectContext, context)
}

#Preview("One account's reminders") {
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []
    let account = accounts.first { !$0.remindersArray.isEmpty } ?? accounts[0]

    return NavigationStack {
        ReminderListView(
            reminders: account.remindersArray,
            emptyTitle: "No Reminders for This Account",
            emptyMessage: "Add a reminder to stay on top of this account's bonus."
        )
        .navigationTitle("\(account.bankName) Reminders")
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Empty state") {
    NavigationStack {
        ReminderListView(reminders: [], onAddReminder: {})
            .navigationTitle("Reminders")
    }
    .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
