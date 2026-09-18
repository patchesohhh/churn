//
//  Round5PaycheckDeleteCrashTests.swift
//  ChurnAppTests
//
//  Covers the round-5 "delete paycheck freezes/crashes the app" bug fixed in
//  PaycheckDetailView.swift. Root cause: `paycheck` is an `@ObservedObject`,
//  so `viewContext.delete(paycheck)` fires `objectWillChange` and forces a
//  `body` re-render *before* `dismiss()` has torn the view down — that
//  re-render used to read `paycheck.payDate` / `paycheck.person.name` on a
//  now-deleted (faulted) managed object and crash.
//
//  The fix adds an `isBeingDeleted` guard (flipped before the Core Data
//  delete happens) plus `paycheck.isDeleted` / `managedObjectContext == nil`
//  as belt-and-suspenders signals, and short-circuits `body` to a minimal
//  placeholder whenever any of them is true — so the forced re-render never
//  touches a property on the deleted object.
//
//  This test can't drive SwiftUI's `body` directly (that needs a live
//  simulator run — see the round-5 handoff notes), so it verifies the
//  Core-Data-level signals `PaycheckDetailView.isPaycheckGone` relies on
//  actually flip the way the guard assumes, at the exact points in the
//  delete sequence where the view reads them. It deliberately does NOT
//  re-access a property on the deleted object after the fact — doing that
//  is the crash itself, not a way to test the fix.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class Round5PaycheckDeleteCrashTests: XCTestCase {

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

    private func makePaycheck() -> Paycheck {
        let person = Person(context: context)
        person.id = UUID()
        person.name = "Alex"
        person.payFrequency = PayFrequency.biweekly.rawValue
        person.paycheckAmount = NSDecimalNumber(string: "2400.00")
        person.maxConcurrentDirectDeposits = 3
        person.createdAt = Date()
        person.updatedAt = Date()

        let paycheck = Paycheck(context: context)
        paycheck.id = UUID()
        paycheck.payDate = Date()
        paycheck.totalAmount = NSDecimalNumber(string: "2400.00")
        paycheck.createdAt = Date()
        paycheck.updatedAt = Date()
        paycheck.person = person

        try? context.save()
        return paycheck
    }

    /// `viewContext.delete(paycheck)` must mark the object `isDeleted`
    /// synchronously, *before* `save()` — this is the first guard signal
    /// `PaycheckDetailView.isPaycheckGone` can lean on (alongside the
    /// view's own `isBeingDeleted` flag, which flips even earlier).
    func testIsDeletedFlipsImmediatelyAfterContextDelete() {
        let paycheck = makePaycheck()
        XCTAssertFalse(paycheck.isDeleted)

        context.delete(paycheck)

        XCTAssertTrue(paycheck.isDeleted)
    }

    /// After `save()` actually commits the delete, the object is detached
    /// from its context — the second guard signal.
    func testManagedObjectContextIsNilAfterDeleteAndSave() throws {
        let paycheck = makePaycheck()
        context.delete(paycheck)

        try context.save()

        XCTAssertNil(paycheck.managedObjectContext)
    }

    /// Deleting a paycheck must not touch sibling paychecks — a guard that
    /// fires too broadly (e.g. keyed off something shared) would hide
    /// unrelated paychecks too.
    func testDeletingOnePaycheckLeavesSiblingsUntouched() throws {
        let keep = makePaycheck()
        let doomed = makePaycheck()

        context.delete(doomed)
        try context.save()

        XCTAssertFalse(keep.isDeleted)
        XCTAssertNotNil(keep.managedObjectContext)
    }
}
