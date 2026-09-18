//
//  AddEditOfferView.swift
//  ChurnApp
//
//  Form-based sheet for creating or editing a manually-entered Offer. Core
//  Data itself enforces no "bonus > 0" / "non-empty name" rule (see the note
//  on Offer.bonusAmount), so this form is the one place those constraints
//  actually get checked before a save.
//

import CoreData
import SwiftUI

struct AddEditOfferView: View {

    /// Nil for "add new", non-nil for "edit existing". Kept as an optional
    /// reference rather than two separate views since the form fields and
    /// validation are identical either way.
    let offer: Offer?

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state

    @State private var bankName: String = ""
    @State private var offerTitle: String = ""
    @State private var bonusAmountText: String = ""
    @State private var requirements: String = ""

    @State private var hasExpirationDate: Bool = false
    @State private var expirationDate: Date = Date()

    @State private var eligibilityRestrictionMonths: EligibilityWindow = .none

    @State private var hasMinimumDeposit: Bool = false
    @State private var minimumDepositText: String = ""

    @State private var directDepositRequired: Bool = false

    @State private var hasMonthsToMaintain: Bool = false
    @State private var monthsToMaintainText: String = ""

    @State private var offerURLText: String = ""
    @State private var notes: String = ""
    @State private var isFavorite: Bool = false
    @State private var isActive: Bool = true

    @State private var validationMessage: String?

    private var isEditing: Bool { offer != nil }

    /// Common eligibility windows banks impose (12/24 months) plus "none" for
    /// offers with no restriction and unset for "don't know yet" — a
    /// segmented control is a faster entry path than a free-text number for
    /// the values that actually occur in practice.
    private enum EligibilityWindow: Hashable, CaseIterable {
        case unset, none, twelve, twentyFour

        var label: String {
            switch self {
            case .unset: "—"
            case .none: "None"
            case .twelve: "12 mo"
            case .twentyFour: "24 mo"
            }
        }

        var monthsValue: Int16? {
            switch self {
            case .unset: nil
            case .none: 0
            case .twelve: 12
            case .twentyFour: 24
            }
        }

        static func from(_ months: Int16?) -> EligibilityWindow {
            switch months {
            case nil: .unset
            case 0: .none
            case 12: .twelve
            case 24: .twentyFour
            default: .unset
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Offer") {
                    TextField("Bank Name", text: $bankName)
                        .textInputAutocapitalization(.words)
                    TextField("Offer Title", text: $offerTitle)
                        .textInputAutocapitalization(.words)
                    HStack {
                        Text("Bonus Amount")
                        Spacer()
                        TextField("$0.00", text: $bonusAmountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                }

                Section("Requirements") {
                    TextField("What does the user need to do to earn this bonus?", text: $requirements, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Expiration") {
                    Toggle("Has Expiration Date", isOn: $hasExpirationDate.animation())
                    if hasExpirationDate {
                        DatePicker("Expires", selection: $expirationDate, displayedComponents: .date)
                    }
                }

                Section("Eligibility") {
                    Picker("Restriction Window", selection: $eligibilityRestrictionMonths) {
                        ForEach(EligibilityWindow.allCases, id: \.self) { window in
                            Text(window.label).tag(window)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Has Minimum Deposit", isOn: $hasMinimumDeposit.animation())
                    if hasMinimumDeposit {
                        HStack {
                            Text("Minimum Deposit")
                            Spacer()
                            TextField("$0.00", text: $minimumDepositText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                        }
                    }

                    Toggle("Direct Deposit Required", isOn: $directDepositRequired)

                    Toggle("Has Minimum Maintenance Period", isOn: $hasMonthsToMaintain.animation())
                    if hasMonthsToMaintain {
                        HStack {
                            Text("Months to Maintain")
                            Spacer()
                            TextField("0", text: $monthsToMaintainText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                        }
                    }
                }

                Section("More Info") {
                    TextField("Offer URL", text: $offerURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Toggle("Favorite", isOn: $isFavorite)
                    Toggle("Active", isOn: $isActive)
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Offer" : "Add Offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onAppear(perform: loadExistingOffer)
        }
    }

    // MARK: - Load

    private func loadExistingOffer() {
        guard let offer else { return }

        bankName = offer.bankName
        offerTitle = offer.offerTitle
        bonusAmountText = Self.decimalFormatter.string(from: offer.bonusAmountDecimal as NSDecimalNumber) ?? ""
        requirements = offer.requirements

        if let expiration = offer.expirationDate {
            hasExpirationDate = true
            expirationDate = expiration
        }

        eligibilityRestrictionMonths = .from(offer.eligibilityRestrictionMonths?.int16Value)

        if let minimumDeposit = offer.minimumDeposit {
            hasMinimumDeposit = true
            minimumDepositText = Self.decimalFormatter.string(from: minimumDeposit) ?? ""
        }

        directDepositRequired = offer.directDepositRequired

        if let months = offer.monthsToMaintain?.int16Value {
            hasMonthsToMaintain = true
            monthsToMaintainText = "\(months)"
        }

        offerURLText = offer.offerURL ?? ""
        notes = offer.notes ?? ""
        isFavorite = offer.isFavorite
        isActive = offer.isActive
    }

    // MARK: - Save

    private func save() {
        let trimmedBank = bankName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = offerTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBank.isEmpty else {
            validationMessage = "Bank name is required."
            return
        }
        guard !trimmedTitle.isEmpty else {
            validationMessage = "Offer title is required."
            return
        }
        guard let bonusAmount = Decimal(string: bonusAmountText.trimmingCharacters(in: .whitespaces)),
              bonusAmount > 0 else {
            validationMessage = "Bonus amount must be greater than $0."
            return
        }

        let minimumDeposit: Decimal? = {
            guard hasMinimumDeposit else { return nil }
            return Decimal(string: minimumDepositText.trimmingCharacters(in: .whitespaces))
        }()
        let monthsToMaintain: Int16? = {
            guard hasMonthsToMaintain else { return nil }
            return Int16(monthsToMaintainText.trimmingCharacters(in: .whitespaces))
        }()

        let targetOffer = offer ?? Offer(context: viewContext)
        if offer == nil {
            targetOffer.id = UUID()
            targetOffer.createdAt = Date()
        }

        targetOffer.bankName = trimmedBank
        targetOffer.offerTitle = trimmedTitle
        targetOffer.bonusAmountDecimal = bonusAmount
        targetOffer.requirements = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        targetOffer.expirationDate = hasExpirationDate ? expirationDate : nil
        targetOffer.eligibilityRestrictionMonths = eligibilityRestrictionMonths.monthsValue.map(NSNumber.init)
        targetOffer.minimumDeposit = minimumDeposit.map { NSDecimalNumber(decimal: $0) }
        targetOffer.directDepositRequired = directDepositRequired
        targetOffer.monthsToMaintain = monthsToMaintain.map(NSNumber.init)
        let trimmedURL = offerURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        targetOffer.offerURL = trimmedURL.isEmpty ? nil : trimmedURL
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        targetOffer.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        targetOffer.isFavorite = isFavorite
        targetOffer.isActive = isActive
        targetOffer.updatedAt = Date()

        PersistenceController.shared.saveContext()
        dismiss()
    }

    /// Plain decimal formatter (no currency symbol) for pre-filling text
    /// fields from stored `Decimal` values when editing.
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}

// MARK: - Previews

#Preview("Add new") {
    AddEditOfferView(offer: nil)
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Edit existing") {
    let context = PersistenceController.preview.container.viewContext
    let offer = (try? context.fetch(Offer.fetchRequest()))?.first ?? Offer(context: context)

    return AddEditOfferView(offer: offer)
        .environment(\.managedObjectContext, context)
}

#Preview("Dark mode") {
    AddEditOfferView(offer: nil)
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
