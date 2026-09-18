//
//  CalculationServiceTests.swift
//  ChurnAppTests
//
//  Exercises every `CalculationService` function against small, purpose-built
//  fixtures in an in-memory Core Data stack. Deliberately doesn't reuse
//  `PersistenceController.preview`'s fixed sample data for most cases here —
//  the edge cases below (exact-boundary eligibility, empty account lists,
//  mixed years) need precise control over dates that the shared seed data
//  doesn't give us. `testYtdEarnings_matchesPreviewSeedData` is the one case
//  that does exercise the shared preview stack, per CLAUDE.md's testing rule.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class CalculationServiceTests: XCTestCase {

    private var controller: PersistenceController!
    private var context: NSManagedObjectContext!
    private let calendar = Calendar.current

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

    // MARK: - Fixture helpers

    private func makePerson(name: String = "Test Person") -> Person {
        let person = Person(context: context)
        person.id = UUID()
        person.name = name
        person.payFrequency = PayFrequency.biweekly.rawValue
        person.paycheckAmount = NSDecimalNumber(string: "1000.00")
        person.maxConcurrentDirectDeposits = 2
        person.createdAt = Date()
        person.updatedAt = Date()
        return person
    }

    @discardableResult
    private func makeAccount(
        bankName: String = "Test Bank",
        bonus: String = "100.00",
        status: AccountStatus = .open,
        actualBonusDate: Date? = nil,
        openingDate: Date = Date(),
        closedDate: Date? = nil,
        eligibilityMonths: Int16 = 12,
        person: Person? = nil
    ) -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.bankName = bankName
        account.accountType = AccountType.checking.rawValue
        account.openingDate = openingDate
        account.bonusAmount = NSDecimalNumber(string: bonus)
        account.bonusStructure = BonusStructure.lumpSum.rawValue
        account.bonusRequirements = "Test requirements"
        account.accountStatus = status.rawValue
        account.actualBonusDate = actualBonusDate
        account.closedDate = closedDate
        account.eligibilityMonths = eligibilityMonths
        account.isArchived = false
        account.createdAt = Date()
        account.updatedAt = Date()
        account.person = person
        return account
    }

    @discardableResult
    private func makeDeposit(
        account: Account,
        status: DirectDepositStatus,
        sequence: Int16 = 1
    ) -> DirectDeposit {
        let deposit = DirectDeposit(context: context)
        deposit.id = UUID()
        deposit.scheduledDate = Date()
        deposit.amount = NSDecimalNumber(string: "500.00")
        deposit.status = status.rawValue
        deposit.sequenceNumberInSeries = sequence
        deposit.isFirstToBank = sequence == 1
        deposit.createdAt = Date()
        deposit.updatedAt = Date()
        deposit.account = account
        return deposit
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date()
    }

    // MARK: - ytdEarnings

    func testYtdEarnings_noAccounts_isZero() {
        XCTAssertEqual(CalculationService.ytdEarnings(accounts: [], year: 2026), 0)
    }

    func testYtdEarnings_sumsOnlyMatchingYear() {
        let a = makeAccount(bonus: "300", status: .maintaining, actualBonusDate: date(year: 2026, month: 3, day: 1))
        let b = makeAccount(bonus: "200", status: .maintaining, actualBonusDate: date(year: 2025, month: 12, day: 1))
        let c = makeAccount(bonus: "150", status: .maintaining, actualBonusDate: date(year: 2026, month: 8, day: 15))
        let pendingNoDate = makeAccount(bonus: "999", status: .open, actualBonusDate: nil)

        let total = CalculationService.ytdEarnings(accounts: [a, b, c, pendingNoDate], year: 2026)
        XCTAssertEqual(total, 450)
    }

    func testYtdEarnings_excludesAccountsWithoutActualBonusDate() {
        let pending = makeAccount(bonus: "500", status: .open, actualBonusDate: nil)
        XCTAssertEqual(CalculationService.ytdEarnings(accounts: [pending], year: 2026), 0)
    }

    // MARK: - allTimeEarnings

    func testAllTimeEarnings_noAccounts_isZero() {
        XCTAssertEqual(CalculationService.allTimeEarnings(accounts: []), 0)
    }

    func testAllTimeEarnings_sumsAcrossAllYears() {
        let a = makeAccount(bonus: "300", status: .maintaining, actualBonusDate: date(year: 2024, month: 1, day: 1))
        let b = makeAccount(bonus: "200", status: .closed, actualBonusDate: date(year: 2026, month: 6, day: 1))
        let pending = makeAccount(bonus: "999", status: .open, actualBonusDate: nil)

        XCTAssertEqual(CalculationService.allTimeEarnings(accounts: [a, b, pending]), 500)
    }

    // MARK: - pendingBonusesTotal

    func testPendingBonusesTotal_allAccountsPending() {
        let a = makeAccount(bonus: "300", status: .open)
        let b = makeAccount(bonus: "450", status: .prospecting)
        XCTAssertEqual(CalculationService.pendingBonusesTotal(accounts: [a, b]), 750)
    }

    func testPendingBonusesTotal_excludesMaintainingAndClosed() {
        let openAccount = makeAccount(bonus: "300", status: .open)
        let maintaining = makeAccount(bonus: "500", status: .maintaining, actualBonusDate: Date())
        let closed = makeAccount(bonus: "200", status: .closed, actualBonusDate: Date())

        let total = CalculationService.pendingBonusesTotal(accounts: [openAccount, maintaining, closed])
        XCTAssertEqual(total, 300)
    }

    func testPendingBonusesTotal_noAccounts_isZero() {
        XCTAssertEqual(CalculationService.pendingBonusesTotal(accounts: []), 0)
    }

    // MARK: - estimatedTaxLiability

    func testEstimatedTaxLiability_defaultRate() {
        XCTAssertEqual(CalculationService.estimatedTaxLiability(earnings: 1000), 250)
    }

    func testEstimatedTaxLiability_customRate() {
        XCTAssertEqual(CalculationService.estimatedTaxLiability(earnings: 1000, rate: 0.1), 100)
    }

    func testEstimatedTaxLiability_zeroEarnings() {
        XCTAssertEqual(CalculationService.estimatedTaxLiability(earnings: 0), 0)
    }

    // MARK: - accountsOpenedThisYear / accountsClosedThisYear

    func testAccountsOpenedThisYear_countsOnlyMatchingYear() {
        let a = makeAccount(openingDate: date(year: 2026, month: 1, day: 5))
        let b = makeAccount(openingDate: date(year: 2026, month: 9, day: 1))
        let c = makeAccount(openingDate: date(year: 2025, month: 11, day: 20))

        XCTAssertEqual(CalculationService.accountsOpenedThisYear(accounts: [a, b, c], year: 2026), 2)
    }

    func testAccountsClosedThisYear_excludesNeverClosed() {
        let a = makeAccount(closedDate: date(year: 2026, month: 4, day: 1))
        let neverClosed = makeAccount(closedDate: nil)
        let closedLastYear = makeAccount(closedDate: date(year: 2025, month: 4, day: 1))

        XCTAssertEqual(CalculationService.accountsClosedThisYear(accounts: [a, neverClosed, closedLastYear], year: 2026), 1)
    }

    func testAccountsClosedThisYear_noAccounts_isZero() {
        XCTAssertEqual(CalculationService.accountsClosedThisYear(accounts: [], year: 2026), 0)
    }

    // MARK: - isEligible

    func testIsEligible_noAccountsAtBank_isTrue() {
        let person = makePerson()
        makeAccount(bankName: "Chase", status: .open, person: person)

        XCTAssertTrue(CalculationService.isEligible(person: person, bankName: "SoFi"))
    }

    func testIsEligible_openAccountAtBank_isTrue() {
        // An open (not closed) account at the bank doesn't block a new bonus —
        // only a closed account starts the eligibility clock.
        let person = makePerson()
        makeAccount(bankName: "Chase", status: .open, closedDate: nil, person: person)

        XCTAssertTrue(CalculationService.isEligible(person: person, bankName: "Chase"))
    }

    func testIsEligible_withinWindow_isFalse() {
        let person = makePerson()
        let closed = date(year: 2026, month: 1, day: 1)
        makeAccount(bankName: "Chase", status: .closed, closedDate: closed, eligibilityMonths: 24, person: person)

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertFalse(CalculationService.isEligible(person: person, bankName: "Chase", asOf: asOf))
    }

    func testIsEligible_pastWindow_isTrue() {
        let person = makePerson()
        let closed = date(year: 2023, month: 1, day: 1)
        makeAccount(bankName: "Chase", status: .closed, closedDate: closed, eligibilityMonths: 12, person: person)

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertTrue(CalculationService.isEligible(person: person, bankName: "Chase", asOf: asOf))
    }

    func testIsEligible_exactlyAtBoundary_isTrue() {
        // eligibilityMonths window elapses exactly at closedDate + N months —
        // the person must be eligible again right at that instant, not still
        // blocked.
        let person = makePerson()
        let closed = date(year: 2025, month: 1, day: 15)
        makeAccount(bankName: "Chase", status: .closed, closedDate: closed, eligibilityMonths: 12, person: person)

        let reeligibleDate = calendar.date(byAdding: .month, value: 12, to: closed)!
        XCTAssertTrue(CalculationService.isEligible(person: person, bankName: "Chase", asOf: reeligibleDate))
    }

    func testIsEligible_oneDayBeforeBoundary_isFalse() {
        let person = makePerson()
        let closed = date(year: 2025, month: 1, day: 15)
        makeAccount(bankName: "Chase", status: .closed, closedDate: closed, eligibilityMonths: 12, person: person)

        let reeligibleDate = calendar.date(byAdding: .month, value: 12, to: closed)!
        let oneDayBefore = calendar.date(byAdding: .day, value: -1, to: reeligibleDate)!
        XCTAssertFalse(CalculationService.isEligible(person: person, bankName: "Chase", asOf: oneDayBefore))
    }

    func testIsEligible_bankNameIsCaseInsensitive() {
        let person = makePerson()
        let closed = date(year: 2026, month: 1, day: 1)
        makeAccount(bankName: "chase", status: .closed, closedDate: closed, eligibilityMonths: 24, person: person)

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertFalse(CalculationService.isEligible(person: person, bankName: "CHASE", asOf: asOf))
    }

    // MARK: - directDepositProgress

    func testDirectDepositProgress_noDeposits_isZeroOfZero() {
        let account = makeAccount()
        let progress = CalculationService.directDepositProgress(for: account)
        XCTAssertEqual(progress.completed, 0)
        XCTAssertEqual(progress.total, 0)
    }

    func testDirectDepositProgress_mixedStatuses() {
        let account = makeAccount()
        makeDeposit(account: account, status: .posted, sequence: 1)
        makeDeposit(account: account, status: .posted, sequence: 2)
        makeDeposit(account: account, status: .scheduled, sequence: 3)

        let progress = CalculationService.directDepositProgress(for: account)
        XCTAssertEqual(progress.completed, 2)
        XCTAssertEqual(progress.total, 3)
    }

    func testDirectDepositProgress_skippedNotCountedAsCompleted() {
        let account = makeAccount()
        makeDeposit(account: account, status: .posted, sequence: 1)
        makeDeposit(account: account, status: .skipped, sequence: 2)

        let progress = CalculationService.directDepositProgress(for: account)
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.total, 2)
    }

    // MARK: - daysUntil

    func testDaysUntil_futureDate_isPositive() {
        let now = date(year: 2026, month: 1, day: 1)
        let future = date(year: 2026, month: 1, day: 11)
        XCTAssertEqual(CalculationService.daysUntil(future, from: now), 10)
    }

    func testDaysUntil_pastDate_isNegative() {
        let now = date(year: 2026, month: 1, day: 11)
        let past = date(year: 2026, month: 1, day: 1)
        XCTAssertEqual(CalculationService.daysUntil(past, from: now), -10)
    }

    func testDaysUntil_sameDay_isZero() {
        let now = date(year: 2026, month: 1, day: 1)
        XCTAssertEqual(CalculationService.daysUntil(now, from: now), 0)
    }

    // MARK: - Preview stack integration

    /// Sanity check that `ytdEarnings` behaves correctly against the shared
    /// `PersistenceController.preview` fixture (not just hand-built ones),
    /// per CLAUDE.md's instruction to reuse it in tests.
    func testYtdEarnings_matchesPreviewSeedData() throws {
        let previewContext = PersistenceController.preview.viewContext
        let accounts = try previewContext.fetch(NSFetchRequest<Account>(entityName: "Account"))

        let currentYear = calendar.component(.year, from: Date())
        let expected = accounts
            .filter { account in
                guard let posted = account.actualBonusDate else { return false }
                return calendar.component(.year, from: posted) == currentYear
            }
            .reduce(Decimal(0)) { $0 + $1.bonusAmountDecimal }

        XCTAssertEqual(CalculationService.ytdEarnings(accounts: accounts, year: currentYear), expected)
    }
}
