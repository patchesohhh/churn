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
        }
        .navigationTitle(isEditing ? "Edit Person" : "Add Person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .onAppear(perform: populateFromExistingPerson)
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Identity") {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.words)

            if didAttemptSave && name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Name is required.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextField("Default Bank (optional)", text: $defaultBankName)
                .textInputAutocapitalization(.words)
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
                    .keyboardType(.decimalPad)
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

        let target = person ?? Person(context: viewContext)
        let now = Date()
        if person == nil {
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
            dismiss()
        } catch {
            assertionFailure("Failed to save person: \(error)")
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
