//
//  Enums.swift
//  ChurnApp
//
//  Canonical, String-backed enums for every "typed string" attribute in the
//  Core Data model. Core Data itself stores the raw value (a String) because
//  Core Data has no native enum type; these enums are the only place the raw
//  strings are spelled out, so everything else in the app should convert via
//  `init(rawValue:)` rather than comparing string literals.
//
//  Every enum is `String, CaseIterable, Identifiable` so it can drop straight
//  into a SwiftUI `Picker(selection:)` / `ForEach` without an adapter.
//

import Foundation

// MARK: - PayFrequency

/// How often a `Person` is paid. Drives direct-deposit date projection.
enum PayFrequency: String, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case semimonthly
    case monthly
    case irregular

    var id: Self { self }

    var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 Weeks"
        case .semimonthly: "Twice a Month"
        case .monthly: "Monthly"
        case .irregular: "Irregular"
        }
    }

    /// Approximate number of paychecks per year. Used for rough projections
    /// only — `.irregular` deliberately reports 0 so callers must special-case
    /// it instead of silently producing a bogus forecast.
    var paychecksPerYear: Int {
        switch self {
        case .weekly: 52
        case .biweekly: 26
        case .semimonthly: 24
        case .monthly: 12
        case .irregular: 0
        }
    }
}

// MARK: - AccountType

/// Bank account flavor. Kept deliberately small — the churning use case only
/// ever distinguishes checking vs. savings.
enum AccountType: String, CaseIterable, Identifiable {
    case checking
    case savings

    var id: Self { self }

    var displayName: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        }
    }

    /// SF Symbol used by list rows / badges.
    var systemImageName: String {
        switch self {
        case .checking: "creditcard"
        case .savings: "banknote"
        }
    }
}

// MARK: - BonusStructure

/// How the bonus pays out. `tiered` was added beyond the source docs (which
/// only listed lump sum / recurring) because several real offers pay a
/// different amount per deposit tier.
enum BonusStructure: String, CaseIterable, Identifiable {
    case lumpSum
    case tiered
    case recurring

    var id: Self { self }

    var displayName: String {
        switch self {
        case .lumpSum: "Lump Sum"
        case .tiered: "Tiered"
        case .recurring: "Recurring"
        }
    }
}

// MARK: - AccountStatus

/// Lifecycle of a churned account.
///
/// `prospecting` (considering / applied but not funded) and `maintaining`
/// (bonus posted, now waiting out the fee-free window before closing) are
/// additions beyond the source docs' open/closed pair — the Home and Calendar
/// views need to separate "work to do" from "just waiting".
enum AccountStatus: String, CaseIterable, Identifiable {
    case prospecting
    case open
    case maintaining
    case closed

    var id: Self { self }

    var displayName: String {
        switch self {
        case .prospecting: "Prospecting"
        case .open: "Open"
        case .maintaining: "Maintaining"
        case .closed: "Closed"
        }
    }

    /// True while the account still needs attention (requirements or the
    /// maintenance window). Closed and prospecting accounts are inert.
    var isActive: Bool {
        self == .open || self == .maintaining
    }
}

// MARK: - DirectDepositStatus

/// State of a single scheduled paycheck allocation.
enum DirectDepositStatus: String, CaseIterable, Identifiable {
    case scheduled
    case posted
    case skipped

    var id: Self { self }

    var displayName: String {
        switch self {
        case .scheduled: "Scheduled"
        case .posted: "Posted"
        case .skipped: "Skipped"
        }
    }
}

// MARK: - ReminderType

/// Why a reminder exists. Determines the default title and the SF Symbol
/// shown in the reminder list.
enum ReminderType: String, CaseIterable, Identifiable {
    case checkBonus
    case closeAccount
    case updateDirectDeposit
    case meetRequirement
    case custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .checkBonus: "Check Bonus"
        case .closeAccount: "Close Account"
        case .updateDirectDeposit: "Update Direct Deposit"
        case .meetRequirement: "Meet Requirement"
        case .custom: "Custom"
        }
    }

    var systemImageName: String {
        switch self {
        case .checkBonus: "dollarsign.circle"
        case .closeAccount: "xmark.circle"
        case .updateDirectDeposit: "arrow.triangle.2.circlepath"
        case .meetRequirement: "checklist"
        case .custom: "bell"
        }
    }
}
