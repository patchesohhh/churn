//
//  Offer.swift
//  ChurnApp
//
//  A bank promotion the user has entered by hand. There is no bundled JSON,
//  no API and no marketplace in this build (see CLAUDE.md) — `Offer` is pure
//  user CRUD, and the rich crowdsourced schema in
//  `potential database structure.txt` is Phase 2+.
//
//  See `Person.swift` for why these classes are hand-written.
//

import CoreData
import Foundation

@objc(Offer)
public class Offer: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Offer> {
        NSFetchRequest<Offer>(entityName: "Offer")
    }

    // MARK: - Attributes

    @NSManaged public var id: UUID
    @NSManaged public var bankName: String
    /// Optional as of round 3 — a user jotting down "Chase, $300" shouldn't be
    /// forced to invent a title. Display code should use `displayTitle`, which
    /// falls back to `bankName`, rather than reading this directly.
    @NSManaged public var offerTitle: String?
    /// The model enforces a minimum of 0 (no negative bonuses); see the note
    /// on `Account.bonusAmount` for why a strict "> 0" rule lives in the UI.
    /// Money is always `NSDecimalNumber` in the store. Use `bonusAmountDecimal`.
    @NSManaged public var bonusAmount: NSDecimalNumber
    @NSManaged public var requirements: String
    @NSManaged public var expirationDate: Date?
    /// Months the bank makes you wait after a previous bonus. `NSNumber?`
    /// rather than a scalar so "unknown" stays distinguishable from "0".
    @NSManaged public var eligibilityRestrictionMonths: NSNumber?
    @NSManaged public var minimumDeposit: NSDecimalNumber?
    @NSManaged public var directDepositRequired: Bool
    /// Months the account must stay open. `NSNumber?` for the same reason as
    /// `eligibilityRestrictionMonths` — 0 is a real answer ("close anytime").
    @NSManaged public var monthsToMaintain: NSNumber?
    @NSManaged public var offerURL: String?
    @NSManaged public var isActive: Bool
    @NSManaged public var isFavorite: Bool
    @NSManaged public var notes: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    // MARK: - Relationships

    /// Nullify: deleting an offer must leave any accounts opened from it alone.
    @NSManaged public var accounts: NSSet?
    /// The `Bank` row this offer is from, when one has been picked. Optional
    /// and additive — `bankName` above stays the display string. Nullify:
    /// deleting a bank unlinks its offers rather than deleting them.
    @NSManaged public var bank: Bank?
}

// MARK: - Convenience

extension Offer {

    /// `bonusAmount` as a Swift `Decimal`.
    var bonusAmountDecimal: Decimal {
        get { bonusAmount.decimalValue }
        set { bonusAmount = NSDecimalNumber(decimal: newValue) }
    }

    /// What to show wherever a title would go: the user's title if they gave
    /// one, otherwise the bank name. Centralised here so the list and detail
    /// views can't drift apart on the fallback rule. Whitespace-only titles
    /// count as absent.
    var displayTitle: String {
        let trimmed = offerTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? bankName : trimmed
    }

    var accountsArray: [Account] {
        (accounts as? Set<Account> ?? []).sorted { $0.openingDate > $1.openingDate }
    }

    /// True when an expiration date is set and has passed.
    var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }
}

// MARK: - Generated relationship accessors

extension Offer {

    @objc(addAccountsObject:)
    @NSManaged public func addToAccounts(_ value: Account)

    @objc(removeAccountsObject:)
    @NSManaged public func removeFromAccounts(_ value: Account)

    @objc(addAccounts:)
    @NSManaged public func addToAccounts(_ values: NSSet)

    @objc(removeAccounts:)
    @NSManaged public func removeFromAccounts(_ values: NSSet)
}

extension Offer: Identifiable {}
