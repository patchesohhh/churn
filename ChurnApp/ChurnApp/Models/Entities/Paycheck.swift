//
//  Paycheck.swift
//  ChurnApp
//
//  One income event: "$2,400 to Alex on Sep 30". Added in round 2, when the
//  app's centre of gravity moved from "bonus tracker" to "route the employer's
//  direct deposit to the right accounts" — a paycheck is the thing being
//  routed, and each `DirectDeposit` under it is one split of that routing.
//
//  See `Person.swift` for why these classes are hand-written.
//

import CoreData
import Foundation

@objc(Paycheck)
public class Paycheck: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Paycheck> {
        NSFetchRequest<Paycheck>(entityName: "Paycheck")
    }

    // MARK: - Attributes

    @NSManaged public var id: UUID
    @NSManaged public var payDate: Date
    /// Gross amount hitting payroll for this pay date, before it's split.
    ///
    /// Money is always `NSDecimalNumber` in the store — Core Data cannot back a
    /// `Decimal` struct with `@NSManaged`. Use `totalAmountDecimal` for
    /// arithmetic; never convert money through `Double`.
    @NSManaged public var totalAmount: NSDecimalNumber
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    // MARK: - Relationships

    /// Required: a paycheck with no earner is meaningless.
    ///
    /// Delete rule is *nullify* on this side, mirroring the `Reminder.account`
    /// decision: a cascade here would mean deleting one paycheck destroys the
    /// person (and, transitively, all their accounts). The behaviour the spec
    /// actually asks for — delete a person, lose their paycheck history — is
    /// provided by the cascade on `Person.paychecks`.
    @NSManaged public var person: Person

    /// The splits of this paycheck. Cascade on *this* side only: deleting a
    /// paycheck deletes its split rows, while deleting a single split
    /// (`DirectDeposit.paycheck` is nullify) leaves the paycheck untouched.
    @NSManaged public var directDeposits: NSSet?

    /// Which home account receives this paycheck's unallocated remainder.
    ///
    /// Round 3. Optional and per-paycheck (not per-person) so a couple can route
    /// a given cheque to a shared/joint account without changing anyone's
    /// defaults. The UI seeds it from the person's own home account when one
    /// exists; the user can override it to any home account.
    ///
    /// Nullify both ways: deleting the account leaves the paycheck (and its
    /// splits) intact with no remainder destination, and deleting the paycheck
    /// never touches the account.
    @NSManaged public var remainderAccount: Account?
}

// MARK: - Typed accessors

extension Paycheck {

    /// `totalAmount` as a Swift `Decimal`.
    var totalAmountDecimal: Decimal {
        get { totalAmount.decimalValue }
        set { totalAmount = NSDecimalNumber(decimal: newValue) }
    }

    /// Splits as a stable, sorted array — `NSSet` has no order, and SwiftUI
    /// `ForEach` needs one. Ordered by position in the required DD series,
    /// then by account name, so the list doesn't reshuffle between renders
    /// when several splits share a sequence number.
    var directDepositsArray: [DirectDeposit] {
        (directDeposits as? Set<DirectDeposit> ?? []).sorted { lhs, rhs in
            if lhs.sequenceNumberInSeries != rhs.sequenceNumberInSeries {
                return lhs.sequenceNumberInSeries < rhs.sequenceNumberInSeries
            }
            return (lhs.account?.bankName ?? "") < (rhs.account?.bankName ?? "")
        }
    }

    /// Sum of every split assigned to this paycheck.
    var allocatedAmountDecimal: Decimal {
        directDepositsArray.reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    /// What's left of the paycheck after the splits — the money that lands in
    /// the home account.
    ///
    /// **Intentionally computed, never stored** (see CLAUDE.md, round 2): the
    /// remainder is a function of `totalAmount` and the split rows, so storing
    /// it would create a second source of truth that silently desyncs the
    /// moment a split is edited or deleted. The UI presents it as
    /// "→ [home account]" rather than making the user hand-create a
    /// `DirectDeposit` row for it.
    ///
    /// Can go negative if the user over-allocates (splits summing past the
    /// gross). That's deliberately not clamped — a negative remainder is the
    /// signal the UI uses to flag "you've allocated more than you earn".
    var unallocatedAmountDecimal: Decimal {
        totalAmountDecimal - allocatedAmountDecimal
    }
}

// MARK: - Generated relationship accessors

extension Paycheck {

    @objc(addDirectDepositsObject:)
    @NSManaged public func addToDirectDeposits(_ value: DirectDeposit)

    @objc(removeDirectDepositsObject:)
    @NSManaged public func removeFromDirectDeposits(_ value: DirectDeposit)

    @objc(addDirectDeposits:)
    @NSManaged public func addToDirectDeposits(_ values: NSSet)

    @objc(removeDirectDeposits:)
    @NSManaged public func removeFromDirectDeposits(_ values: NSSet)
}

extension Paycheck: Identifiable {}
