//
//  AutomaticNotificationServiceTests.swift
//  ChurnAppTests
//
//  `UNUserNotificationCenter` itself isn't meaningfully testable headlessly
//  (see `NotificationServiceTests`'s header for the same carve-out) — so
//  what's covered here is `AutomaticNotificationService`'s own logic: the
//  pure, `static` "does this account/person qualify" functions that decide
//  *whether* to schedule, kept separate from the scheduling side effects.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class AutomaticNotificationServiceTests: XCTestCase {

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

    private func makeAccount(
        status: AccountStatus = .open,
        actualBonusDate: Date? = nil,
        isArchived: Bool = false
    ) -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.bankName = "Chase"
        account.accountType = AccountType.checking.rawValue
        account.openingDate = Date()
        account.bonusAmount = NSDecimalNumber(string: "300.00")
        account.bonusStructure = BonusStructure.lumpSum.rawValue
        account.bonusRequirements = "Test requirement"
        account.accountStatus = status.rawValue
        account.actualBonusDate = actualBonusDate
        account.eligibilityMonths = 12
        account.isArchived = isArchived
        account.createdAt = Date()
        account.updatedAt = Date()
        return account
    }

    private func makeDeposit(account: Account, status: DirectDepositStatus, scheduledDate: Date = Date()) -> DirectDeposit {
        let deposit = DirectDeposit(context: context)
        deposit.id = UUID()
        deposit.scheduledDate = scheduledDate
        deposit.amount = NSDecimalNumber(string: "500.00")
        deposit.status = status.rawValue
        deposit.sequenceNumberInSeries = 1
        deposit.isFirstToBank = false
        deposit.createdAt = Date()
        deposit.updatedAt = Date()
        deposit.account = account
        return deposit
    }

    private func makePerson(
        payFrequency: PayFrequency = .biweekly,
        nextPaycheckDate: Date?,
        isArchived: Bool = false
    ) -> Person {
        let person = Person(context: context)
        person.id = UUID()
        person.name = "Alex"
        person.payFrequency = payFrequency.rawValue
        person.paycheckAmount = NSDecimalNumber(string: "2400.00")
        person.nextPaycheckDate = nextPaycheckDate
        person.maxConcurrentDirectDeposits = 3
        person.isArchived = isArchived
        person.createdAt = Date()
        person.updatedAt = Date()
        return person
    }

    private func daysFromNow(_ days: Int, from base: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
    }

    // MARK: - Trigger 1: "Close this account"

    func testAccountQualifies_whenActualBonusDateSet_andStillOpen() {
        let account = makeAccount(status: .open, actualBonusDate: daysFromNow(-2))
        XCTAssertTrue(AutomaticNotificationService.accountQualifiesForCloseTrigger(account))
    }

    func testAccountDoesNotQualify_whenAlreadyClosed_evenWithActualBonusDate() {
        let account = makeAccount(status: .closed, actualBonusDate: daysFromNow(-2))
        XCTAssertFalse(AutomaticNotificationService.accountQualifiesForCloseTrigger(account))
    }

    func testAccountQualifies_whenDirectDepositSeriesComplete_noActualBonusDateYet() {
        let account = makeAccount(status: .open, actualBonusDate: nil)
        _ = makeDeposit(account: account, status: .posted)
        _ = makeDeposit(account: account, status: .posted)
        XCTAssertTrue(AutomaticNotificationService.accountQualifiesForCloseTrigger(account))
    }

    func testAccountDoesNotQualify_whenDirectDepositSeriesIncomplete() {
        let account = makeAccount(status: .open, actualBonusDate: nil)
        _ = makeDeposit(account: account, status: .posted)
        _ = makeDeposit(account: account, status: .scheduled)
        XCTAssertFalse(AutomaticNotificationService.accountQualifiesForCloseTrigger(account))
    }

    func testAccountDoesNotQualify_whenNoDepositSeriesTracked_andNoActualBonusDate() {
        // total == 0 must not trivially satisfy completed >= total.
        let account = makeAccount(status: .open, actualBonusDate: nil)
        XCTAssertFalse(AutomaticNotificationService.accountQualifiesForCloseTrigger(account))
    }

    func testAccountDoesNotQualify_whenArchived() {
        let account = makeAccount(status: .open, actualBonusDate: daysFromNow(-2), isArchived: true)
        XCTAssertFalse(AutomaticNotificationService.accountQualifiesForCloseTrigger(account))
    }

    func testAccountsQualifyingForCloseTrigger_filtersToOnlyQualifying() {
        let closeMe = makeAccount(status: .open, actualBonusDate: daysFromNow(-1))
        let leaveAlone = makeAccount(status: .open, actualBonusDate: nil)
        let result = AutomaticNotificationService.accountsQualifyingForCloseTrigger(accounts: [closeMe, leaveAlone])
        XCTAssertEqual(result.map(\.id), [closeMe.id])
    }

    // MARK: - nextPayDate(for:asOf:)

    func testNextPayDate_futureDate_returnsAsIs() {
        let payDate = daysFromNow(10)
        let person = makePerson(payFrequency: .biweekly, nextPaycheckDate: payDate)
        let result = AutomaticNotificationService.nextPayDate(for: person)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: result ?? .distantPast),
            Calendar.current.startOfDay(for: payDate)
        )
    }

    func testNextPayDate_staleDate_advancesForwardToNotBeInThePast() {
        // A biweekly person whose stored nextPaycheckDate drifted 40 days
        // into the past (e.g. never updated after several pay cycles).
        let staleDate = daysFromNow(-40)
        let person = makePerson(payFrequency: .biweekly, nextPaycheckDate: staleDate)
        let now = Date()
        let result = AutomaticNotificationService.nextPayDate(for: person, asOf: now)
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(
            Calendar.current.startOfDay(for: result!),
            Calendar.current.startOfDay(for: now)
        )
    }

    func testNextPayDate_nilWhenNoNextPaycheckDateSet() {
        let person = makePerson(nextPaycheckDate: nil)
        XCTAssertNil(AutomaticNotificationService.nextPayDate(for: person))
    }

    func testNextPayDate_nilForIrregularFrequency() {
        let person = makePerson(payFrequency: .irregular, nextPaycheckDate: daysFromNow(5))
        XCTAssertNil(AutomaticNotificationService.nextPayDate(for: person))
    }

    func testNextPayDate_nilForArchivedPerson() {
        let person = makePerson(nextPaycheckDate: daysFromNow(5), isArchived: true)
        XCTAssertNil(AutomaticNotificationService.nextPayDate(for: person))
    }

    // MARK: - Trigger 2: "Update your direct deposit"

    func testPersonQualifies_whenPaycheckIsWithinWindow_andNoMatchingDeposit() {
        let person = makePerson(nextPaycheckDate: daysFromNow(3))
        XCTAssertTrue(AutomaticNotificationService.personQualifiesForUpdateDDTrigger(person))
    }

    func testPersonDoesNotQualify_whenPaycheckIsOutsideWindow() {
        // Default window is 5 days; 10 days out shouldn't trigger yet.
        let person = makePerson(nextPaycheckDate: daysFromNow(10))
        XCTAssertFalse(AutomaticNotificationService.personQualifiesForUpdateDDTrigger(person))
    }

    func testPersonDoesNotQualify_whenMatchingDirectDepositAlreadyExists() {
        let payDate = daysFromNow(3)
        let person = makePerson(nextPaycheckDate: payDate)
        let account = makeAccount()
        // A DD row already scheduled right around the upcoming pay date —
        // the user has already handled this period.
        person.addToDirectDeposits(makeDeposit(account: account, status: .scheduled, scheduledDate: payDate))
        XCTAssertFalse(AutomaticNotificationService.personQualifiesForUpdateDDTrigger(person))
    }

    func testPersonDoesNotQualify_whenDepositIsWithinToleranceButNotExactMatch() {
        let payDate = daysFromNow(3)
        let person = makePerson(nextPaycheckDate: payDate)
        let account = makeAccount()
        let nearbyDate = daysFromNow(3 - 2) // 2 days off, within ddMatchToleranceDays (4)
        person.addToDirectDeposits(makeDeposit(account: account, status: .posted, scheduledDate: nearbyDate))
        XCTAssertFalse(AutomaticNotificationService.personQualifiesForUpdateDDTrigger(person))
    }

    func testPersonQualifies_whenOnlyDepositIsForADifferentPayPeriod() {
        let payDate = daysFromNow(3)
        let person = makePerson(nextPaycheckDate: payDate)
        let account = makeAccount()
        // A deposit tied to a much earlier pay period shouldn't count as
        // "handled" for the upcoming one.
        person.addToDirectDeposits(makeDeposit(account: account, status: .posted, scheduledDate: daysFromNow(-20)))
        XCTAssertTrue(AutomaticNotificationService.personQualifiesForUpdateDDTrigger(person))
    }

    func testPersonsQualifyingForUpdateDDTrigger_filtersToOnlyQualifying() {
        let nag = makePerson(nextPaycheckDate: daysFromNow(1))
        let dontNag = makePerson(nextPaycheckDate: daysFromNow(30))
        let result = AutomaticNotificationService.personsQualifyingForUpdateDDTrigger(persons: [nag, dontNag])
        XCTAssertEqual(result.map(\.id), [nag.id])
    }

    // MARK: - Identifiers

    func testIdentifiers_areStableAndDerivableFromID() {
        let account = makeAccount()
        XCTAssertEqual(
            AutomaticNotificationService.closeAccountIdentifier(for: account),
            "close-account-\(account.id)"
        )
        XCTAssertEqual(
            AutomaticNotificationService.closeAccountIdentifier(for: account),
            AutomaticNotificationService.closeAccountIdentifier(for: account)
        )

        let person = makePerson(nextPaycheckDate: nil)
        XCTAssertEqual(
            AutomaticNotificationService.updateDDIdentifier(for: person),
            "update-dd-\(person.id)"
        )
    }

    // MARK: - refreshNotifications end-to-end (logic only, no assertions on
    // the real notification center — just confirms it runs without throwing
    // against a realistic mixed dataset).

    func testRefreshNotifications_runsWithoutErrorAgainstSampleData() async {
        SampleData.populate(in: context)
        await AutomaticNotificationService.refreshNotifications(context: context)
        // No assertion beyond "didn't crash/throw" — actual scheduling
        // behavior is system plumbing, per the carve-out documented above.
    }
}
