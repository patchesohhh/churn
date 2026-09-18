//
//  CalculationService.swift
//  ChurnApp
//
//  Pure, stateless calculation helpers shared across Home/Calendar/Account
//  views and `ChurningStore`. Deliberately Foundation-only: no Core Data
//  import beyond taking already-fetched `Account`/`Person`/`DirectDeposit`
//  arrays as input. Callers (views, `ChurningStore`) own the `@FetchRequest`
//  / `NSManagedObjectContext` and hand this layer plain arrays — that keeps
//  these functions trivially testable without a persistent store and keeps
//  the low-coupling rule from CLAUDE.md intact.
//
//  All money arithmetic uses `Decimal`, never `Double`, per CLAUDE.md.
//
//  `import CoreData` is here only so `isEligible` can compare two `Bank` rows
//  by `objectID` (round 2). This layer still never fetches, saves, or touches a
//  context — callers hand it already-fetched objects, as before. The import is
//  required because this project enables Swift's member-import-visibility
//  upcoming feature, so `NSManagedObject` members aren't re-exported implicitly.
//

import CoreData
import Foundation

enum CalculationService {

    // MARK: - Earnings

    /// Sum of `bonusAmountDecimal` for accounts whose bonus actually posted
    /// (`actualBonusDate` non-nil) within the given calendar year.
    ///
    /// Uses `actualBonusDate`, not `expectedBonusDate` — YTD earnings is
    /// "money that has landed", not a projection. An account can have an
    /// `expectedBonusDate` in the current year but no `actualBonusDate` yet;
    /// that's pending money, not earned money (see `pendingBonusesTotal`).
    static func ytdEarnings(
        accounts: [Account],
        year: Int = Calendar.current.component(.year, from: Date())
    ) -> Decimal {
        let calendar = Calendar.current
        return accounts.reduce(Decimal(0)) { total, account in
            guard let postedDate = account.actualBonusDate,
                  calendar.component(.year, from: postedDate) == year else {
                return total
            }
            return total + account.bonusAmountDecimal
        }
    }

    /// Sum of `bonusAmountDecimal` for every account with a non-nil
    /// `actualBonusDate`, regardless of year. The lifetime "money earned
    /// from churning" figure.
    static func allTimeEarnings(accounts: [Account]) -> Decimal {
        accounts.reduce(Decimal(0)) { total, account in
            guard account.actualBonusDate != nil else { return total }
            return total + account.bonusAmountDecimal
        }
    }

    /// Sum of `bonusAmountDecimal` for accounts still working toward a bonus
    /// that hasn't posted yet.
    ///
    /// Restricted to `.open` and `.prospecting` — deliberately excludes
    /// `.maintaining`, because a `.maintaining` account's bonus has *already*
    /// posted (that's what moved it out of `.open`); counting it here would
    /// double-count money that `ytdEarnings`/`allTimeEarnings` already include.
    /// `.closed` is excluded for the same reason (its bonus either posted
    /// already or the account was abandoned before qualifying). The
    /// `actualBonusDate == nil` guard is a belt-and-suspenders check against
    /// bad data — an `.open` account should never actually have a posted date,
    /// but this keeps the total correct even if status and date fall out of
    /// sync.
    static func pendingBonusesTotal(accounts: [Account]) -> Decimal {
        accounts.reduce(Decimal(0)) { total, account in
            let status = account.accountStatusValue
            guard status == .open || status == .prospecting,
                  account.actualBonusDate == nil else {
                return total
            }
            return total + account.bonusAmountDecimal
        }
    }

    /// Simple flat-rate tax estimate: `earnings * rate`. Per the source docs,
    /// this build intentionally does not model marginal brackets, state tax,
    /// or 1099-INT thresholds — just "assume a quarter of it is gone at tax
    /// time" so the user isn't surprised.
    static func estimatedTaxLiability(earnings: Decimal, rate: Decimal = 0.25) -> Decimal {
        earnings * rate
    }

    // MARK: - Account counts

    /// Number of accounts whose `openingDate` falls within the given year.
    static func accountsOpenedThisYear(
        accounts: [Account],
        year: Int = Calendar.current.component(.year, from: Date())
    ) -> Int {
        let calendar = Calendar.current
        return accounts.filter { calendar.component(.year, from: $0.openingDate) == year }.count
    }

    /// Number of accounts whose `closedDate` falls within the given year.
    /// Accounts with no `closedDate` (never closed) are excluded.
    static func accountsClosedThisYear(
        accounts: [Account],
        year: Int = Calendar.current.component(.year, from: Date())
    ) -> Int {
        let calendar = Calendar.current
        return accounts.filter { account in
            guard let closedDate = account.closedDate else { return false }
            return calendar.component(.year, from: closedDate) == year
        }.count
    }

    // MARK: - Eligibility

    /// Whether `person` is currently eligible for a new bonus at `bankName`.
    ///
    /// A bank blocks a new signup bonus for `eligibilityMonths` after the
    /// account tied to a *previous* bonus at that bank was closed. So the
    /// person is ineligible only if they have a closed account at that bank
    /// (matched case-insensitively — bank names are free-text user entry and
    /// "Chase" / "chase" shouldn't be treated as different banks) whose
    /// `closedDate + eligibilityMonths` is still in the future relative to
    /// `date`. If there's no matching closed account (never had one, or it's
    /// still open/prospecting/maintaining), there's nothing to be ineligible
    /// from, so the person is eligible by default.
    ///
    /// At the exact boundary (`date == closedDate + eligibilityMonths`), the
    /// window has elapsed and the person is eligible again — `date` must be
    /// strictly *before* the reeligibility date to still be blocked.
    ///
    /// **Bank matching (round 2).** `bank` is an optional, additive refinement:
    /// when the caller passes a `Bank` row *and* the closed account also has
    /// one, the two are compared by object identity — that's an exact,
    /// user-confirmed link and beats any string comparison. Whenever either
    /// side lacks a `Bank` (legacy rows, or a target the user typed by hand),
    /// the original case-insensitive `bankName` match is used instead. The
    /// fallback is never dropped, so nothing needs migrating: existing callers
    /// that pass only `bankName` behave exactly as they did before.
    ///
    /// - Parameters:
    ///   - bankName: free-text bank name, always required — it's the fallback
    ///     match and the label the UI already has.
    ///   - bank: the `Bank` row for the account/offer being evaluated, when the
    ///     user has picked one. Defaults to nil for backward compatibility.
    static func isEligible(
        person: Person,
        bankName: String,
        bank: Bank? = nil,
        asOf date: Date = Date()
    ) -> Bool {
        let calendar = Calendar.current
        let targetBank = bankName.lowercased()

        /// True when this closed account is at the same bank as the target.
        /// Prefers the relationship, falls back to the name.
        func matchesTargetBank(_ account: Account) -> Bool {
            if let bank, let accountBank = account.bank {
                return accountBank.objectID == bank.objectID
            }
            return account.bankName.lowercased() == targetBank
        }

        let blockingAccounts = person.accountsArray.filter { account in
            guard matchesTargetBank(account),
                  let closedDate = account.closedDate else {
                return false
            }
            guard let reeligibleDate = calendar.date(
                byAdding: .month,
                value: Int(account.eligibilityMonths),
                to: closedDate
            ) else {
                return false
            }
            return date < reeligibleDate
        }

        return blockingAccounts.isEmpty
    }

    // MARK: - Direct deposits

    /// How many of an account's direct deposits have posted, out of how many
    /// total are expected in the series.
    ///
    /// `total` is taken as `directDepositsArray.count` (the number of
    /// `DirectDeposit` rows actually scheduled against this account) rather
    /// than the max `sequenceNumberInSeries` seen. Reasoning: the user creates
    /// exactly one `DirectDeposit` row per expected paycheck when they set up
    /// an account's DD plan, so the row count already *is* the plan size —
    /// deriving "total" from the max sequence number would silently undercount
    /// if a deposit is ever deleted/re-sequenced, or overcount if sequence
    /// numbers aren't contiguous. Row count is the simpler, harder-to-desync
    /// source of truth here.
    static func directDepositProgress(for account: Account) -> (completed: Int, total: Int) {
        let deposits = account.directDepositsArray
        let completed = deposits.filter { $0.statusValue == .posted }.count
        return (completed: completed, total: deposits.count)
    }

    // MARK: - Dates

    /// Whole days between `now` and `date` (positive if `date` is in the
    /// future, negative if it's in the past). Used across Home/Calendar for
    /// "N days until bonus posts" / "N days until safe to close" displays.
    static func daysUntil(_ date: Date, from now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: startOfNow, to: startOfDate).day ?? 0
    }
}
