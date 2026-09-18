//
//  BankPicker.swift
//  ChurnApp
//
//  Reusable "pick a bank" form row for the Account and Offer add/edit
//  sheets. Suggests a short list of well-known banks, but also lets the
//  user type anything else — round 2's `Bank` entity is additive alongside
//  the existing `bankName` string (see CLAUDE.md), so this component always
//  keeps both in sync: picking/typing a name finds-or-creates the matching
//  `Bank` row (`BankLookup.findOrCreate`) and writes its name into
//  `bankNameText`, so every existing view that reads `account.bankName` /
//  `offer.bankName` keeps working unchanged.
//
//  Built as a `NavigationLink` row rather than a `Menu` so it can host a
//  real `.searchable` list — a dozen-plus well-known names plus free typing
//  doesn't fit comfortably in a `Menu`, and `NavigationLink` is the native
//  fit for a `Form` row that pushes a bigger picking surface (same pattern
//  iOS Settings uses for e.g. "Language").
//

import CoreData
import SwiftUI

struct BankPicker: View {

    /// The resolved `Bank` row, kept in sync with `bankNameText`. Callers
    /// should assign this straight to `account.bank` / `offer.bank` on save.
    @Binding var selectedBank: Bank?
    /// The display name, kept in sync with `selectedBank`. Callers should
    /// assign this straight to `account.bankName` / `offer.bankName` on
    /// save — it's what every round-1 view already renders.
    @Binding var bankNameText: String

    /// A reasonable, non-exhaustive set of banks people commonly churn
    /// through. Anything else is a tap away via the search field's "Use
    /// this name" option in `BankSelectionList`.
    static let wellKnownBankNames: [String] = [
        "Chase", "Wells Fargo", "Bank of America", "Capital One", "SoFi",
        "Ally", "Discover", "Citi", "US Bank", "Chime", "American Express",
        "PNC", "TD Bank"
    ]

    var body: some View {
        NavigationLink {
            BankSelectionList(selectedBank: $selectedBank, bankNameText: $bankNameText)
        } label: {
            HStack {
                Text("Bank")
                Spacer()
                Text(bankNameText.isEmpty ? "Select a bank" : bankNameText)
                    .foregroundStyle(bankNameText.isEmpty ? Color.secondary : Color.primary)
            }
        }
    }
}

/// The pushed picking surface: a searchable list of well-known banks plus a
/// "use what I typed" option when the search text doesn't match one.
private struct BankSelectionList: View {

    @Binding var selectedBank: Bank?
    @Binding var bankNameText: String

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredWellKnown: [String] {
        guard !trimmedSearch.isEmpty else { return BankPicker.wellKnownBankNames }
        return BankPicker.wellKnownBankNames.filter { $0.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    /// True when the typed text isn't an exact (case-insensitive) match for
    /// a well-known name — offers it as a custom entry instead of forcing
    /// the user to find their bank in the list.
    private var showsCustomOption: Bool {
        !trimmedSearch.isEmpty && !BankPicker.wellKnownBankNames.contains {
            $0.caseInsensitiveCompare(trimmedSearch) == .orderedSame
        }
    }

    var body: some View {
        List {
            if showsCustomOption {
                Section {
                    Button {
                        select(trimmedSearch)
                    } label: {
                        Label("Use “\(trimmedSearch)”", systemImage: "plus.circle")
                    }
                }
            }

            Section {
                ForEach(filteredWellKnown, id: \.self) { name in
                    Button {
                        select(name)
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if name.caseInsensitiveCompare(bankNameText) == .orderedSame {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Well-Known Banks")
            }
        }
        .searchable(text: $searchText, prompt: "Search or type a bank name")
        .navigationTitle("Bank")
        .toolbarTitleDisplayMode(.inline)
    }

    /// Finds-or-creates the `Bank` row for `name`, writes both bindings, and
    /// dismisses back to the form — the whole point of pushing this list is
    /// a single tap resolves the selection.
    private func select(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bank = BankLookup.findOrCreate(name: trimmed, in: viewContext)
        selectedBank = bank
        bankNameText = bank.name
        dismiss()
    }
}

// MARK: - Previews

#Preview("No selection") {
    NavigationStack {
        Form {
            Section("Bank") {
                BankPicker(selectedBank: .constant(nil), bankNameText: .constant(""))
            }
        }
    }
    .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Well-known bank selected") {
    NavigationStack {
        Form {
            Section("Bank") {
                BankPicker(selectedBank: .constant(nil), bankNameText: .constant("Chase"))
            }
        }
    }
    .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Custom bank selected") {
    NavigationStack {
        Form {
            Section("Bank") {
                BankPicker(selectedBank: .constant(nil), bankNameText: .constant("My Local Credit Union"))
            }
        }
    }
    .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Selection list") {
    NavigationStack {
        BankSelectionList(selectedBank: .constant(nil), bankNameText: .constant("Chase"))
    }
    .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
