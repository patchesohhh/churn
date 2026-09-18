//
//  Round3SchemaTests.swift
//  ChurnAppTests
//
//  Covers the round-3 additive schema:
//    - `Account.isChurnAccount` (defaults to TRUE, which is what keeps every
//      pre-round-3 row behaving identically after the model change),
//    - `Offer.offerTitle` becoming optional and the `Offer.displayTitle`
//      fallback that replaces it at display sites,
//    - `Paycheck.remainderAccount` and its nullify-both-ways delete rules.
//
//  As with the round-2 tests, the delete rules get the most attention: a
//  remainder destination is a routing preference, and losing it must never take
//  the paycheck (bookkeeping history) or the account with it.
//
//  Every test gets its own empty in-memory stack — never the app's real store.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class Round3SchemaTests: XCTestCase {

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

    /// Deliberately does NOT touch `isChurnAccount` — these tests rely on the
    /// model's own default value, exactly as a row created before round 3 would.
    @discardableResult
    private func makeAccount(
        bankName: String = "Chase",
        openingDate: Date = Date(),
        closedDate: Date? = nil,
        person: Person? = nil
    ) -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.bankName = bankName
        account.accountType = AccountType.checking.rawValue
        account.openingDate = openingDate
        account.bonusAmount = NSDecimalNumber(string: "300.00")
        account.bonusStructure = BonusStructure.lumpSum.rawValue
        account.bonusRequirements = "One DD of $500+."
        account.accountStatus = AccountStatus.open.rawValue
        account.closedDate = closedDate
        account.eligibilityMonths = 12
        account.isArchived = false
        account.createdAt = Date()
        account.updatedAt = Date()
        account.person = person
        return account
    }

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

    private func makeOffer(title: String?, bankName: String = "SoFi") -> Offer {
        let offer = Offer(context: context)
        offer.id = UUID()
        offer.bankName = bankName
        offer.offerTitle = title
        offer.bonusAmount = NSDecimalNumber(string: "300.00")
        offer.requirements = "$5,000 in DDs within 25 days."
        offer.directDepositRequired = true
        offer.isActive = true
        offer.isFavorite = false
        offer.createdAt = Date()
        offer.updatedAt = Date()
        return offer
    }

    // MARK: - Account.isChurnAccount

    func testIsChurnAccountDefaultsToTrue() throws {
        let account = makeAccount()
        // Core Data applies model defaults at insert time, so this is also the
        // value every account created before round 3 gets after migration.
        XCTAssertTrue(account.isChurnAccount)

        try context.save()
        context.refreshAllObjects()
        XCTAssertTrue(account.isChurnAccount)
    }

    func testIsChurnAccountIsIndependentOfIsHomeAccount() throws {
        let account = makeAccount()
        account.isHomeAccount = true
        try context.save()

        // Marking an account as "home" must not silently flip the churn flag —
        // a home account is allowed to be running a promotion too.
        XCTAssertTrue(account.isChurnAccount)
    }

    func testExplicitNonChurnAccountRoundTrips() throws {
        let account = makeAccount(bankName: "Ally")
        account.isHomeAccount = true
        account.isChurnAccount = false
        account.bonusAmount = NSDecimalNumber(string: "0")
        account.bonusRequirements = ""
        try context.save()
        context.refreshAllObjects()

        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "bankName == %@", "Ally")
        let fetched = try XCTUnwrap(try context.fetch(request).first)
        XCTAssertFalse(fetched.isChurnAccount)
        XCTAssertTrue(fetched.isHomeAccount)
        // The churn columns stay non-optional in the store; they just aren't
        // meaningful on this row.
        XCTAssertEqual(fetched.bonusAmountDecimal, 0)
        XCTAssertEqual(fetched.bonusStructureValue, .lumpSum)
    }

    func testNonChurnAccountsAreFetchableByPredicate() throws {
        makeAccount(bankName: "Chase")
        let home = makeAccount(bankName: "Ally")
        home.isChurnAccount = false
        try context.save()

        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "isChurnAccount == YES")
        XCTAssertEqual(try context.fetch(request).count, 1)
    }

    func testSampleDataIncludesANonChurnHomeAccount() throws {
        XCTAssertTrue(SampleData.populate(in: context))

        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "isChurnAccount == NO")
        let nonChurn = try context.fetch(request)
        XCTAssertEqual(nonChurn.count, 1)
        XCTAssertTrue(try XCTUnwrap(nonChurn.first).isHomeAccount)

        // Every other seeded account keeps the default — nothing in the seed
        // data changed behaviour for the round 1/2 rows.
        let churnRequest = Account.fetchRequest()
        churnRequest.predicate = NSPredicate(format: "isChurnAccount == YES")
        XCTAssertEqual(try context.fetch(churnRequest).count, 4)
    }

    // MARK: - CalculationService counters

    func testAccountCountersIgnoreNonChurnAccounts() {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())

        let churn = makeAccount(bankName: "Chase", closedDate: Date())
        let home = makeAccount(bankName: "Ally", closedDate: Date())
        home.isChurnAccount = false

        // Opening or closing the joint savings account isn't a churning
        // milestone, so only the churn account is counted.
        XCTAssertEqual(
            CalculationService.accountsOpenedThisYear(accounts: [churn, home], year: thisYear), 1)
        XCTAssertEqual(
            CalculationService.accountsClosedThisYear(accounts: [churn, home], year: thisYear), 1)
    }

    // MARK: - Offer.displayTitle

    func testDisplayTitleUsesTheTitleWhenPresent() {
        let offer = makeOffer(title: "SoFi Checking & Savings $300")
        XCTAssertEqual(offer.displayTitle, "SoFi Checking & Savings $300")
    }

    func testDisplayTitleFallsBackToBankNameWhenNil() {
        let offer = makeOffer(title: nil)
        XCTAssertNil(offer.offerTitle)
        XCTAssertEqual(offer.displayTitle, "SoFi")
    }

    func testDisplayTitleFallsBackToBankNameWhenBlank() {
        XCTAssertEqual(makeOffer(title: "").displayTitle, "SoFi")
        // Whitespace-only counts as absent, otherwise the UI renders a blank row.
        XCTAssertEqual(makeOffer(title: "   \n").displayTitle, "SoFi")
    }

    func testOfferSavesWithoutATitle() throws {
        let offer = makeOffer(title: nil)
        // The whole point of making it optional: validation must not reject this.
        XCTAssertNoThrow(try context.save())
        context.refreshAllObjects()
        XCTAssertNil(offer.offerTitle)
        XCTAssertEqual(offer.displayTitle, "SoFi")
    }

    // MARK: - Paycheck.remainderAccount

    func testRemainderAccountRoundTrips() throws {
        let person = makePerson()
        let home = makeAccount(bankName: "Ally", person: person)
        home.isHomeAccount = true
        home.isChurnAccount = false

        let paycheck = makePaycheck(person: person)
        paycheck.remainderAccount = home
        try context.save()
        context.refreshAllObjects()

        XCTAssertEqual(paycheck.remainderAccount?.objectID, home.objectID)
        // Inverse is maintained by Core Data.
        XCTAssertEqual(home.remainderForPaychecksArray.count, 1)
        XCTAssertEqual(home.remainderForPaychecksArray.first?.objectID, paycheck.objectID)
    }

    func testRemainderAccountIsOptional() throws {
        let person = makePerson()
        let paycheck = makePaycheck(person: person)
        XCTAssertNil(paycheck.remainderAccount)
        XCTAssertNoThrow(try context.save())
    }

    func testDeletingRemainderAccountNullifiesButKeepsThePaycheck() throws {
        let person = makePerson()
        let home = makeAccount(bankName: "Ally", person: person)
        home.isHomeAccount = true
        let paycheck = makePaycheck(person: person)
        paycheck.remainderAccount = home
        try context.save()

        context.delete(home)
        try context.save()

        // Nullify, not cascade: losing the destination account must never
        // destroy the paycheck record it was routed to.
        XCTAssertFalse(paycheck.isDeleted)
        XCTAssertNil(paycheck.remainderAccount)
        XCTAssertEqual(try context.count(for: Paycheck.fetchRequest()), 1)
    }

    func testDeletingThePaycheckLeavesTheRemainderAccountAlone() throws {
        let person = makePerson()
        let home = makeAccount(bankName: "Ally", person: person)
        home.isHomeAccount = true
        let paycheck = makePaycheck(person: person)
        paycheck.remainderAccount = home
        try context.save()

        context.delete(paycheck)
        try context.save()

        XCTAssertFalse(home.isDeleted)
        XCTAssertTrue(home.remainderForPaychecksArray.isEmpty)
        XCTAssertEqual(try context.count(for: Account.fetchRequest()), 1)
    }

    func testMultiplePaychecksCanShareOneRemainderAccount() throws {
        let alex = makePerson(name: "Alex")
        let jordan = makePerson(name: "Jordan")
        let joint = makeAccount(bankName: "Ally")
        joint.isHomeAccount = true

        // A couple routing both their remainders into a shared account is the
        // explicit use case for putting this on the paycheck, not the person.
        let a = makePaycheck(person: alex)
        a.remainderAccount = joint
        let j = makePaycheck(person: jordan)
        j.remainderAccount = joint
        try context.save()

        XCTAssertEqual(joint.remainderForPaychecksArray.count, 2)
    }

    func testSampleDataSetsARemainderAccount() throws {
        XCTAssertTrue(SampleData.populate(in: context))

        let request = Paycheck.fetchRequest()
        let withRemainder = try context.fetch(request).filter { $0.remainderAccount != nil }
        XCTAssertEqual(withRemainder.count, 1)
        let paycheck = try XCTUnwrap(withRemainder.first)
        XCTAssertTrue(try XCTUnwrap(paycheck.remainderAccount).isHomeAccount)
        // The partially-allocated sample paycheck is the one with a remainder.
        XCTAssertTrue(paycheck.unallocatedAmountDecimal > 0)
    }
}
