//
//  Round4PersonArchiveTests.swift
//  ChurnAppTests
//
//  Covers the round-4 soft delete of a `Person` (`Person.isArchived`).
//
//  The design decision under test (CLAUDE.md, round 4): "delete person" flips
//  `isArchived` instead of calling `context.delete(person)`, because a real
//  delete would cascade through `Person.paychecks`/`Person.accounts`/
//  `Person.directDeposits` and destroy the history the user still needs to
//  see. So the most important assertion here isn't "the flag flipped" — it's
//  "nothing else moved."
//
//  The last test demonstrates the `isArchived == NO` fetch predicate that the
//  person pickers (AddEditAccountView, AddEditPaycheckView), Home's
//  first-run/quick-action logic, and Calendar's projection loop will use to
//  hide archived people from *new* work. Wiring those call sites is separate
//  follow-up work; the predicate pattern is proven here.
//
//  Every test gets its own empty in-memory stack — never the app's real store.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class Round4PersonArchiveTests: XCTestCase {

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

    // MARK: - Fixture helpers

    /// Deliberately does NOT touch `isArchived` — these rows behave exactly
    /// like ones created before round 4, relying on the model's default value.
    private func makePerson(name: String = "Alex") -> Person {
        let person = Person(context: context)
        person.id = UUID()
        person.name = name
        person.payFrequency = PayFrequency.biweekly.rawValue
        person.paycheckAmount = NSDecimalNumber(string: "2400.00")
        person.maxConcurrentDirectDeposits = 3
        person.createdAt = Date()
        person.updatedAt = Date()
        return person
    }

    @discardableResult
    private func makeAccount(bankName: String = "Chase", person: Person) -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.bankName = bankName
        account.accountType = AccountType.checking.rawValue
        account.openingDate = Date()
        account.bonusAmount = NSDecimalNumber(string: "300.00")
        account.bonusStructure = BonusStructure.lumpSum.rawValue
        account.bonusRequirements = "One DD of $500+."
        account.accountStatus = AccountStatus.open.rawValue
        account.eligibilityMonths = 12
        account.isArchived = false
        account.createdAt = Date()
        account.updatedAt = Date()
        account.person = person
        return account
    }

    @discardableResult
    private func makePaycheck(person: Person, total: String = "2400.00") -> Paycheck {
        let paycheck = Paycheck(context: context)
        paycheck.id = UUID()
        paycheck.payDate = Date()
        paycheck.totalAmount = NSDecimalNumber(string: total)
        paycheck.createdAt = Date()
        paycheck.updatedAt = Date()
        paycheck.person = person
        return paycheck
    }

    @discardableResult
    private func makeDirectDeposit(
        person: Person,
        account: Account,
        paycheck: Paycheck?,
        amount: String = "500.00"
    ) -> DirectDeposit {
        let deposit = DirectDeposit(context: context)
        deposit.id = UUID()
        deposit.amount = NSDecimalNumber(string: amount)
        deposit.scheduledDate = Date()
        deposit.status = DirectDepositStatus.scheduled.rawValue
        deposit.sequenceNumberInSeries = 1
        deposit.isFirstToBank = true
        deposit.createdAt = Date()
        deposit.updatedAt = Date()
        deposit.person = person
        deposit.account = account
        deposit.paycheck = paycheck
        return deposit
    }

    // MARK: - Flag round-trip

    func testIsArchivedDefaultsToFalse() throws {
        let person = makePerson()
        try context.save()

        XCTAssertFalse(person.isArchived, "A newly created person must be active by default.")

        // Re-fetch to prove the default came from the store, not just the
        // in-memory object.
        context.refreshAllObjects()
        let fetched = try XCTUnwrap(try context.fetch(Person.fetchRequest()).first)
        XCTAssertFalse(fetched.isArchived)
    }

    func testIsArchivedRoundTripsWhenSetTrue() throws {
        let person = makePerson()
        try context.save()

        person.isArchived = true
        try context.save()

        context.refreshAllObjects()
        let fetched = try XCTUnwrap(try context.fetch(Person.fetchRequest()).first)
        XCTAssertTrue(fetched.isArchived)
    }

    // MARK: - Archiving is non-destructive

    func testArchivingPersonLeavesAccountsPaychecksAndDepositsIntact() throws {
        let person = makePerson(name: "Jordan")
        let chase = makeAccount(bankName: "Chase", person: person)
        let sofi = makeAccount(bankName: "SoFi", person: person)
        let paycheck = makePaycheck(person: person, total: "2400.00")
        makeDirectDeposit(person: person, account: chase, paycheck: paycheck, amount: "500.00")
        makeDirectDeposit(person: person, account: sofi, paycheck: paycheck, amount: "250.00")
        try context.save()

        let personID = person.objectID

        // The soft delete itself — this is exactly what PersonSetupView does.
        person.isArchived = true
        try context.save()
        context.refreshAllObjects()

        // The person row itself survives (a hard delete would have removed it).
        let people = try context.fetch(Person.fetchRequest())
        XCTAssertEqual(people.count, 1)
        let archived = try XCTUnwrap(people.first)
        XCTAssertEqual(archived.objectID, personID)
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.name, "Jordan")

        // Accounts: still there, still owned by the archived person.
        let accounts = try context.fetch(Account.fetchRequest())
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.map(\.bankName)), ["Chase", "SoFi"])
        XCTAssertTrue(accounts.allSatisfy { $0.person?.objectID == personID })
        XCTAssertEqual(archived.accountsArray.count, 2)

        // Paychecks: history intact, and `paycheck.person` is still non-optional
        // and readable — the exact property a nullify-based hard delete would
        // have broken across Home/Calendar/Paycheck views.
        let paychecks = try context.fetch(Paycheck.fetchRequest())
        XCTAssertEqual(paychecks.count, 1)
        let fetchedPaycheck = try XCTUnwrap(paychecks.first)
        XCTAssertEqual(fetchedPaycheck.person.name, "Jordan")
        XCTAssertEqual(fetchedPaycheck.totalAmountDecimal, Decimal(string: "2400.00"))
        XCTAssertEqual(archived.paychecksArray.count, 1)

        // Direct deposits: both splits survive with their amounts and links.
        let deposits = try context.fetch(DirectDeposit.fetchRequest())
        XCTAssertEqual(deposits.count, 2)
        XCTAssertEqual(
            deposits.reduce(Decimal(0)) { $0 + $1.amountDecimal },
            Decimal(string: "750.00")
        )
        XCTAssertTrue(deposits.allSatisfy { $0.person?.objectID == personID })
        XCTAssertTrue(deposits.allSatisfy { $0.paycheck?.objectID == fetchedPaycheck.objectID })
        XCTAssertEqual(fetchedPaycheck.directDepositsArray.count, 2)
    }

    // MARK: - The `isArchived == NO` filter pattern

    func testActivePersonFetchExcludesArchivedPerson() throws {
        let active = makePerson(name: "Alex")
        let archived = makePerson(name: "Jordan")
        try context.save()

        archived.isArchived = true
        try context.save()
        context.refreshAllObjects()

        // The predicate every "current" person picker should adopt — same
        // convention already used for Account/Reminder.
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == NO")
        let activePeople = try context.fetch(request)

        XCTAssertEqual(activePeople.count, 1)
        XCTAssertEqual(activePeople.first?.name, "Alex")
        XCTAssertEqual(activePeople.first?.objectID, active.objectID)

        // ...while an unfiltered fetch (history, detail views) still sees both.
        XCTAssertEqual(try context.fetch(Person.fetchRequest()).count, 2)
    }
}
