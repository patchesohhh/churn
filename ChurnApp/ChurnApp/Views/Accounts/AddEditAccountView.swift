//
//  AddEditAccountView.swift
//  ChurnApp
//
//  Form-based sheet for creating a new Account or editing an existing one.
//  Writes straight to Core Data via the environment's managedObjectContext
//  — no store layer for writes, per CLAUDE.md's hybrid architecture (views
//  own their own saves).
//

import CoreData
import SwiftUI

struct AddEditAccountView: View {

    /// Nil for "add new", non-nil for "edit existing". Kept as an optional
    /// rather than two separate view types so the form layout only has to
    /// be written once.
    let account: Account?

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Person.name, ascending: true)])
    private var people: FetchedResults<Person>

    // MARK: - Form state
    // Mirrors the Account entity's fields as plain SwiftUI-friendly state
    // rather than editing `account` live, so a cancel just discards the
    // sheet without leaving a half-edited managed object mutating the
    // shared context (Core Data properties are set-on-write, not staged).

    @State private var selectedPersonID: NSManagedObjectID?
    @State private var bankName = ""
    /// The `Bank` row `bankName` resolves to, kept in sync by `BankPicker`.
    /// Additive per CLAUDE.md round 2 — `bankName` stays the source of truth
    /// every existing view reads.
    @State private var selectedBank: Bank?
    @State private var accountType: AccountType = .checking
    @State private var openingDate = Date()
    @State private var bonusAmountText = ""
    @State private var bonusStructure: BonusStructure = .lumpSum
    @State private var bonusRequirements = ""
    @State private var hasMinimumBalance = false
    @State private var minimumBalanceText = ""
    @State private var hasExpectedBonusDate = false
    @State private var expectedBonusDate = Date()
    @State private var accountStatus: AccountStatus = .prospecting
    @State private var eligibilityMonths: Int16 = 12
    @State private var accountNumberLast4 = ""
    @State private var isHomeAccount = false
    /// Round 3: whether this account is running a signup bonus at all. Most
    /// home accounts aren't, so toggling `isHomeAccount` on for a *new*
    /// account (see the `onChange` below) flips this off by default; it
    /// otherwise defaults to `true`, preserving round 1/2 behavior for plain
    /// churn accounts.
    @State private var isChurnAccount = true
    @State private var notes = ""

    @State private var didAttemptSave = false

    private var isEditing: Bool { account != nil }

    var body: some View {
        NavigationStack {
            Form {
                if people.isEmpty {
                    Section {
                        Label(
                            "Add a person in Settings before creating an account — bonuses are tracked per household earner.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                } else {
                    personSection
                }

                bankSection
                accountDetailsSection
                churnToggleSection
                if isChurnAccount {
                    bonusSection
                }
                statusSection
                notesSection
            }
            .navigationTitle(isEditing ? "Edit Account" : "New Account")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear(perform: populateFromExistingAccount)
        }
    }

    // MARK: - Sections

    private var personSection: some View {
        Section("Person") {
            Picker("Account Owner", selection: $selectedPersonID) {
                Text("Select a person").tag(NSManagedObjectID?.none)
                ForEach(people, id: \.objectID) { person in
                    Text(person.name).tag(NSManagedObjectID?.some(person.objectID))
                }
            }
        }
    }

    private var bankSection: some View {
        Section("Bank") {
            BankPicker(selectedBank: $selectedBank, bankNameText: $bankName)

            if didAttemptSave && bankName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Bank name is required.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Type", selection: $accountType) {
                ForEach(AccountType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            DatePicker("Opening Date", selection: $openingDate, displayedComponents: .date)
        }
    }

    /// Round 2: last-4 is promoted from a buried optional detail to its own
    /// prominent field (what the user cross-references against their
    /// paystub), and `isHomeAccount` marks a permanent routing destination.
    /// No single-home-account constraint — multiple are allowed, so this
    /// never validates against other accounts.
    private var accountDetailsSection: some View {
        Group {
            Section {
                TextField("Last 4 Digits", text: $accountNumberLast4)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onChange(of: accountNumberLast4) { _, newValue in
                        accountNumberLast4 = String(newValue.filter(\.isNumber).prefix(4))
                    }
            } footer: {
                Text("Matches the last 4 digits shown on your paystub — this app never stores full account numbers.")
            }

            Section {
                // Not in the churn-fields-to-hide list (bonus amount/
                // structure/requirements/dates/eligibility/offer link) — a
                // plain non-churn account can still have a minimum balance
                // to avoid a monthly fee, so this stays visible regardless
                // of `isChurnAccount`.
                Toggle("Has Minimum Balance Requirement", isOn: $hasMinimumBalance.animation())
                if hasMinimumBalance {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("Minimum Balance", text: $minimumBalanceText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                }
            }

            Section {
                Toggle("This Is a Home Account", isOn: $isHomeAccount)
                    .onChange(of: isHomeAccount) { _, newValue in
                        // Round 3: most home accounts have no promo attached,
                        // so flipping this on for a *new* account defaults
                        // the churn toggle off. Only for new accounts — an
                        // existing account's `isChurnAccount` shouldn't
                        // silently flip just because the user is editing its
                        // home-account flag.
                        guard !isEditing else { return }
                        isChurnAccount = !newValue
                    }
            } footer: {
                Text("Everything else routes through this account. Multiple home accounts are allowed.")
            }
        }
    }

    /// Round 3: lets the user say "this account isn't running a bonus at
    /// all" — most pre-existing home accounts (checking/savings from before
    /// the user ever churned anything). Hides (not just disables) the
    /// bonus-specific fields below when off, and eligibility-window when off.
    private var churnToggleSection: some View {
        Section {
            Toggle("Earning a Bonus?", isOn: $isChurnAccount.animation())
        } footer: {
            Text("Turn this off for a plain account you're not running a signup bonus on.")
        }
    }

    private var bonusSection: some View {
        Section("Bonus") {
            HStack {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Amount", text: $bonusAmountText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }

            if didAttemptSave && bonusAmountDecimal == nil {
                Text("Enter a valid amount.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if didAttemptSave && (bonusAmountDecimal ?? 0) <= 0 {
                Text("Bonus amount must be greater than $0.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Structure", selection: $bonusStructure) {
                ForEach(BonusStructure.allCases) { structure in
                    Text(structure.displayName).tag(structure)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Requirements")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $bonusRequirements)
                    .frame(minHeight: 80)
            }

            Toggle("Has Expected Bonus Date", isOn: $hasExpectedBonusDate.animation())
            if hasExpectedBonusDate {
                DatePicker("Expected Bonus Date", selection: $expectedBonusDate, displayedComponents: .date)
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            Picker("Status", selection: $accountStatus) {
                ForEach(AccountStatus.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }

            if isChurnAccount {
                Picker("Eligibility Window", selection: $eligibilityMonths) {
                    Text("12 months").tag(Int16(12))
                    Text("24 months").tag(Int16(24))
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextEditor(text: $notes)
                .frame(minHeight: 80)
        }
    }

    // MARK: - Validation

    /// Parses the free-text bonus amount into a `Decimal`. `nil` means the
    /// text isn't a parseable number at all (as opposed to a parseable but
    /// non-positive one, which `isValid` checks separately so the two error
    /// messages above can be distinct).
    private var bonusAmountDecimal: Decimal? {
        Decimal(string: bonusAmountText.trimmingCharacters(in: .whitespaces))
    }

    /// Core Data's model can only enforce a non-negative bonus (it truncates
    /// fractional min-value bounds — see the comment on `Account.bonusAmount`
    /// in the entity file), so "must be greater than zero" has to be
    /// enforced here in the form rather than at the store level.
    private var isValid: Bool {
        guard !people.isEmpty, selectedPersonID != nil else { return false }
        guard !bankName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // Bonus fields are only required when this account is actually
        // running a promotion — off, they're hidden and saved with sane
        // defaults instead (see `save()`).
        if isChurnAccount {
            guard let amount = bonusAmountDecimal, amount > 0 else { return false }
        }
        return true
    }

    // MARK: - Populate (edit mode)

    private func populateFromExistingAccount() {
        guard let account else {
            // New account: default the owner to the first person if there's
            // exactly one household earner set up, otherwise leave it
            // unselected so the picker forces an explicit choice.
            if people.count == 1 {
                selectedPersonID = people.first?.objectID
            }
            return
        }

        selectedPersonID = account.person?.objectID
        bankName = account.bankName
        selectedBank = account.bank
        accountType = account.accountTypeValue
        openingDate = account.openingDate
        bonusAmountText = NSDecimalNumber(decimal: account.bonusAmountDecimal).stringValue
        bonusStructure = account.bonusStructureValue
        bonusRequirements = account.bonusRequirements
        if let minBalance = account.minimumBalance {
            hasMinimumBalance = true
            minimumBalanceText = minBalance.stringValue
        }
        if let expected = account.expectedBonusDate {
            hasExpectedBonusDate = true
            expectedBonusDate = expected
        }
        accountStatus = account.accountStatusValue
        eligibilityMonths = account.eligibilityMonths
        accountNumberLast4 = account.accountNumberLast4 ?? ""
        isHomeAccount = account.isHomeAccount
        isChurnAccount = account.isChurnAccount
        notes = account.notes ?? ""
    }

    // MARK: - Save

    private func save() {
        didAttemptSave = true
        guard isValid, let selectedPersonID else { return }

        let target = account ?? Account(context: viewContext)
        if account == nil {
            target.id = UUID()
            target.createdAt = Date()
            target.isArchived = false
        }

        target.person = viewContext.object(with: selectedPersonID) as? Person
        target.bankName = bankName.trimmingCharacters(in: .whitespaces)
        target.bank = selectedBank
        target.accountTypeValue = accountType
        target.openingDate = openingDate
        target.isChurnAccount = isChurnAccount
        if isChurnAccount {
            // `isValid` guarantees a parseable, positive amount whenever
            // `isChurnAccount` is true.
            target.bonusAmountDecimal = bonusAmountDecimal ?? 0
            target.bonusStructureValue = bonusStructure
            target.bonusRequirements = bonusRequirements
            target.expectedBonusDate = hasExpectedBonusDate ? expectedBonusDate : nil
            target.eligibilityMonths = eligibilityMonths
        } else {
            // Round 3: churn fields are hidden, not validated, when this
            // account isn't running a bonus — save harmless defaults instead
            // of whatever stale/partial text happens to be sitting in the
            // (hidden) form fields.
            target.bonusAmountDecimal = 0
            target.bonusStructureValue = .lumpSum
            target.bonusRequirements = ""
            target.expectedBonusDate = nil
            target.eligibilityMonths = 12
        }
        target.minimumBalance = hasMinimumBalance ? NSDecimalNumber(string: minimumBalanceText.isEmpty ? "0" : minimumBalanceText) : nil
        target.accountStatusValue = accountStatus
        target.accountNumberLast4 = accountNumberLast4.isEmpty ? nil : accountNumberLast4
        target.isHomeAccount = isHomeAccount
        target.notes = notes.isEmpty ? nil : notes
        target.updatedAt = Date()

        do {
            try viewContext.save()
            dismiss()
        } catch {
            assertionFailure("Failed to save account: \(error)")
        }
    }
}

// MARK: - Previews

#Preview("New account") {
    AddEditAccountView(account: nil)
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Edit existing account") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?.first

    return AddEditAccountView(account: account)
        .environment(\.managedObjectContext, context)
}

#Preview("Edit non-churn home account") {
    let context = PersistenceController.preview.container.viewContext
    let account = (try? context.fetch(Account.fetchRequest()))?
        .first { $0.isHomeAccount && !$0.isChurnAccount }

    return AddEditAccountView(account: account)
        .environment(\.managedObjectContext, context)
}

#Preview("No people yet") {
    AddEditAccountView(account: nil)
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Dark mode") {
    AddEditAccountView(account: nil)
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
