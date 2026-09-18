//
//  ChurnAppTests.swift
//  ChurnAppTests
//
//  Smoke tests: proves the test target is wired to the app target and that the
//  preview stack loads with its sample data.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class ChurnAppTests: XCTestCase {

    /// Trivial canary — if this fails, the test target itself is broken.
    func testTestTargetRuns() {
        XCTAssertTrue(true)
    }

    /// `PersistenceController.preview` must load an in-memory store and seed it.
    /// Every `#Preview` in the app depends on this, so a failure here breaks
    /// Xcode previews project-wide.
    func testPreviewControllerIsSeeded() throws {
        let context = PersistenceController.preview.viewContext

        let people = try context.fetch(NSFetchRequest<Person>(entityName: "Person"))
        let accounts = try context.fetch(NSFetchRequest<Account>(entityName: "Account"))
        let deposits = try context.fetch(NSFetchRequest<DirectDeposit>(entityName: "DirectDeposit"))
        let reminders = try context.fetch(NSFetchRequest<Reminder>(entityName: "Reminder"))
        let offers = try context.fetch(NSFetchRequest<Offer>(entityName: "Offer"))

        XCTAssertEqual(people.count, 2, "Sample data models a two-earner household.")
        // Five as of round 3: one account per status, plus the non-churn joint
        // savings home account.
        XCTAssertEqual(accounts.count, 5)
        XCTAssertEqual(deposits.count, 4)
        XCTAssertEqual(reminders.count, 3)
        XCTAssertEqual(offers.count, 2)

        // The preview store must never be the on-disk store.
        let storeURL = PersistenceController.preview.container
            .persistentStoreCoordinator.persistentStores.first?.url
        XCTAssertEqual(storeURL?.path, "/dev/null")
    }

    /// Sample accounts should cover every status so previews can show each
    /// visual state without extra setup.
    func testPreviewCoversEveryAccountStatus() throws {
        let context = PersistenceController.preview.viewContext
        let accounts = try context.fetch(NSFetchRequest<Account>(entityName: "Account"))
        let statuses = Set(accounts.map(\.accountStatus))

        for status in AccountStatus.allCases {
            XCTAssertTrue(statuses.contains(status.rawValue), "Missing sample account with status \(status.rawValue)")
        }
    }

    // MARK: - Enums

    func testEnumRawValuesRoundTrip() {
        XCTAssertEqual(PayFrequency(rawValue: "biweekly"), .biweekly)
        XCTAssertEqual(AccountType(rawValue: "savings"), .savings)
        XCTAssertEqual(BonusStructure(rawValue: "lumpSum"), .lumpSum)
        XCTAssertEqual(AccountStatus(rawValue: "maintaining"), .maintaining)
        XCTAssertEqual(DirectDepositStatus(rawValue: "posted"), .posted)
        XCTAssertEqual(ReminderType(rawValue: "updateDirectDeposit"), .updateDirectDeposit)

        // Every case needs a non-empty display name — these go straight into
        // Pickers, so a blank one is an invisible UI bug.
        for case_ in PayFrequency.allCases { XCTAssertFalse(case_.displayName.isEmpty) }
        for case_ in AccountType.allCases { XCTAssertFalse(case_.displayName.isEmpty) }
        for case_ in BonusStructure.allCases { XCTAssertFalse(case_.displayName.isEmpty) }
        for case_ in AccountStatus.allCases { XCTAssertFalse(case_.displayName.isEmpty) }
        for case_ in DirectDepositStatus.allCases { XCTAssertFalse(case_.displayName.isEmpty) }
        for case_ in ReminderType.allCases { XCTAssertFalse(case_.displayName.isEmpty) }
    }
}
