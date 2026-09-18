//
//  AccountDetailView.swift
//  ChurnApp
//
//  Full detail screen for one Account: everything the list card summarizes,
//  plus requirements text, the full date timeline, notes, and the account's
//  reminders and direct deposits. This is the "tap an account, see all pay
//  dates" flow from the original UI doc — kept to a plain sorted list per
//  CLAUDE.md's explicit "no Gantt chart" scope cut.
//

import CoreData
import SwiftUI

struct AccountDetailView: View {

    @ObservedObject var account: Account

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var isPresentingEdit = false
    @State private var isPresentingDeleteConfirm = false

    var body: some View {
        List {
            headerSection
            detailsSection
            datesSection
            if let notes = account.notes, !notes.isEmpty {
                notesSection(notes)
            }
            remindersSection
            directDepositsSection
        }
        .navigationTitle(account.bankName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isPresentingEdit = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button {
                        archive()
                    } label: {
                        Label(account.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                    }

                    Button(role: .destructive) {
                        isPresentingDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            AddEditAccountView(account: account)
        }
        .confirmationDialog(
            "Delete this account?",
            isPresented: $isPresentingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                delete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the account and its reminders/deposits. This can't be undone.")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.bankName)
                            .font(.title2.weight(.bold))
                        Label(account.accountTypeValue.displayName, systemImage: account.accountTypeValue.systemImageName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: account.accountStatusValue)
                }

                MoneyText(
                    amount: account.bonusAmountDecimal,
                    size: .large,
                    color: account.hasBonusPosted ? .green : nil
                )

                if let person = account.person {
                    Label(person.name, systemImage: "person.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowSeparator(.hidden)
    }

    private var detailsSection: some View {
        Section("Bonus Details") {
            LabeledContent("Structure", value: account.bonusStructureValue.displayName)

            if !account.bonusRequirements.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requirements")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(account.bonusRequirements)
                }
                .padding(.vertical, 2)
            }

            if let minBalance = account.minimumBalance {
                LabeledContent("Minimum Balance") {
                    MoneyText(amount: minBalance.decimalValue, size: .small)
                }
            }

            LabeledContent("Eligibility Window", value: "\(account.eligibilityMonths) months")

            if let last4 = account.accountNumberLast4, !last4.isEmpty {
                LabeledContent("Account Number", value: "••••\(last4)")
            }
        }
    }

    private var datesSection: some View {
        Section("Timeline") {
            LabeledContent("Opened", value: account.openingDate.formatted(date: .abbreviated, time: .omitted))

            if let expected = account.expectedBonusDate {
                LabeledContent("Expected Bonus", value: expected.formatted(date: .abbreviated, time: .omitted))
            }

            if let actual = account.actualBonusDate {
                LabeledContent("Bonus Posted", value: actual.formatted(date: .abbreviated, time: .omitted))
            }

            if let closed = account.closedDate {
                LabeledContent("Closed", value: closed.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func notesSection(_ notes: String) -> some View {
        Section("Notes") {
            Text(notes)
        }
    }

    private var remindersSection: some View {
        Section("Reminders") {
            let reminders = account.remindersArray.filter { !$0.isArchived }
            if reminders.isEmpty {
                Text("No reminders for this account.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reminders, id: \.id) { reminder in
                    HStack {
                        Label(reminder.title, systemImage: reminder.reminderTypeValue.systemImageName)
                        Spacer()
                        Text(reminder.dueDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                    }
                }
            }
        }
    }

    private var directDepositsSection: some View {
        Section("Direct Deposits") {
            let deposits = account.directDepositsArray
            if deposits.isEmpty {
                Text("No direct deposits scheduled for this account.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deposits, id: \.id) { deposit in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deposit.scheduledDate.formatted(date: .abbreviated, time: .omitted))
                            if let person = deposit.person {
                                Text(person.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            MoneyText(amount: deposit.amountDecimal, size: .small)
                            GenericStatusBadge(
                                text: deposit.statusValue.displayName,
                                color: depositStatusColor(deposit.statusValue)
                            )
                        }
                    }
                }
            }
        }
    }

    private func depositStatusColor(_ status: DirectDepositStatus) -> Color {
        switch status {
        case .scheduled: .blue
        case .posted: .green
        case .skipped: .secondary
        }
    }

    // MARK: - Actions

    private func archive() {
        account.isArchived.toggle()
        account.updatedAt = Date()
        save()
    }

    private func delete() {
        viewContext.delete(account)
        save()
        dismiss()
    }

    private func save() {
        do {
            try viewContext.save()
        } catch {
            assertionFailure("Failed to save Core Data context: \(error)")
        }
    }
}

// MARK: - Previews

#Preview("Open account") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?
        .first { $0.accountStatusValue == .open }

    return NavigationStack {
        if let account {
            AccountDetailView(account: account)
        }
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Closed account, no notes/reminders") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?
        .first { $0.accountStatusValue == .closed }

    return NavigationStack {
        if let account {
            AccountDetailView(account: account)
        }
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Dark mode") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?.first

    return NavigationStack {
        if let account {
            AccountDetailView(account: account)
        }
    }
    .environment(\.managedObjectContext, context)
    .preferredColorScheme(.dark)
}
