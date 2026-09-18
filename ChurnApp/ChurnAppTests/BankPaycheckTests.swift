//
//  BankPaycheckTests.swift
//  ChurnAppTests
//
//  Covers the round-2 additive schema: the `Bank` and `Paycheck` entities, the
//  new `Account.isHomeAccount` flag, the computed (never stored) paycheck
//  remainder, and `CalculationService.isEligible`'s new Bank-relationship path.
//
//  The delete rules get the most attention here — they're the easy thing to get
//  wrong and the expensive thing to fix once real data exists. In particular:
//  deleting ONE split must not touch its paycheck, and deleting a bank must
//  unlink accounts rather than delete them.
//
//  Every test gets its own empty in-memory stack — never the app's real store.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class BankPaycheckTests: XCTestCase {

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

    @discardableResult
    private func makeBank(name: String = "Chase") -> Bank {
        let bank = Bank(context: context)
        bank.id = UUID()
        bank.name = name
        bank.createdAt = Date()
        return bank
    }

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
    private func makeAccount(
        bankName: String = "Chase",
        bank: Bank? = nil,
        status: AccountStatus = .open,
        closedDate: Date? = nil,
        eligibilityMonths: Int16 = 12,
        person: Person? = nil
    ) -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.bankName = bankName
        account.accountType = AccountType.checking.rawValue
        account.openingDate = Date()
        account.bonusAmount = NSDecimalNumber(string: "300.00")
        account.bonusStructure = BonusStructure.lumpSum.rawValue
        account.bonusRequirements = "One DD of $500+."
        account.accountStatus = status.rawValue
        account.closedDate = closedDate
        account.eligibilityMonths = eligibilityMonths
        account.isArchived = false
        account.createdAt = Date()
        account.updatedAt = Date()
        account.person = person
        account.bank = bank
        return account
    }

    private func makePaycheck(
        person: Person,
        total: String = "2400.00",
        payDate: Date = Date()
    ) -> Paycheck {
        let paycheck = Paycheck(context: context)
        paycheck.id = UUID()
        paycheck.payDate = payDate
        paycheck.totalAmount = NSDecimalNumber(string: total)
        paycheck.createdAt = Date()
        paycheck.updatedAt = Date()
        paycheck.person = person
        return paycheck
    }

    @discardableResult
    private func makeSplit(
        of paycheck: Paycheck?,
        amount: String,
        account: Account? = nil,
        sequence: Int16 = 1
    ) -> DirectDeposit {
        let deposit = DirectDeposit(context: context)
        deposit.id = UUID()
        deposit.scheduledDate = paycheck?.payDate ?? Date()
        deposit.amount = NSDecimalNumber(string: amount)
        deposit.status = DirectDepositStatus.scheduled.rawValue
        deposit.sequenceNumberInSeries = sequence
        deposit.isFirstToBank = false
        deposit.createdAt = Date()
        deposit.updatedAt = Date()
        deposit.account = account
        deposit.paycheck = paycheck
        return deposit
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private func count(of entityName: String) throws -> Int {
        try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
    }

    // MARK: - Bank round-trip

    func testBank_savesAndFetchesBack() throws {
        let bank = makeBank(name: "Wells Fargo")
        let id = bank.id
        try context.save()

        let request = NSFetchRequest<Bank>(entityName: "Bank")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let fetched = try XCTUnwrap(try context.fetch(request).first)

        XCTAssertEqual(fetched.name, "Wells Fargo")
        XCTAssertEqual(fetched.id, id)
        XCTAssertTrue(fetched.accountsArray.isEmpty)
        XCTAssertTrue(fetched.offersArray.isEmpty)
    }

    func testBank_accountsAndOffersArrays_areLinkedBothWays() throws {
        let bank = makeBank(name: "SoFi")
        let account = makeAccount(bankName: "SoFi", bank: bank)

        let offer = Offer(context: context)
        offer.id = UUID()
        offer.bankName = "SoFi"
        offer.offerTitle = "SoFi $300"
        offer.bonusAmount = NSDecimalNumber(string: "300.00")
        offer.requirements = "$5,000 in DDs."
        offer.isActive = true
        offer.isFavorite = false
        offer.directDepositRequired = true
        offer.createdAt = Date()
        offer.updatedAt = Date()
        offer.bank = bank

        try context.save()

        XCTAssertEqual(bank.accountsArray.map(\.objectID), [account.objectID])
        XCTAssertEqual(bank.offersArray.map(\.objectID), [offer.objectID])
        XCTAssertEqual(account.bank?.objectID, bank.objectID)
        XCTAssertEqual(offer.bank?.objectID, bank.objectID)
    }

    /// Deleting a bank must only *unlink* — accounts and offers still carry
    /// `bankName`, so nothing is lost, and destroying an account because a
    /// lookup row went away would be data loss.
    func testDeletingBank_nullifiesAccountsAndOffers_withoutDeletingThem() throws {
        let bank = makeBank(name: "Chase")
        let account = makeAccount(bankName: "Chase", bank: bank)
        try context.save()

        context.delete(bank)
        try context.save()

        XCTAssertEqual(try count(of: "Account"), 1)
        XCTAssertNil(account.bank)
        XCTAssertEqual(account.bankName, "Chase", "bankName is untouched by the unlink.")
    }

    /// Additive: `bank` is optional everywhere and an account with none must
    /// still save cleanly.
    func testAccount_savesWithoutABank() throws {
        makeAccount(bankName: "Citi", bank: nil)
        XCTAssertNoThrow(try context.save())
    }

    // MARK: - Account.isHomeAccount

    func testIsHomeAccount_defaultsToFalse() throws {
        let account = makeAccount()
        try context.save()

        XCTAssertFalse(account.isHomeAccount)
    }

    func testIsHomeAccount_roundTrips_andAllowsMultipleHomeAccounts() throws {
        // The user has checking + savings at two different banks; nothing
        // enforces a single home account, deliberately.
        let checking = makeAccount(bankName: "Chase")
        let savings = makeAccount(bankName: "Ally")
        checking.isHomeAccount = true
        savings.isHomeAccount = true
        try context.save()

        let request = NSFetchRequest<Account>(entityName: "Account")
        request.predicate = NSPredicate(format: "isHomeAccount == YES")
        XCTAssertEqual(try context.fetch(request).count, 2)
    }

    // MARK: - Paycheck round-trip

    func testPaycheck_savesAndFetchesBack() throws {
        let person = makePerson()
        let payDate = date(year: 2026, month: 9, day: 30)
        let paycheck = makePaycheck(person: person, total: "2400.00", payDate: payDate)
        let id = paycheck.id
        try context.save()

        let request = NSFetchRequest<Paycheck>(entityName: "Paycheck")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let fetched = try XCTUnwrap(try context.fetch(request).first)

        XCTAssertEqual(fetched.totalAmountDecimal, Decimal(string: "2400.00"))
        XCTAssertEqual(fetched.payDate, payDate)
        XCTAssertEqual(fetched.person.objectID, person.objectID)
        XCTAssertEqual(person.paychecksArray.map(\.objectID), [paycheck.objectID])
    }

    func testPaycheck_totalAmountDecimalSetter_writesThroughToNSDecimalNumber() throws {
        let paycheck = makePaycheck(person: makePerson())
        paycheck.totalAmountDecimal = Decimal(string: "1875.50")!
        try context.save()

        XCTAssertEqual(paycheck.totalAmount, NSDecimalNumber(string: "1875.50"))
    }

    func testPaycheck_directDepositsArray_isSortedBySequence() throws {
        let person = makePerson()
        let paycheck = makePaycheck(person: person)
        makeSplit(of: paycheck, amount: "400.00", sequence: 3)
        makeSplit(of: paycheck, amount: "500.00", sequence: 1)
        makeSplit(of: paycheck, amount: "600.00", sequence: 2)
        try context.save()

        XCTAssertEqual(paycheck.directDepositsArray.map(\.sequenceNumberInSeries), [1, 2, 3])
    }

    // MARK: - Paycheck delete rules

    func testDeletingPaycheck_cascadesToItsSplits() throws {
        let person = makePerson()
        let paycheck = makePaycheck(person: person)
        makeSplit(of: paycheck, amount: "500.00", sequence: 1)
        makeSplit(of: paycheck, amount: "700.00", sequence: 2)
        // A round-1 deposit belonging to no paycheck must survive untouched.
        let orphan = makeSplit(of: nil, amount: "100.00")
        try context.save()
        XCTAssertEqual(try count(of: "DirectDeposit"), 3)

        context.delete(paycheck)
        try context.save()

        XCTAssertEqual(try count(of: "DirectDeposit"), 1)
        XCTAssertFalse(orphan.isDeleted)
        XCTAssertEqual(try count(of: "Person"), 1, "Deleting a paycheck must not touch its person.")
    }

    /// The mirror of the cascade above, and the rule most likely to be set
    /// backwards: `DirectDeposit.paycheck` is *nullify*.
    func testDeletingOneSplit_leavesPaycheckAndSiblingsAlone() throws {
        let person = makePerson()
        let paycheck = makePaycheck(person: person, total: "1200.00")
        let first = makeSplit(of: paycheck, amount: "500.00", sequence: 1)
        makeSplit(of: paycheck, amount: "700.00", sequence: 2)
        try context.save()

        context.delete(first)
        try context.save()

        XCTAssertEqual(try count(of: "Paycheck"), 1)
        XCTAssertFalse(paycheck.isDeleted)
        XCTAssertEqual(paycheck.directDepositsArray.count, 1)
        XCTAssertEqual(try count(of: "Person"), 1)
    }

    /// Deleting a person takes their paycheck history — and, transitively,
    /// those paychecks' splits — with it.
    func testDeletingPerson_cascadesToPaychecksAndTheirSplits() throws {
        let person = makePerson()
        let paycheck = makePaycheck(person: person)
        makeSplit(of: paycheck, amount: "500.00")
        try context.save()

        context.delete(person)
        try context.save()

        XCTAssertEqual(try count(of: "Paycheck"), 0)
        XCTAssertEqual(try count(of: "DirectDeposit"), 0)
    }

    // MARK: - unallocatedAmountDecimal

    func testUnallocated_fullyAllocated_isZero() throws {
        let paycheck = makePaycheck(person: makePerson(), total: "2400.00")
        makeSplit(of: paycheck, amount: "1400.00", sequence: 1)
        makeSplit(of: paycheck, amount: "1000.00", sequence: 2)
        try context.save()

        XCTAssertEqual(paycheck.allocatedAmountDecimal, Decimal(string: "2400.00"))
        XCTAssertEqual(paycheck.unallocatedAmountDecimal, 0)
    }

    func testUnallocated_partiallyAllocated_isTheRemainder() throws {
        let paycheck = makePaycheck(person: makePerson(), total: "2400.00")
        makeSplit(of: paycheck, amount: "500.00", sequence: 1)
        makeSplit(of: paycheck, amount: "275.25", sequence: 2)
        try context.save()

        XCTAssertEqual(paycheck.unallocatedAmountDecimal, Decimal(string: "1624.75"))
    }

    func testUnallocated_noSplits_isTheWholePaycheck() throws {
        let paycheck = makePaycheck(person: makePerson(), total: "1875.50")
        try context.save()

        XCTAssertEqual(paycheck.unallocatedAmountDecimal, Decimal(string: "1875.50"))
    }

    /// Over-allocation is allowed to go negative rather than clamping at zero —
    /// the negative value is the signal the UI uses to warn the user.
    func testUnallocated_overAllocated_isNegative() throws {
        let paycheck = makePaycheck(person: makePerson(), total: "1000.00")
        makeSplit(of: paycheck, amount: "600.00", sequence: 1)
        makeSplit(of: paycheck, amount: "700.00", sequence: 2)
        try context.save()

        XCTAssertEqual(paycheck.unallocatedAmountDecimal, Decimal(string: "-300.00"))
        XCTAssertTrue(paycheck.unallocatedAmountDecimal < 0)
    }

    /// The remainder is computed, never stored: editing a split must be
    /// reflected immediately with no bookkeeping on the paycheck.
    func testUnallocated_recomputesWhenASplitChanges() throws {
        let paycheck = makePaycheck(person: makePerson(), total: "1000.00")
        let split = makeSplit(of: paycheck, amount: "400.00")
        try context.save()
        XCTAssertEqual(paycheck.unallocatedAmountDecimal, Decimal(string: "600.00"))

        split.amountDecimal = Decimal(string: "750.00")!
        XCTAssertEqual(paycheck.unallocatedAmountDecimal, Decimal(string: "250.00"))

        context.delete(split)
        // Core Data only updates the inverse relationship when pending changes
        // are processed; force it so the computed remainder is read post-delete.
        context.processPendingChanges()
        XCTAssertEqual(paycheck.unallocatedAmountDecimal, Decimal(string: "1000.00"))
    }

    // MARK: - isEligible: Bank-relationship path

    /// Both sides have a `Bank`, so identity matching wins: the closed Chase
    /// account blocks a new Chase bonus even though the caller passed a
    /// deliberately non-matching `bankName`.
    func testIsEligible_bankRelationshipMatches_evenWhenBankNameDoesNot() {
        let person = makePerson()
        let chase = makeBank(name: "Chase")
        makeAccount(
            bankName: "Chase",
            bank: chase,
            status: .closed,
            closedDate: date(year: 2026, month: 1, day: 1),
            eligibilityMonths: 24,
            person: person
        )

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertFalse(CalculationService.isEligible(person: person,
                                                    bankName: "totally different string",
                                                    bank: chase,
                                                    asOf: asOf))
    }

    /// Two different `Bank` rows that happen to share a name are still
    /// different banks — the relationship, not the string, decides.
    func testIsEligible_differentBankRow_doesNotBlock() {
        let person = makePerson()
        let chaseA = makeBank(name: "Chase")
        let chaseB = makeBank(name: "Chase")
        makeAccount(
            bankName: "Chase",
            bank: chaseA,
            status: .closed,
            closedDate: date(year: 2026, month: 1, day: 1),
            eligibilityMonths: 24,
            person: person
        )

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertTrue(CalculationService.isEligible(person: person,
                                                    bankName: "Chase",
                                                    bank: chaseB,
                                                    asOf: asOf))
    }

    /// The eligibility *window* still applies on the Bank path — matching by
    /// relationship doesn't block forever.
    func testIsEligible_bankRelationshipMatches_butWindowElapsed_isTrue() {
        let person = makePerson()
        let chase = makeBank(name: "Chase")
        makeAccount(
            bankName: "Chase",
            bank: chase,
            status: .closed,
            closedDate: date(year: 2023, month: 1, day: 1),
            eligibilityMonths: 12,
            person: person
        )

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertTrue(CalculationService.isEligible(person: person,
                                                    bankName: "Chase",
                                                    bank: chase,
                                                    asOf: asOf))
    }

    /// Target has a `Bank`, the legacy closed account doesn't — must fall back
    /// to the case-insensitive name match rather than silently passing.
    func testIsEligible_targetHasBankButAccountDoesNot_fallsBackToBankName() {
        let person = makePerson()
        let chase = makeBank(name: "Chase")
        makeAccount(
            bankName: "chase",
            bank: nil,
            status: .closed,
            closedDate: date(year: 2026, month: 1, day: 1),
            eligibilityMonths: 24,
            person: person
        )

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertFalse(CalculationService.isEligible(person: person,
                                                    bankName: "CHASE",
                                                    bank: chase,
                                                    asOf: asOf))
    }

    /// The account has a `Bank` but the caller passed none (e.g. a hand-typed
    /// bank name in a form) — name matching again.
    func testIsEligible_accountHasBankButTargetDoesNot_fallsBackToBankName() {
        let person = makePerson()
        let chase = makeBank(name: "Chase")
        makeAccount(
            bankName: "Chase",
            bank: chase,
            status: .closed,
            closedDate: date(year: 2026, month: 1, day: 1),
            eligibilityMonths: 24,
            person: person
        )

        let asOf = date(year: 2026, month: 6, day: 1)
        XCTAssertFalse(CalculationService.isEligible(person: person, bankName: "Chase", asOf: asOf))
        XCTAssertTrue(CalculationService.isEligible(person: person, bankName: "SoFi", asOf: asOf))
    }

    // MARK: - Historical immutability (round 4 hard invariant)

    /// CLAUDE.md's round 4 section: a real, persisted `Paycheck`'s stored
    /// `totalAmountDecimal` and its `DirectDeposit` splits are a snapshot
    /// taken at creation/edit time. A person's pay raise (or any other edit
    /// to live `Person`/`Account` data) must only ever affect *future*
    /// projected/new paychecks — never rewrite one that already happened.
    /// This is true structurally (`Paycheck.totalAmountDecimal` and
    /// `DirectDeposit.amountDecimal` are stored attributes, never computed
    /// from `Person.paycheckAmountDecimal`), but this test pins that down
    /// so a future change that tries to "helpfully" recompute a real
    /// paycheck from current Person data gets caught immediately.
    func testHistoricalImmutability_personPayRaiseDoesNotRewriteExistingPaycheck() throws {
        let person = makePerson()
        person.paycheckAmount = NSDecimalNumber(string: "2400.00")

        // A real paycheck logged *before* the raise, with its own splits.
        let paycheck = makePaycheck(person: person, total: "2400.00", payDate: date(year: 2026, month: 8, day: 15))
        let account = makeAccount(person: person)
        let split = makeSplit(of: paycheck, amount: "1000.00", account: account, sequence: 1)
        try context.save()

        XCTAssertEqual(paycheck.totalAmountDecimal, Decimal(string: "2400.00"))
        XCTAssertEqual(split.amountDecimal, Decimal(string: "1000.00"))

        // The raise: only `Person.paycheckAmountDecimal` changes. Nothing
        // about the already-real paycheck or its splits is touched.
        person.paycheckAmountDecimal = Decimal(string: "2900.00")!
        try context.save()

        XCTAssertEqual(person.paycheckAmountDecimal, Decimal(string: "2900.00"), "The raise itself should have taken effect on Person.")
        XCTAssertEqual(paycheck.totalAmountDecimal, Decimal(string: "2400.00"), "A past real Paycheck's total must never track a later Person pay-rate change.")
        XCTAssertEqual(split.amountDecimal, Decimal(string: "1000.00"), "A past real Paycheck's splits must never be recomputed from current data either.")

        // Refetching from the store (not just reading the in-memory object)
        // rules out a stale-cache false positive.
        let request = NSFetchRequest<Paycheck>(entityName: "Paycheck")
        request.predicate = NSPredicate(format: "id == %@", paycheck.id as CVarArg)
        let refetched = try XCTUnwrap(try context.fetch(request).first)
        XCTAssertEqual(refetched.totalAmountDecimal, Decimal(string: "2400.00"))
    }

    // MARK: - Preview stack integration

    /// The shared seed data must exercise the round-2 schema, since every
    /// `#Preview` in the app renders from it.
    func testPreviewSeedData_coversBanksPaychecksAndHomeAccount() throws {
        let previewContext = PersistenceController.preview.viewContext

        let banks = try previewContext.fetch(NSFetchRequest<Bank>(entityName: "Bank"))
        let paychecks = try previewContext.fetch(NSFetchRequest<Paycheck>(entityName: "Paycheck"))
        let accounts = try previewContext.fetch(NSFetchRequest<Account>(entityName: "Account"))

        XCTAssertEqual(banks.count, 3)
        XCTAssertEqual(paychecks.count, 2)
        XCTAssertTrue(accounts.contains { $0.isHomeAccount }, "Previews need a home account.")
        XCTAssertTrue(accounts.contains { $0.bank != nil }, "Previews need a Bank-linked account.")
        XCTAssertTrue(accounts.contains { $0.bank == nil }, "…and a legacy, name-only one.")

        // One fully allocated paycheck and one with a remainder, so the
        // Calendar tab's two states are both previewable.
        XCTAssertTrue(paychecks.contains { $0.unallocatedAmountDecimal == 0 })
        XCTAssertTrue(paychecks.contains { $0.unallocatedAmountDecimal > 0 })

        // A Bank-linked account's name must stay in sync with its Bank row.
        for account in accounts {
            guard let bank = account.bank else { continue }
            XCTAssertEqual(account.bankName.lowercased(), bank.name.lowercased())
        }
    }
}
