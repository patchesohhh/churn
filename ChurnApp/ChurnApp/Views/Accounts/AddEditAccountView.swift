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
                bonusSection
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
            TextField("Bank Name", text: $bankName)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif

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

            Picker("Eligibility Window", selection: $eligibilityMonths) {
                Text("12 months").tag(Int16(12))
                Text("24 months").tag(Int16(24))
            }
            .pickerStyle(.segmented)
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
        guard let amount = bonusAmountDecimal, amount > 0 else { return false }
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
        notes = account.notes ?? ""
    }

    // MARK: - Save

    private func save() {
        didAttemptSave = true
        guard isValid, let amount = bonusAmountDecimal, let selectedPersonID else { return }

        let target = account ?? Account(context: viewContext)
        if account == nil {
            target.id = UUID()
            target.createdAt = Date()
            target.isArchived = false
        }

        target.person = viewContext.object(with: selectedPersonID) as? Person
        target.bankName = bankName.trimmingCharacters(in: .whitespaces)
        target.accountTypeValue = accountType
        target.openingDate = openingDate
        target.bonusAmountDecimal = amount
        target.bonusStructureValue = bonusStructure
        target.bonusRequirements = bonusRequirements
        target.minimumBalance = hasMinimumBalance ? NSDecimalNumber(string: minimumBalanceText.isEmpty ? "0" : minimumBalanceText) : nil
        target.expectedBonusDate = hasExpectedBonusDate ? expectedBonusDate : nil
        target.accountStatusValue = accountStatus
        target.eligibilityMonths = eligibilityMonths
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

#Preview("No people yet") {
    AddEditAccountView(account: nil)
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Dark mode") {
    AddEditAccountView(account: nil)
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
