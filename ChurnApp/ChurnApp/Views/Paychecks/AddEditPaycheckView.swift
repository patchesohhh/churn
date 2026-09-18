//
//  AddEditPaycheckView.swift
//  ChurnApp
//
//  Form-based sheet for creating a new Paycheck or editing an existing one,
//  always attached to a specific Person (`Paycheck.person` is non-optional —
//  a paycheck with no earner is meaningless, same rule as
//  `Reminder`/`Account`). Below the paycheck's own date/amount, the form
//  manages its `DirectDeposit` splits inline: each split routes a slice of
//  this paycheck to one account, and whatever isn't split lands in the
//  household's home account (a computed remainder — see
//  `Paycheck.unallocatedAmountDecimal`).
//
//  Mirrors AddEditAccountView/AddEditReminderView's pattern: plain @State
//  mirrors the entity's fields (and, here, its splits) so a cancelled sheet
//  never leaves a half-edited managed object graph sitting in the shared
//  context. Nothing is written to Core Data until Save.
//
//  API NOTE: `AddEditPaycheckView(person:paycheck:)` is a load-bearing
//  signature — Home/onboarding links into this sheet without waiting on the
//  rest of this feature, so don't change the initializer shape without a
//  strong reason.
//

import CoreData
import SwiftUI

struct AddEditPaycheckView: View {

    /// The earner this paycheck belongs to (or already belongs to, when
    /// editing). Always required — paychecks don't exist independent of a
    /// person, and this view never offers a person picker of its own; the
    /// presenting view decides who the paycheck is for.
    let person: Person

    /// Nil for "add new", non-nil for "edit existing".
    let paycheck: Paycheck?

    init(person: Person, paycheck: Paycheck? = nil) {
        self.person = person
        self.paycheck = paycheck
    }

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    /// Every non-archived account, for the per-split account picker. Not
    /// scoped to `person` — a household's "home" accounts often belong to
    /// the other earner, and nothing in the schema restricts a split to the
    /// paycheck owner's own accounts.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.bankName, ascending: true)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var accounts: FetchedResults<Account>

    /// Home accounts, to name where the unallocated remainder goes. Multiple
    /// are allowed by the schema (see `Account.isHomeAccount`); this view
    /// just names the first one found.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.bankName, ascending: true)],
        predicate: NSPredicate(format: "isHomeAccount == YES")
    )
    private var homeAccounts: FetchedResults<Account>

    // MARK: - Form state

    @State private var payDate = Date()
    @State private var totalAmountText = ""

    /// Splits as editable drafts. Existing `DirectDeposit`s are wrapped
    /// on-appear; "Add Split" appends an empty, unsaved draft row.
    @State private var splits: [SplitDraft] = []
    /// Existing splits the user removed via the row's delete button — held
    /// here rather than deleted immediately so a cancelled sheet doesn't
    /// touch the shared context. Actually deleted from Core Data on Save.
    @State private var removedDeposits: [DirectDeposit] = []

    @State private var didAttemptSave = false

    private var isEditing: Bool { paycheck != nil }

    var body: some View {
        NavigationStack {
            Form {
                paycheckSection
                splitsSection
                remainderSection
            }
            .navigationTitle(isEditing ? "Edit Paycheck" : "New Paycheck")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear(perform: populateFromExistingPaycheck)
        }
    }

    // MARK: - Sections

    private var paycheckSection: some View {
        Section("Paycheck") {
            LabeledContent("Person", value: person.name)

            DatePicker("Pay Date", selection: $payDate, displayedComponents: .date)

            HStack {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Total Amount", text: $totalAmountText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }

            if didAttemptSave && !isValid {
                Text("Enter a total amount greater than $0.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var splitsSection: some View {
        Section {
            ForEach($splits) { $draft in
                SplitRowView(draft: $draft, accounts: Array(accounts)) {
                    removeSplit(draft)
                }
            }

            Button {
                splits.append(SplitDraft())
            } label: {
                Label("Add Split", systemImage: "plus.circle")
            }
        } header: {
            Text("Splits")
        } footer: {
            Text("Route slices of this paycheck to the accounts you're churning. Whatever's left over automatically goes to your home account.")
        }
    }

    /// Live-updating remainder line — the whole reason this section exists
    /// separately from the splits list. Deliberately never clamps a
    /// negative value; over-allocation is a real state the user needs to
    /// see and fix, not one the UI should hide.
    private var remainderSection: some View {
        Section {
            if unallocatedAmountDecimal < 0 {
                Label {
                    HStack(spacing: 4) {
                        Text("Over-allocated by")
                        MoneyText(amount: abs(unallocatedAmountDecimal), size: .small, color: .red)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            } else {
                Label {
                    HStack(spacing: 4) {
                        Text("Unallocated:")
                        MoneyText(amount: unallocatedAmountDecimal, size: .small)
                        Text(homeAccountDescription)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
            }
        }
    }

    private var homeAccountDescription: String {
        if let home = homeAccounts.first {
            "→ \(home.bankName)"
        } else {
            "(no home account set)"
        }
    }

    // MARK: - Derived amounts

    private var totalAmountDecimal: Decimal? {
        Decimal(string: totalAmountText.trimmingCharacters(in: .whitespaces))
    }

    private var allocatedAmountDecimal: Decimal {
        splits.reduce(Decimal(0)) { $0 + ($1.parsedAmount ?? 0) }
    }

    private var unallocatedAmountDecimal: Decimal {
        (totalAmountDecimal ?? 0) - allocatedAmountDecimal
    }

    // MARK: - Validation

    /// Core Data can't enforce "greater than zero" on `totalAmount` any more
    /// than it can on `Account.bonusAmount` (same fractional-min-value
    /// limitation) — enforced here instead.
    private var isValid: Bool {
        guard let amount = totalAmountDecimal, amount > 0 else { return false }
        return true
    }

    // MARK: - Populate (edit mode)

    private func populateFromExistingPaycheck() {
        guard let paycheck else {
            // New paycheck: default the date/amount from the person's own
            // pay profile so the form isn't blank when the shape of the
            // data is already known.
            payDate = person.nextPaycheckDate ?? Date()
            if person.paycheckAmountDecimal > 0 {
                totalAmountText = NSDecimalNumber(decimal: person.paycheckAmountDecimal).stringValue
            }
            return
        }

        payDate = paycheck.payDate
        totalAmountText = NSDecimalNumber(decimal: paycheck.totalAmountDecimal).stringValue
        splits = paycheck.directDepositsArray.map { deposit in
            SplitDraft(
                existingDeposit: deposit,
                accountID: deposit.account?.objectID,
                amountText: NSDecimalNumber(decimal: deposit.amountDecimal).stringValue
            )
        }
    }

    // MARK: - Split row removal

    private func removeSplit(_ draft: SplitDraft) {
        if let existing = draft.existingDeposit {
            removedDeposits.append(existing)
        }
        splits.removeAll { $0.id == draft.id }
    }

    // MARK: - Save

    private func save() {
        didAttemptSave = true
        guard let amount = totalAmountDecimal, amount > 0 else { return }

        let target = paycheck ?? Paycheck(context: viewContext)
        if paycheck == nil {
            target.id = UUID()
            target.createdAt = Date()
            target.person = person
        }
        target.payDate = payDate
        target.totalAmountDecimal = amount
        target.updatedAt = Date()

        // Splits removed by the user only leave Core Data on Save — a
        // cancelled sheet must never mutate the shared context.
        for deposit in removedDeposits {
            viewContext.delete(deposit)
        }

        for draft in splits {
            guard let accountID = draft.accountID,
                  let account = viewContext.object(with: accountID) as? Account,
                  let splitAmount = draft.parsedAmount,
                  splitAmount > 0
            else { continue }

            let deposit = draft.existingDeposit ?? DirectDeposit(context: viewContext)
            if draft.existingDeposit == nil {
                deposit.id = UUID()
                deposit.createdAt = Date()
                deposit.statusValue = .scheduled
                deposit.sequenceNumberInSeries = 0
                deposit.isFirstToBank = false
                deposit.paycheck = target
            }
            deposit.account = account
            deposit.person = target.person
            deposit.amountDecimal = splitAmount
            deposit.scheduledDate = target.payDate
            deposit.updatedAt = Date()
        }

        do {
            try viewContext.save()
            dismiss()
        } catch {
            assertionFailure("Failed to save paycheck: \(error)")
        }
    }
}

// MARK: - SplitDraft

/// An editable, unsaved mirror of one `DirectDeposit` split row. Wraps an
/// existing deposit (`existingDeposit != nil`) when editing, or represents a
/// brand-new, not-yet-persisted split otherwise.
private struct SplitDraft: Identifiable {
    let id = UUID()
    var existingDeposit: DirectDeposit?
    var accountID: NSManagedObjectID?
    var amountText: String = ""

    var parsedAmount: Decimal? {
        Decimal(string: amountText.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - SplitRowView

/// One split row: account picker (labelled by bank name, plus last-4 when
/// set — the same field a user cross-references against their paystub) and
/// an amount field, with a trailing delete button.
private struct SplitRowView: View {

    @Binding var draft: SplitDraft
    let accounts: [Account]
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Account", selection: $draft.accountID) {
                    Text("Select Account").tag(NSManagedObjectID?.none)
                    ForEach(accounts, id: \.objectID) { account in
                        Text(accountLabel(account)).tag(NSManagedObjectID?.some(account.objectID))
                    }
                }

                HStack {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("Amount", text: $draft.amountText)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    private func accountLabel(_ account: Account) -> String {
        if let last4 = account.accountNumberLast4, !last4.isEmpty {
            "\(account.bankName) ••••\(last4)"
        } else {
            account.bankName
        }
    }
}

// MARK: - Previews

#Preview("New paycheck") {
    let context = PersistenceController.preview.container.viewContext
    let person = (try? context.fetch(Person.fetchRequest()))?.first

    return Group {
        if let person {
            AddEditPaycheckView(person: person)
        } else {
            Text("No sample person found")
        }
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Edit existing (partial allocation)") {
    let context = PersistenceController.preview.container.viewContext
    let paycheck = (try? context.fetch(Paycheck.fetchRequest()))?
        .first { $0.unallocatedAmountDecimal > 0 }

    return Group {
        if let paycheck {
            AddEditPaycheckView(person: paycheck.person, paycheck: paycheck)
        } else {
            Text("No sample paycheck found")
        }
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Over-allocated warning state") {
    // Built in-place rather than relying on SampleData, which doesn't seed
    // an over-allocated paycheck — Core Data surfaces unsaved inserted
    // objects to @FetchRequest on the same context, so this doesn't need a
    // save to render.
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let person = Person(context: context)
    person.id = UUID()
    person.name = "Sam"
    person.payFrequency = PayFrequency.biweekly.rawValue
    person.paycheckAmount = NSDecimalNumber(string: "2000.00")
    person.maxConcurrentDirectDeposits = 3
    person.createdAt = Date()
    person.updatedAt = Date()

    let paycheck = Paycheck(context: context)
    paycheck.id = UUID()
    paycheck.payDate = Date()
    paycheck.totalAmount = NSDecimalNumber(string: "2000.00")
    paycheck.createdAt = Date()
    paycheck.updatedAt = Date()
    paycheck.person = person

    let account = Account(context: context)
    account.id = UUID()
    account.bankName = "SoFi"
    account.accountType = AccountType.checking.rawValue
    account.openingDate = Date()
    account.bonusAmount = NSDecimalNumber(string: "300.00")
    account.bonusStructure = BonusStructure.lumpSum.rawValue
    account.bonusRequirements = ""
    account.accountStatus = AccountStatus.open.rawValue
    account.eligibilityMonths = 24
    account.isArchived = false
    account.createdAt = Date()
    account.updatedAt = Date()
    account.person = person

    let deposit = DirectDeposit(context: context)
    deposit.id = UUID()
    deposit.scheduledDate = Date()
    deposit.amount = NSDecimalNumber(string: "2500.00")
    deposit.status = DirectDepositStatus.scheduled.rawValue
    deposit.sequenceNumberInSeries = 1
    deposit.isFirstToBank = true
    deposit.createdAt = Date()
    deposit.updatedAt = Date()
    deposit.account = account
    deposit.person = person
    deposit.paycheck = paycheck

    return AddEditPaycheckView(person: person, paycheck: paycheck)
        .environment(\.managedObjectContext, context)
}

#Preview("No home account set") {
    // A fresh store with a person + paycheck but no `isHomeAccount` account
    // — exercises the "(no home account set)" remainder copy.
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let person = Person(context: context)
    person.id = UUID()
    person.name = "Taylor"
    person.payFrequency = PayFrequency.monthly.rawValue
    person.paycheckAmount = NSDecimalNumber(string: "3200.00")
    person.maxConcurrentDirectDeposits = 2
    person.createdAt = Date()
    person.updatedAt = Date()

    return AddEditPaycheckView(person: person)
        .environment(\.managedObjectContext, context)
}
