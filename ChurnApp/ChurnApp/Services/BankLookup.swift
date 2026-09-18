//
//  BankLookup.swift
//  ChurnApp
//
//  The find-or-create rule for `Bank` rows (round 2): given a name typed or
//  picked in a form, either return the existing `Bank` whose name matches
//  case-insensitively, or create a new one. Pulled out of `BankPicker` into
//  a standalone, Core-Data-only function so it's trivially unit-testable
//  without standing up a whole view — see CLAUDE.md's testing rule.
//
//  Deliberately fetches-then-filters in memory rather than an
//  `NSPredicate` with `[c]` — the list of banks a household would ever churn
//  through is tiny (dozens at most), so a predicate's marginal efficiency
//  isn't worth the locale/collation edge cases a case-insensitive predicate
//  can introduce.
//

import CoreData
import Foundation

enum BankLookup {

    /// Finds an existing `Bank` in `context` whose `name` matches `name`
    /// case-insensitively, or creates and inserts a new one if none exists.
    /// Does not save the context — callers own the save, same as every other
    /// entity mutation in this app (see `AddEditAccountView.save()`).
    static func findOrCreate(name: String, in context: NSManagedObjectContext) -> Bank {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let request = Bank.fetchRequest()
        let existingBanks = (try? context.fetch(request)) ?? []
        if let match = existingBanks.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }

        let bank = Bank(context: context)
        bank.id = UUID()
        bank.name = trimmed
        bank.createdAt = Date()
        return bank
    }
}
