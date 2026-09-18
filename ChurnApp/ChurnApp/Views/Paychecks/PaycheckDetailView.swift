//
//  PaycheckDetailView.swift
//  ChurnApp
//
//  Detail screen for one Paycheck: date, total, its DirectDeposit splits,
//  and the same live remainder line AddEditPaycheckView shows while
//  editing. Pushed from CalendarView. Mirrors AccountDetailView's
//  edit/delete menu pattern.
//

import CoreData
import SwiftUI

struct PaycheckDetailView: View {

    @ObservedObject var paycheck: Paycheck

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var isPresentingEdit = false
    @State private var isPresentingDeleteConfirm = false

    /// Set the instant `delete()` starts, *before* the managed object is
    /// actually removed. `paycheck` is `@ObservedObject`, so deleting it
    /// fires `objectWillChange` and forces a `body` re-render before
    /// `dismiss()` has torn the view down — without this guard that
    /// re-render reads `paycheck.payDate` / `paycheck.person.name` on a
    /// now-deleted (faulted) managed object and crashes. Also checked via
    /// `paycheck.isDeleted`/`managedObjectContext == nil` as a second
    /// signal, in case something else deletes this object out from under
    /// the view without going through this view's own `delete()`.
    @State private var isBeingDeleted = false

    private var isPaycheckGone: Bool {
        isBeingDeleted || paycheck.isDeleted || paycheck.managedObjectContext == nil
    }

    var body: some View {
        if isPaycheckGone {
            // Deliberately touch nothing on `paycheck` here — render a
            // minimal placeholder while `dismiss()` finishes tearing the
            // view down, instead of the real content that would fault.
            Color.clear
        } else {
            content
        }
    }

    private var content: some View {
        List {
            headerSection
            splitsSection
            remainderSection
        }
        .navigationTitle("Paycheck")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isPresentingEdit = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
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
            AddEditPaycheckView(person: paycheck.person, paycheck: paycheck)
        }
        .confirmationDialog(
            "Delete this paycheck?",
            isPresented: $isPresentingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                delete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // `Paycheck.directDeposits` is cascade — deleting a paycheck
            // takes its split rows with it. Say so up front rather than
            // let that be a surprise.
            Text("This permanently removes the paycheck and all of its splits. This can't be undone.")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(paycheck.payDate.formatted(date: .long, time: .omitted))
                        .font(.title3.weight(.semibold))
                    Spacer()
                    allocationBadge
                }

                Label(paycheck.person.name, systemImage: "person.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                MoneyText(amount: paycheck.totalAmountDecimal, size: .large)
            }
            .padding(.vertical, 4)
        }
        .listRowSeparator(.hidden)
    }

    private var allocationBadge: some View {
        let remainder = paycheck.unallocatedAmountDecimal
        return GenericStatusBadge(
            text: allocationText(for: remainder),
            color: allocationColor(for: remainder),
            systemImageName: allocationSymbolName(for: remainder)
        )
    }

    private var splitsSection: some View {
        Section("Splits") {
            let splits = paycheck.directDepositsArray
            if splits.isEmpty {
                Text("No splits assigned yet — the full amount routes to the home account.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(splits, id: \.id) { deposit in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deposit.account?.bankName ?? "Unassigned Account")
                            if let last4 = deposit.account?.accountNumberLast4, !last4.isEmpty {
                                Text("••••\(last4)")
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

    /// Same live remainder presentation as AddEditPaycheckView — negative
    /// (over-allocated) is deliberately never clamped, it's a warning state.
    private var remainderSection: some View {
        Section {
            let remainder = paycheck.unallocatedAmountDecimal
            if remainder < 0 {
                Label {
                    HStack(spacing: 4) {
                        Text("Over-allocated by")
                        MoneyText(amount: abs(remainder), size: .small, color: .red)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            } else {
                Label {
                    HStack(spacing: 4) {
                        Text("Unallocated:")
                        MoneyText(amount: remainder, size: .small)
                        Text(homeAccountDescription)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
            }
        }
    }

    /// Reflects the real `Paycheck.remainderAccount` — nil means no
    /// destination has been chosen, shown as a neutral state rather than
    /// guessing at "the" home account.
    private var homeAccountDescription: String {
        if let account = paycheck.remainderAccount {
            if let last4 = account.accountNumberLast4, !last4.isEmpty {
                "→ \(account.bankName) ••••\(last4)"
            } else {
                "→ \(account.bankName)"
            }
        } else {
            "(no destination set)"
        }
    }

    private func depositStatusColor(_ status: DirectDepositStatus) -> Color {
        switch status {
        case .scheduled: .blue
        case .posted: .green
        case .skipped: .gray
        }
    }

    private func allocationText(for remainder: Decimal) -> String {
        if remainder < 0 { "Over-Allocated" }
        else if remainder == 0 { "Fully Allocated" }
        else { "Partial" }
    }

    private func allocationColor(for remainder: Decimal) -> Color {
        if remainder < 0 { .red }
        else if remainder == 0 { .green }
        else { .orange }
    }

    private func allocationSymbolName(for remainder: Decimal) -> String {
        if remainder < 0 { "exclamationmark.triangle.fill" }
        else if remainder == 0 { "checkmark.circle.fill" }
        else { "circle.lefthalf.filled" }
    }

    // MARK: - Actions

    private func delete() {
        // Flip the guard *before* touching Core Data — see `isBeingDeleted`'s
        // doc comment. This makes the forced re-render triggered by
        // `viewContext.delete(paycheck)` below render the placeholder in
        // `body` instead of re-reading properties on a faulted object.
        isBeingDeleted = true

        // Cascade: deleting the paycheck takes its DirectDeposit splits
        // with it (Paycheck.directDeposits is the cascade side).
        viewContext.delete(paycheck)
        do {
            try viewContext.save()
            dismiss()
        } catch {
            assertionFailure("Failed to delete paycheck: \(error)")
        }
    }
}

// MARK: - Previews

#Preview("Fully allocated") {
    let context = PersistenceController.preview.container.viewContext
    let paycheck = (try? context.fetch(Paycheck.fetchRequest()))?
        .first { $0.unallocatedAmountDecimal == 0 }

    return NavigationStack {
        if let paycheck {
            PaycheckDetailView(paycheck: paycheck)
        } else {
            Text("No sample paycheck found")
        }
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Partially allocated") {
    let context = PersistenceController.preview.container.viewContext
    let paycheck = (try? context.fetch(Paycheck.fetchRequest()))?
        .first { $0.unallocatedAmountDecimal > 0 }

    return NavigationStack {
        if let paycheck {
            PaycheckDetailView(paycheck: paycheck)
        } else {
            Text("No sample paycheck found")
        }
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Over-allocated warning state") {
    // Unsaved, in-place fixture (same approach as
    // AddEditPaycheckView's equivalent preview) — a $2,000 paycheck with a
    // single $2,500 split.
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

    return NavigationStack {
        PaycheckDetailView(paycheck: paycheck)
    }
    .environment(\.managedObjectContext, context)
}

#Preview("No destination set") {
    // No `remainderAccount` assigned (and no home accounts exist in this
    // fresh store at all) — exercises the neutral "(no destination set)"
    // copy rather than guessing at an implicit home account.
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

    let paycheck = Paycheck(context: context)
    paycheck.id = UUID()
    paycheck.payDate = Date()
    paycheck.totalAmount = NSDecimalNumber(string: "3200.00")
    paycheck.createdAt = Date()
    paycheck.updatedAt = Date()
    paycheck.person = person

    return NavigationStack {
        PaycheckDetailView(paycheck: paycheck)
    }
    .environment(\.managedObjectContext, context)
}

#Preview("Remainder account set") {
    // `Paycheck.remainderAccount` assigned to a real home account —
    // exercises the "→ Bank ••••1234" destination copy.
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    let person = Person(context: context)
    person.id = UUID()
    person.name = "Jordan"
    person.payFrequency = PayFrequency.biweekly.rawValue
    person.paycheckAmount = NSDecimalNumber(string: "2200.00")
    person.maxConcurrentDirectDeposits = 3
    person.createdAt = Date()
    person.updatedAt = Date()

    let homeAccount = Account(context: context)
    homeAccount.id = UUID()
    homeAccount.bankName = "Ally"
    homeAccount.accountNumberLast4 = "4821"
    homeAccount.accountType = AccountType.checking.rawValue
    homeAccount.openingDate = Date()
    homeAccount.bonusAmount = NSDecimalNumber(string: "0")
    homeAccount.bonusStructure = BonusStructure.lumpSum.rawValue
    homeAccount.bonusRequirements = ""
    homeAccount.accountStatus = AccountStatus.open.rawValue
    homeAccount.eligibilityMonths = 12
    homeAccount.isArchived = false
    homeAccount.isHomeAccount = true
    homeAccount.isChurnAccount = false
    homeAccount.createdAt = Date()
    homeAccount.updatedAt = Date()
    homeAccount.person = person

    let paycheck = Paycheck(context: context)
    paycheck.id = UUID()
    paycheck.payDate = Date()
    paycheck.totalAmount = NSDecimalNumber(string: "2200.00")
    paycheck.createdAt = Date()
    paycheck.updatedAt = Date()
    paycheck.person = person
    paycheck.remainderAccount = homeAccount

    return NavigationStack {
        PaycheckDetailView(paycheck: paycheck)
    }
    .environment(\.managedObjectContext, context)
}
