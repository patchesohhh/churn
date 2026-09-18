//
//  DirectDeposit.swift
//  ChurnApp
//
//  One scheduled or posted paycheck allocation from a `Person` to an
//  `Account`. This entity doesn't exist in the source docs — they flagged it
//  as "probably needed" and never defined it — but Home's paycheck preview,
//  the Calendar tab and per-account pay history all depend on it.
//
//  See `Person.swift` for why these classes are hand-written.
//

import CoreData
import Foundation

@objc(DirectDeposit)
public class DirectDeposit: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<DirectDeposit> {
        NSFetchRequest<DirectDeposit>(entityName: "DirectDeposit")
    }

    // MARK: - Attributes

    @NSManaged public var id: UUID
    @NSManaged public var scheduledDate: Date
    /// Money is always `NSDecimalNumber` in the store. Use `amountDecimal`.
    @NSManaged public var amount: NSDecimalNumber
    /// Raw value of `DirectDepositStatus`. Prefer `statusValue`.
    @NSManaged public var status: String
    /// Position within a required series, e.g. 3 for "3rd of 5 required DDs".
    @NSManaged public var sequenceNumberInSeries: Int16
    /// True for the first-ever deposit to a given bank. Banks differ on what
    /// they count as a "real" direct deposit, so the UI surfaces a
    /// verify-it-worked prompt on exactly this one.
    @NSManaged public var isFirstToBank: Bool
    @NSManaged public var notes: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    // MARK: - Relationships

    /// Nullify, not cascade: a deposit records something that happened to the
    /// user's payroll and shouldn't vanish just because it was un-assigned
    /// from an account. (Deleting the *account* does cascade it away.)
    @NSManaged public var account: Account?
    @NSManaged public var person: Person?
}

// MARK: - Typed accessors

extension DirectDeposit {

    /// `amount` as a Swift `Decimal`.
    var amountDecimal: Decimal {
        get { amount.decimalValue }
        set { amount = NSDecimalNumber(decimal: newValue) }
    }

    var statusValue: DirectDepositStatus {
        get { DirectDepositStatus(rawValue: status) ?? .scheduled }
        set { status = newValue.rawValue }
    }
}

extension DirectDeposit: Identifiable {}
