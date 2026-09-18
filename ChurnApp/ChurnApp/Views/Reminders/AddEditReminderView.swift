//
//  AddEditReminderView.swift
//  ChurnApp
//
//  Form-based sheet for creating a new Reminder or editing an existing one,
//  always attached to a specific Account (the presenting view — typically
//  AccountDetailView — passes the account in; a reminder with no account
//  isn't meaningful, per `Reminder.account` being a required relationship).
//
//  Mirrors AddEditAccountView's pattern: plain @State mirrors the entity's
//  fields so a cancelled sheet never leaves a half-edited managed object
//  sitting in the shared context, then writes everything on Save.
//

import CoreData
import SwiftUI

struct AddEditReminderView: View {

    /// The account this reminder belongs to (or already belongs to, when
    /// editing). Always required — reminders don't exist independent of an
    /// account.
    let account: Account

    /// Nil for "add new", non-nil for "edit existing".
    let reminder: Reminder?

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state

    @State private var title = ""
    @State private var reminderType: ReminderType = .checkBonus
    @State private var dueDate = Date()
    @State private var notes = ""

    @State private var didAttemptSave = false

    private var isEditing: Bool { reminder != nil }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    TextField("Title", text: $title)

                    Picker("Type", selection: $reminderType) {
                        ForEach(ReminderType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImageName)
                                .tag(type)
                        }
                    }
                    .onChange(of: reminderType) { _, newValue in
                        // Convenience default: pre-fill the title from the
                        // type when the user hasn't typed a custom one yet,
                        // same UX shorthand a Reminders app gives you.
                        if title.isEmpty || title == reminderType.displayName {
                            title = newValue.displayName
                        }
                    }

                    DatePicker("Due Date", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                }

                Section("Notes") {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if didAttemptSave && !isValid {
                    Section {
                        Label("Title is required.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Reminder" : "New Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear(perform: populateFromExistingReminder)
        }
    }

    // MARK: - Populate / Save

    private func populateFromExistingReminder() {
        guard let reminder else { return }
        title = reminder.title
        reminderType = reminder.reminderTypeValue
        dueDate = reminder.dueDate
        notes = reminder.notes ?? ""
    }

    private func save() {
        didAttemptSave = true
        guard isValid else { return }

        let target = reminder ?? Reminder(context: viewContext)
        if reminder == nil {
            target.id = UUID()
            target.isCompleted = false
            target.isArchived = false
            target.createdAt = Date()
            target.account = account
        }

        target.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.reminderTypeValue = reminderType
        target.dueDate = dueDate
        target.notes = notes.isEmpty ? nil : notes

        // Schedule (or reschedule) the local notification, then persist.
        // The notification identifier gets written onto `target` inside
        // `schedule(for:)`, so the save has to happen after that completes.
        Task {
            await NotificationService.shared.schedule(for: target)
            PersistenceController.shared.saveContext()
        }

        dismiss()
    }
}

// MARK: - Previews

#Preview("New reminder") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?.first ?? Account(context: context)

    return AddEditReminderView(account: account, reminder: nil)
        .environment(\.managedObjectContext, context)
}

#Preview("Edit existing reminder") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?.first { !$0.remindersArray.isEmpty }
    let reminder = account?.remindersArray.first

    return Group {
        if let account, let reminder {
            AddEditReminderView(account: account, reminder: reminder)
        } else {
            Text("No sample reminder found")
        }
    }
    .environment(\.managedObjectContext, context)
}
