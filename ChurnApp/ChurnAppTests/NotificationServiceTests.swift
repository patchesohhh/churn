//
//  NotificationServiceTests.swift
//  ChurnAppTests
//
//  `UNUserNotificationCenter` itself isn't meaningfully testable headlessly
//  (no real notification center in a simulator test run, and Apple's own
//  APIs are trusted plumbing) — see CLAUDE.md's testing guidance for the
//  "don't force tests on pure system-API plumbing" carve-out. What IS this
//  app's own logic, and so what's tested here:
//    - `NotificationService.bodyText(for:)`: pure string generation per
//      `ReminderType`, with no system dependency at all.
//    - The "already past due / completed reminders get no notification"
//      guard inside `schedule(for:)`, exercised indirectly by checking that
//      calling it clears `notificationIdentifier` for such reminders rather
//      than leaving a stale one in place.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class NotificationServiceTests: XCTestCase {

    private var controller: PersistenceController!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        controller = PersistenceController(inMemory: true)
        context = controller.viewContext
    }

    override func tearDown() {
        context = nil
        controller = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeAccount(bankName: String = "Chase") -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.bankName = bankName
        account.accountType = AccountType.checking.rawValue
        account.openingDate = Date()
        account.bonusAmount = NSDecimalNumber(string: "300.00")
        account.bonusStructure = BonusStructure.lumpSum.rawValue
        account.bonusRequirements = "Test requirement"
        account.accountStatus = AccountStatus.open.rawValue
        account.eligibilityMonths = 12
        account.isArchived = false
        account.createdAt = Date()
        account.updatedAt = Date()
        return account
    }

    private func makeReminder(
        type: ReminderType,
        dueDate: Date = Date().addingTimeInterval(86_400),
        isCompleted: Bool = false,
        account: Account
    ) -> Reminder {
        let reminder = Reminder(context: context)
        reminder.id = UUID()
        reminder.title = "Test reminder"
        reminder.reminderTypeValue = type
        reminder.dueDate = dueDate
        reminder.isCompleted = isCompleted
        reminder.isArchived = false
        reminder.createdAt = Date()
        reminder.account = account
        return reminder
    }

    // MARK: - bodyText(for:)

    func testBodyText_includesBankNameForEveryReminderType() {
        let account = makeAccount(bankName: "Ally")

        for type in ReminderType.allCases {
            let reminder = makeReminder(type: type, account: account)
            let body = NotificationService.bodyText(for: reminder)
            XCTAssertTrue(
                body.contains("Ally"),
                "Body text for \(type) should mention the account's bank name, got: \(body)"
            )
        }
    }

    func testBodyText_checkBonus_mentionsBonusPosting() {
        let account = makeAccount(bankName: "SoFi")
        let reminder = makeReminder(type: .checkBonus, account: account)

        XCTAssertTrue(NotificationService.bodyText(for: reminder).localizedCaseInsensitiveContains("bonus"))
    }

    func testBodyText_closeAccount_mentionsClosing() {
        let account = makeAccount(bankName: "Citi")
        let reminder = makeReminder(type: .closeAccount, account: account)

        XCTAssertTrue(NotificationService.bodyText(for: reminder).localizedCaseInsensitiveContains("close"))
    }

    func testBodyText_updateDirectDeposit_mentionsDirectDeposit() {
        let account = makeAccount(bankName: "U.S. Bank")
        let reminder = makeReminder(type: .updateDirectDeposit, account: account)

        XCTAssertTrue(NotificationService.bodyText(for: reminder).localizedCaseInsensitiveContains("direct deposit"))
    }

    func testBodyText_meetRequirement_mentionsRequirements() {
        let account = makeAccount(bankName: "Wells Fargo")
        let reminder = makeReminder(type: .meetRequirement, account: account)

        XCTAssertTrue(NotificationService.bodyText(for: reminder).localizedCaseInsensitiveContains("requirement"))
    }

    func testBodyText_differsAcrossTypes() {
        // Guards against a lazy switch that returns the same string for
        // every case — each reminder type should read distinctly.
        let account = makeAccount()
        let bodies = Set(ReminderType.allCases.map { type in
            NotificationService.bodyText(for: makeReminder(type: type, account: account))
        })
        XCTAssertEqual(bodies.count, ReminderType.allCases.count)
    }

    // MARK: - schedule(for:) guard logic

    func testSchedule_pastDueReminder_clearsNotificationIdentifier() async {
        let account = makeAccount()
        let reminder = makeReminder(
            type: .checkBonus,
            dueDate: Date().addingTimeInterval(-86_400),
            account: account
        )
        reminder.notificationIdentifier = "stale-identifier"

        await NotificationService.shared.schedule(for: reminder)

        XCTAssertNil(reminder.notificationIdentifier, "A past-due reminder shouldn't keep a scheduled notification.")
    }

    func testSchedule_completedReminder_clearsNotificationIdentifier() async {
        let account = makeAccount()
        let reminder = makeReminder(
            type: .checkBonus,
            dueDate: Date().addingTimeInterval(86_400),
            isCompleted: true,
            account: account
        )
        reminder.notificationIdentifier = "stale-identifier"

        await NotificationService.shared.schedule(for: reminder)

        XCTAssertNil(reminder.notificationIdentifier, "A completed reminder shouldn't keep a scheduled notification.")
    }

    // MARK: - cancel(for:)

    func testCancel_clearsNotificationIdentifier() {
        let account = makeAccount()
        let reminder = makeReminder(type: .custom, account: account)
        reminder.notificationIdentifier = "some-identifier"

        NotificationService.shared.cancel(for: reminder)

        XCTAssertNil(reminder.notificationIdentifier)
    }
}
