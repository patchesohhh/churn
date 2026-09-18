//
//  Person.swift
//  ChurnApp
//
//  One household earner. This app is built for a dual-income household, so
//  there are normally exactly two of these — but nothing enforces that.
//
//  NOTE ON CODEGEN: the `.xcdatamodeld` uses *manual* codegen and every
//  `NSManagedObject` subclass is hand-written here. Xcode's automatic codegen
//  emits `NSDecimalNumber?` for every Decimal attribute, which would leak
//  optional NSDecimalNumber into every view and calculation. Writing the
//  classes by hand lets money be a plain non-optional `Decimal` and lets the
//  String-backed attributes expose typed enum accessors.
//

import CoreData
import Foundation

@objc(Person)
public class Person: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Person> {
        NSFetchRequest<Person>(entityName: "Person")
    }

    // MARK: - Attributes

    @NSManaged public var id: UUID
    @NSManaged public var name: String
    /// Raw value of `PayFrequency`. Prefer `payFrequencyValue`.
    @NSManaged public var payFrequency: String
    /// Money is always `NSDecimalNumber` in the store — Core Data cannot back
    /// a `Decimal` struct with `@NSManaged`. Use `paycheckAmountDecimal` for
    /// arithmetic; never convert money through `Double`.
    @NSManaged public var paycheckAmount: NSDecimalNumber
    @NSManaged public var nextPaycheckDate: Date?
    /// How many direct deposits this person's employer will split a paycheck
    /// across. The hard ceiling on how many accounts they can churn at once.
    @NSManaged public var maxConcurrentDirectDeposits: Int16
    /// The person's "home" bank — where leftover pay lands.
    @NSManaged public var defaultBankName: String?
    /// A system color name (e.g. "blue", "purple") used to tint this person's
    /// rows so the two earners are distinguishable at a glance.
    @NSManaged public var colorTag: String?
    /// Soft-delete flag, same convention as `Account.isArchived` /
    /// `Reminder.isArchived` (named `isArchived` because `NSManagedObject`
    /// already defines `isDeleted`). Round 4: "delete person" archives rather
    /// than hard-deleting, because the user must keep seeing an archived
    /// person's past paychecks and direct deposits — `Paycheck.person` is
    /// non-optional and every Home/Calendar/Paycheck read of
    /// `paycheck.person.name` depends on that staying true. Archived people
    /// stay fully visible in history; they just stop being offered for *new*
    /// paychecks and accounts. Filter "current" lists with `isArchived == NO`.
    @NSManaged public var isArchived: Bool
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    // MARK: - Relationships

    @NSManaged public var accounts: NSSet?
    @NSManaged public var directDeposits: NSSet?
    /// This person's income history. Cascade on *this* side: deleting a person
    /// deletes their paycheck history (and, via `Paycheck.directDeposits`,
    /// those paychecks' splits). Deleting a single paycheck leaves the person
    /// alone — `Paycheck.person` is nullify.
    @NSManaged public var paychecks: NSSet?
}

// MARK: - Typed accessors

extension Person {

    /// `paycheckAmount` as a Swift `Decimal`.
    var paycheckAmountDecimal: Decimal {
        get { paycheckAmount.decimalValue }
        set { paycheckAmount = NSDecimalNumber(decimal: newValue) }
    }

    /// Typed view of `payFrequency`. Falls back to `.irregular` rather than
    /// crashing if the store somehow holds an unknown string.
    var payFrequencyValue: PayFrequency {
        get { PayFrequency(rawValue: payFrequency) ?? .irregular }
        set { payFrequency = newValue.rawValue }
    }

    /// Accounts as a stable, sorted array — `NSSet` has no order, and SwiftUI
    /// `ForEach` needs one.
    var accountsArray: [Account] {
        (accounts as? Set<Account> ?? []).sorted { $0.openingDate > $1.openingDate }
    }

    var directDepositsArray: [DirectDeposit] {
        (directDeposits as? Set<DirectDeposit> ?? []).sorted { $0.scheduledDate < $1.scheduledDate }
    }

    /// Paychecks newest-first — the Calendar tab and Home both read the most
    /// recent income events first.
    var paychecksArray: [Paycheck] {
        (paychecks as? Set<Paycheck> ?? []).sorted { $0.payDate > $1.payDate }
    }
}

// MARK: - Generated relationship accessors

extension Person {

    @objc(addAccountsObject:)
    @NSManaged public func addToAccounts(_ value: Account)

    @objc(removeAccountsObject:)
    @NSManaged public func removeFromAccounts(_ value: Account)

    @objc(addAccounts:)
    @NSManaged public func addToAccounts(_ values: NSSet)

    @objc(removeAccounts:)
    @NSManaged public func removeFromAccounts(_ values: NSSet)

    @objc(addDirectDepositsObject:)
    @NSManaged public func addToDirectDeposits(_ value: DirectDeposit)

    @objc(removeDirectDepositsObject:)
    @NSManaged public func removeFromDirectDeposits(_ value: DirectDeposit)

    @objc(addDirectDeposits:)
    @NSManaged public func addToDirectDeposits(_ values: NSSet)

    @objc(removeDirectDeposits:)
    @NSManaged public func removeFromDirectDeposits(_ values: NSSet)

    @objc(addPaychecksObject:)
    @NSManaged public func addToPaychecks(_ value: Paycheck)

    @objc(removePaychecksObject:)
    @NSManaged public func removeFromPaychecks(_ value: Paycheck)

    @objc(addPaychecks:)
    @NSManaged public func addToPaychecks(_ values: NSSet)

    @objc(removePaychecks:)
    @NSManaged public func removeFromPaychecks(_ values: NSSet)
}

extension Person: Identifiable {}
