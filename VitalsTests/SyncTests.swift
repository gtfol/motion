import XCTest
#if canImport(VitalsCore)
@testable import VitalsCore
#else
@testable import Vitals
#endif

final class SyncTests: XCTestCase {
    private let owner = UUID()
    private let key = SyncKey(kind: .workout, id: UUID())
    private func body(_ reps: Int) -> SyncValue { .object(["reps": .number(Double(reps))]) }
    private func record(_ revision: Int64, _ reps: Int?) -> CloudRecord {
        CloudRecord(kind: key.kind, id: key.id, revision: revision, body: reps.map(body))
    }
    func testOfflineEditsSurviveRestartAndLostAcknowledgementWithoutDuplicateUpload() throws {
        var phone = SyncLedger(owner: owner)
        phone.prepare(local: [key: body(8)])
        let request = try XCTUnwrap(phone.pending[key])
        phone = try SyncCoding.decoder().decode(SyncLedger.self, from: SyncCoding.encoder().encode(phone))
        phone.prepare(local: [key: body(8)])
        XCTAssertEqual(phone.pending[key]?.mutationID, request.mutationID)
        // Server committed, but its acknowledgement was lost. The next pull recognizes our exact data.
        XCTAssertEqual(try phone.receive(record(1,8), local:[key:body(8)]), .unchanged)
        XCTAssertTrue(phone.pending.isEmpty)
    }
    func testTwoPhonesEditingTheSameWorkoutKeepBothCopiesUntilResolved() throws {
        var phone = SyncLedger(owner: owner)
        _ = try phone.receive(record(1,5),local:[:])
        phone.prepare(local:[key:body(8)])
        XCTAssertEqual(try phone.receive(record(2,10),local:[key:body(8)]), .conflict)
        XCTAssertEqual(phone.conflicts[key]?.local,body(8))
        XCTAssertEqual(phone.conflicts[key]?.remote.body,body(10))
        XCTAssertTrue(phone.pending.isEmpty)
        _ = phone.resolve(key,keepLocal:true,local:[key:body(9)])
        XCTAssertEqual(phone.pending[key]?.expectedRevision,2)
        XCTAssertEqual(phone.pending[key]?.body,body(9))
    }
    func testRemoteDeletionDoesNotResurrectAfterAnOfflineEdit() throws {
        var phone = SyncLedger(owner:owner)
        _ = try phone.receive(record(1,5),local:[:])
        phone.prepare(local:[key:body(8)])
        XCTAssertEqual(try phone.receive(record(2,nil),local:[key:body(8)]), .conflict)
        XCTAssertNil(phone.pending[key])
        let deletion = phone.resolve(key,keepLocal:false,local:[key:body(8)])
        XCTAssertEqual(deletion,record(2,nil))
        phone.prepare(local:[:])
        XCTAssertTrue(phone.pending.isEmpty)
    }
    func testOfflineDeletionAndRemoteEditAreAConflict() throws {
        var phone=SyncLedger(owner:owner)
        _ = try phone.receive(record(1,5),local:[:])
        phone.prepare(local:[:])
        XCTAssertNil(try XCTUnwrap(phone.pending[key]).body)
        XCTAssertEqual(try phone.receive(record(2,7),local:[:]),.conflict)
        XCTAssertEqual(phone.resolve(key,keepLocal:false,local:[:]),record(2,7))
    }
    func testAnEditDuringUploadBecomesTheNextMutationInsteadOfBeingDiscarded() throws {
        var phone=SyncLedger(owner:owner)
        phone.prepare(local:[key:body(5)])
        let first=try XCTUnwrap(phone.pending[key])
        phone.prepare(local:[key:body(8)])
        try phone.acknowledge(first,record:record(1,5))
        phone.prepare(local:[key:body(8)])
        XCTAssertEqual(phone.pending[key]?.body,body(8))
        XCTAssertEqual(phone.pending[key]?.expectedRevision,1)
        XCTAssertNotEqual(phone.pending[key]?.mutationID,first.mutationID)
    }
    func testUnchangedPhoneAcceptsRemoteChangesAndIgnoresOlderPages() throws {
        var phone=SyncLedger(owner:owner)
        XCTAssertEqual(try phone.receive(record(4,12),local:[:]),.apply(record(4,12)))
        XCTAssertEqual(try phone.receive(record(2,5),local:[key:body(12)]),.unchanged)
        XCTAssertEqual(phone.records[key],record(4,12))
    }
    func testAnAccountsJournalCannotBeLoadedForAnotherAccount() throws {
        let phone=SyncLedger(owner:owner)
        XCTAssertNoThrow(try phone.validate(owner:owner))
        XCTAssertThrowsError(try phone.validate(owner:UUID()))
    }
    func testConflictPersistsAcrossRelaunchAndKeepsLaterPhoneEdits() throws {
        var phone=SyncLedger(owner:owner)
        _ = try phone.receive(record(1,5),local:[:])
        _ = try phone.receive(record(2,7),local:[key:body(9)])
        phone = try SyncCoding.decoder().decode(SyncLedger.self,from:SyncCoding.encoder().encode(phone))
        phone.prepare(local:[key:body(11)])
        XCTAssertEqual(phone.conflicts[key]?.local,body(11))
        XCTAssertEqual(phone.conflicts[key]?.remote.body,body(7))
    }
    func testFutureDocumentVersionIsRejectedInsteadOfDiscardingUnknownFields() throws {
        var exercise = ExerciseDocument(name: "future exercise", isBodyweight: false, createdAt: .now)
        exercise.version = 2
        let record = CloudRecord(kind: .exercise, id: UUID(), revision: 1, body: try .document(exercise))
        XCTAssertThrowsError(try SyncDocument.validate(record))
    }

}
