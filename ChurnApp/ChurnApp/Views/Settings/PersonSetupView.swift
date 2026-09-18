//
//  PersonSetupView.swift
//  ChurnApp
//
//  Form for creating a new household earner or editing an existing one.
//  Mirrors the shape of AddEditAccountView: local @State mirrors the
//  entity's fields (so Cancel discards cleanly instead of leaving a
//  half-edited managed object mutating the shared context), and Save writes
//  straight to Core Data via the environment's managedObjectContext — no
//  store layer for writes, per CLAUDE.md's hybrid architecture.
//

import CoreData
import SwiftUI

struct PersonSetupView: View {

    /// Nil for "add new", non-nil for "edit existing" — same one-view,
    /// optional-subject pattern as `AddEditAccountView`.
    let person: Person?

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state

    @State private var name = ""
    @State private var payFrequency: PayFrequency = .biweekly
    @State private var paycheckAmountText = ""
    @State private var hasNextPaycheckDate = false
    @State private var nextPaycheckDate = Date()
    @State private var maxConcurrentDirectDeposits = 1
    @State private var defaultBankName = ""
    @State private var colorTag = "blue"

    @State private var didAttemptSave = false

    /// After a *new* person is saved, offer the natural next step —
    /// setting up their first paycheck — instead of just dismissing.
    /// Round 2: "onboarding entry point" per CLAUDE.md. Editing an existing
    /// person never triggers this; there's nothing "next" about an edit.
    @State private var savedPerson: Person?

    /// Dedicated target for the paycheck-setup sheet, set directly (and only)
    /// from the "Set Up First Paycheck" button's own action. Deliberately
    /// NOT derived from `savedPerson` + `isPresentingAddPaycheck` — that
    /// combination raced against the confirmation dialog's own
    /// dismiss-driven binding (which nils `savedPerson` as a side effect of
    /// dismissing) and could open the sheet with the `if let` already
    /// failing, producing a blank modal. `.sheet(item:)` keyed on this gives
    /// the sheet a presentation lifecycle fully independent of the dialog's.
    @State private var personForPaycheckSheet: Person?

    /// Round 4: "Delete Person" is a *soft* delete (`person.isArchived = true`),
    /// never `context.delete(person)` — see CLAUDE.md. History must survive.
    @State private var isConfirmingDelete = false

    private var isEditing: Bool { person != nil }

    /// Small, fixed palette of system color names for telling the two
    /// household earners apart at a glance across the app (person rows,
    /// account cards, etc.). Deliberately not a full `ColorPicker` — the
    /// task only needs "pick one of a handful of distinguishable tints",
    /// and a free-form color picker would let the user choose two colors
    /// too close to tell apart.
    private static let colorPalette: [(name: String, color: Color)] = [
        ("blue", .blue),
        ("purple", .purple),
        ("green", .green),
        ("orange", .orange),
        ("pink", .pink),
        ("teal", .teal),
        ("red", .red),
        ("indigo", .indigo),
    ]

    var body: some View {
        Form {
            identitySection
            payStructureSection
            directDepositSection
            colorSection
            // Edit mode only — there's nothing to delete in the "add" flow.
            if isEditing {
                deleteSection
            }
        }
        .navigationTitle(isEditing ? "Edit Person" : "Add Person")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // `savedPerson != nil` means this "add" session already
                // created its Person (the "set up first paycheck?" dialog is
                // up or was just dismissed). Without this guard, dismissing
                // that dialog by tapping outside it (not "Set Up First
                // Paycheck" or "Later") leaves this fully-filled form
                // sitting there with Save still enabled — a second tap
                // would run the add-mode branch of `save()` again and
                // insert a duplicate `Person` from the same session.
                Button("Save") { save() }
                    .disabled(!isValid || savedPerson != nil)
            }
        }
        .onAppear(perform: populateFromExistingPerson)
        // Lightweight confirmation step after a *new* person is saved — not
        // a multi-step wizard, just one extra prompt pointing at the
        // natural next action.
        .confirmationDialog(
            "Paycheck Info Saved",
            isPresented: Binding(
                get: { savedPerson != nil },
                set: { if !$0 { savedPerson = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Set Up First Paycheck") {
                // Capture into the sheet's own dedicated state directly from
                // `savedPerson`, which is known non-nil here (this dialog
                // only shows when it is) — not through the dialog's
                // presentation binding, so the sheet's identity can't be
                // undone by that binding's `set` nil-ing `savedPerson` out
                // from under it.
                personForPaycheckSheet = savedPerson
            }
            Button("Later", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("Want to set up \(savedPerson?.name ?? "their") first paycheck now?")
        }
        .sheet(item: $personForPaycheckSheet, onDismiss: { dismiss() }) { person in
            AddEditPaycheckView(person: person, paycheck: nil)
        }
        // Reassurance is the whole point of this dialog: the user is pressing
        // a destructive-looking button and needs to know their bookkeeping
        // history isn't going anywhere.
        .confirmationDialog(
            "Delete \(person?.name ?? "Person")?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Person", role: .destructive) { archivePerson() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This keeps \(person?.name ?? "this person")'s paycheck and account history — it just stops them from being offered for new paychecks and accounts.")
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Identity") {
            TextField("Name", text: $name)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif

            if didAttemptSave && name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Name is required.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextField("Default Bank (optional)", text: $defaultBankName)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
        }
    }

    private var payStructureSection: some View {
        Section("Pay Structure") {
            Picker("Pay Frequency", selection: $payFrequency) {
                ForEach(PayFrequency.allCases) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }

            HStack {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Paycheck Amount", text: $paycheckAmountText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }

            if didAttemptSave && paycheckAmountDecimal == nil {
                Text("Enter a valid amount.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if didAttemptSave && (paycheckAmountDecimal ?? -1) < 0 {
                Text("Paycheck amount can't be negative.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("Has Next Paycheck Date", isOn: $hasNextPaycheckDate.animation())
            if hasNextPaycheckDate {
                DatePicker("Next Paycheck", selection: $nextPaycheckDate, displayedComponents: .date)
            }
        }
    }

    private var directDepositSection: some View {
        Section {
            Stepper(
                "Max Concurrent Direct Deposits: \(maxConcurrentDirectDeposits)",
                value: $maxConcurrentDirectDeposits,
                in: 1...10
            )
        } header: {
            Text("Direct Deposit Limit")
        } footer: {
            // Rationale carried over from the source docs: this caps how
            // many accounts can be actively churned at once for this
            // person, since most employers only allow splitting a paycheck
            // across a fixed number of destinations.
            Text("How many ways your employer lets you split a single paycheck. This caps how many accounts you can churn at once.")
        }
    }

    private var colorSection: some View {
        Section("Display Color") {
            HStack(spacing: 16) {
                ForEach(Self.colorPalette, id: \.name) { swatch in
                    Button {
                        colorTag = swatch.name
                    } label: {
                        Image(systemName: colorTag == swatch.name ? "circle.inset.filled" : "circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(swatch.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name.capitalized)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Bottom-of-form destructive action, per the user's request. Only built
    /// in edit mode (see `body`).
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete Person", systemImage: "trash")
            }
        } footer: {
            Text("Their past paychecks, direct deposits, and accounts stay exactly as they are.")
        }
    }

    // MARK: - Validation

    private var paycheckAmountDecimal: Decimal? {
        Decimal(string: paycheckAmountText.trimmingCharacters(in: .whitespaces))
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let amount = paycheckAmountDecimal, amount >= 0 else { return false }
        return true
    }

    // MARK: - Populate (edit mode)

    private func populateFromExistingPerson() {
        guard let person else { return }

        name = person.name
        payFrequency = person.payFrequencyValue
        paycheckAmountText = NSDecimalNumber(decimal: person.paycheckAmountDecimal).stringValue
        if let next = person.nextPaycheckDate {
            hasNextPaycheckDate = true
            nextPaycheckDate = next
        }
        maxConcurrentDirectDeposits = max(1, Int(person.maxConcurrentDirectDeposits))
        defaultBankName = person.defaultBankName ?? ""
        colorTag = person.colorTag ?? "blue"
    }

    // MARK: - Save

    private func save() {
        didAttemptSave = true
        guard isValid, let amount = paycheckAmountDecimal else { return }

        let isNewPerson = person == nil
        let target = person ?? Person(context: viewContext)
        let now = Date()
        if isNewPerson {
            target.id = UUID()
            target.createdAt = now
        }

        target.name = name.trimmingCharacters(in: .whitespaces)
        target.payFrequencyValue = payFrequency
        target.paycheckAmountDecimal = amount
        target.nextPaycheckDate = hasNextPaycheckDate ? nextPaycheckDate : nil
        target.maxConcurrentDirectDeposits = Int16(maxConcurrentDirectDeposits)
        let trimmedBank = defaultBankName.trimmingCharacters(in: .whitespaces)
        target.defaultBankName = trimmedBank.isEmpty ? nil : trimmedBank
        target.colorTag = colorTag
        target.updatedAt = now

        do {
            try viewContext.save()
            if isNewPerson {
                // Prompt toward the next step instead of dismissing
                // immediately — see the `.confirmationDialog` in `body`.
                savedPerson = target
            } else {
                dismiss()
            }
        } catch {
            assertionFailure("Failed to save person: \(error)")
        }
    }

    // MARK: - Soft delete

    /// Sets the archive flag and saves — deliberately NOT
    /// `viewContext.delete(person)`. A real delete would cascade through
    /// `Person.paychecks` (and their `DirectDeposit` splits) and wipe the
    /// history the user still needs to see. CLAUDE.md, round 4.
    private func archivePerson() {
        guard let person else { return }

        person.isArchived = true
        person.updatedAt = Date()

        do {
            try viewContext.save()
            dismiss()
        } catch {
            assertionFailure("Failed to archive person: \(error)")
        }
    }
}

// MARK: - Previews

#Preview("New person") {
    NavigationStack {
        PersonSetupView(person: nil)
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}

#Preview("Edit existing person") {
    let context = PersistenceController.preview.container.viewContext
    let person = (try? context.fetch(Person.fetchRequest()))?.first

    return NavigationStack {
        PersonSetupView(person: person)
            .environment(\.managedObjectContext, context)
    }
}

#Preview("Dark mode") {
    NavigationStack {
        PersonSetupView(person: nil)
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
