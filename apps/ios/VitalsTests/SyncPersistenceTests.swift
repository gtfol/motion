import XCTest
import SwiftData
@testable import Vitals

@MainActor private final class MemoryCloud: SyncTransport {
    var records: [SyncKey: CloudRecord] = [:]
    var mutations: [UUID: SyncReply] = [:]
    var offline = false
    var pageSize = 100
    var loseNextAcknowledgement = false
    var revision: Int64 = 0
    var beforeReply: (() -> Void)?
    func pull(after: Int64) async throws -> [CloudRecord] {
        if offline { throw SyncFailure.unavailable }
        return Array(records.values.filter { $0.revision > after }.sorted { $0.revision < $1.revision }.prefix(pageSize))
    }
    func get(_ key: SyncKey) async throws -> CloudRecord? { records[key] }
    func apply(_ mutation: SyncMutation) async throws -> SyncReply {
        if offline { throw SyncFailure.unavailable }
        if let prior = mutations[mutation.mutationID] { return prior }
        if let old = records[mutation.key], old.revision != mutation.expectedRevision { return SyncReply(applied: false, record: old) }
        revision += 1
        let record = CloudRecord(kind: mutation.key.kind, id: mutation.key.id, revision: revision, body: mutation.body)
        records[mutation.key] = record
        let result = SyncReply(applied: true, record: record)
        mutations[mutation.mutationID] = result
        beforeReply?(); beforeReply = nil
        if loseNextAcknowledgement { loseNextAcknowledgement = false; throw SyncFailure.unavailable }
        return result
    }
}

final class SyncPersistenceTests: XCTestCase {
    @MainActor private func phone(owner: UUID, cloud: MemoryCloud) throws -> (WorkoutStore, CloudSync, URL) {
        let directory = temporaryStoreDirectory(for: self)
        let store = WorkoutStore(container: try VitalsContainer.make(directory: directory))
        let sync = try CloudSync(owner: owner, store: store, directory: directory, transport: cloud)
        return (store, sync, directory)
    }

    @MainActor func testSecondInstallationRestoresWorkoutAndRoutineWithoutDeviceHealthOrStrapState() async throws {
        let cloud = MemoryCloud(), owner = UUID()
        let (first, a, _) = try phone(owner: owner, cloud: cloud)
        try first.seedCatalogIfNeeded()
        let exercise = try first.createExercise(name: "test lift")
        let routine = try first.createRoutine(name: "test routine")
        try first.addExercise(exercise, to: routine)
        try first.updatePreferences { $0.unit = .kilograms; $0.age = 30; $0.strapID = UUID(); $0.strapName = "private pairing" }
        let workout = try first.startSession(activity: .strength)
        let entry = try first.addExercise(exercise, to: workout)
        let set = try XCTUnwrap(entry.orderedSets.first)
        try first.update(set, reps: 8, loadKilograms: 42)
        try first.setCompleted(set, true, at: .now, restTarget: 90)
        let sample = HRSample(timestamp: .now, bpm: 123, rrIntervals: Data([1, 2]))
        first.context.insert(sample); sample.session = workout
        try first.finish(workout, at: .now)
        workout.healthState = .saved; workout.healthWorkoutID = UUID()
        try first.save()
        await a.syncNow()
        XCTAssertNil(a.message)
        cloud.pageSize = 2 // Short pages can still have more records on the server.
        let (second, b, _) = try phone(owner: owner, cloud: cloud)
        await b.syncNow()
        XCTAssertNil(b.message)
        XCTAssertEqual(try first.syncSnapshot(), try second.syncSnapshot())
        let restored = try XCTUnwrap(try second.session(id: workout.id))
        XCTAssertEqual(restored.orderedExercises.first?.orderedSets.first?.loadKilograms, 42)
        XCTAssertEqual(restored.heartRateAverage, 123)
        XCTAssertEqual(restored.heartRateSamples.first?.rrIntervals, Data([1,2]))
        XCTAssertEqual(restored.healthState, .pending)
        XCTAssertNil(restored.healthWorkoutID); XCTAssertNil(restored.strapID)
        XCTAssertNil(try second.preferences().strapID)
        XCTAssertEqual(try second.context.fetch(FetchDescriptor<Routine>()).first?.orderedEntries.first?.exercise?.id, exercise.id)
        XCTAssertEqual(b.ledger.conflicts.count, 0)
    }

    @MainActor func testOfflineEditRestartsAndRetryAfterLostAckDoesNotDuplicate() async throws {
        let cloud = MemoryCloud(), owner = UUID()
        let (store, a, directory) = try phone(owner: owner, cloud: cloud)
        try store.seedCatalogIfNeeded()
        await a.syncNow()
        let exercise = try store.createExercise(name: "offline exercise")
        cloud.offline = true
        await a.syncNow()
        XCTAssertNotNil(a.message)
        let reopened = try CloudSync(owner: owner, store: store, directory: directory, transport: cloud)
        cloud.offline = false; cloud.loseNextAcknowledgement = true
        await reopened.syncNow()
        XCTAssertNotNil(reopened.message)
        let count = cloud.records.count
        await reopened.syncNow()
        XCTAssertNil(reopened.message)
        XCTAssertEqual(cloud.records.count, count)
        XCTAssertEqual(try cloud.records[SyncKey(kind: .exercise, id: exercise.id)]?.body?.decode(ExerciseDocument.self).name, "offline exercise")
        XCTAssertTrue(reopened.ledger.pending.isEmpty)
    }

    @MainActor func testDeletionVersusOfflineEditKeepsBothUntilUserChoosesCloud() async throws {
        let cloud = MemoryCloud(), owner = UUID()
        let (first, a, _) = try phone(owner: owner, cloud: cloud)
        let exercise = try first.createExercise(name: "original")
        await a.syncNow()
        let (second, b, _) = try phone(owner: owner, cloud: cloud)
        await b.syncNow()
        let other = try XCTUnwrap(try second.exercise(id: exercise.id))
        try second.update(other, name: "offline edit", category: nil, isBodyweight: false)
        try first.delete(exercise); await a.syncNow()
        await b.syncNow()
        let key = SyncKey(kind: .exercise, id: exercise.id)
        XCTAssertEqual(b.conflicts, [key]); XCTAssertEqual(try second.exercise(id: key.id)?.name, "offline edit")
        b.resolve(key, keepLocal: false)
        b.stop()
        XCTAssertNil(try second.exercise(id: key.id))
        XCTAssertNil(cloud.records[key]?.body)
    }

    @MainActor func testWrongAccountCannotOpenJournalAndStoppedEngineCannotApplyResponse() async throws {
        let cloud = MemoryCloud(), owner = UUID()
        let (store, a, directory) = try phone(owner: owner, cloud: cloud)
        await a.syncNow()
        XCTAssertThrowsError(try CloudSync(owner: UUID(), store: store, directory: directory, transport: cloud))
        let exercise = try store.createExercise(name: "interrupted")
        cloud.beforeReply = { a.stop() }
        await a.syncNow()
        XCTAssertNotNil(a.ledger.pending[SyncKey(kind: .exercise, id: exercise.id)])
        let (other, b, _) = try phone(owner: UUID(), cloud: MemoryCloud())
        await b.syncNow()
        XCTAssertNil(try other.exercise(id: exercise.id))
    }

    @MainActor func testRemoteWorkoutEditUpdatesChildrenAndKeepsLocalHealthExport() async throws {
        let cloud = MemoryCloud(), owner = UUID()
        let (first, a, _) = try phone(owner: owner, cloud: cloud)
        let exercise = try first.createExercise(name: "lift")
        let workout = try first.startSession(activity: .strength)
        let entry = try first.addExercise(exercise, to: workout)
        let initial = try XCTUnwrap(entry.orderedSets.first)
        try first.update(initial, reps: 8, loadKilograms: 10)
        let extra = try first.addSet(to: entry)
        try first.finish(workout, at: .now)
        await a.syncNow()
        let (second, b, _) = try phone(owner: owner, cloud: cloud)
        await b.syncNow()
        let restored = try XCTUnwrap(try second.session(id: workout.id))
        let healthID = UUID()
        restored.healthState = .saved; restored.healthWorkoutID = healthID
        try second.save()
        try first.update(initial, reps: 12, loadKilograms: 20)
        try first.delete(extra)
        await a.syncNow(); await b.syncNow()
        XCTAssertNil(a.message); XCTAssertNil(b.message)
        XCTAssertEqual(restored.orderedExercises.first?.sets.count, 1)
        XCTAssertEqual(restored.orderedExercises.first?.sets.first?.reps, 12)
        XCTAssertEqual(restored.healthState, .saved); XCTAssertEqual(restored.healthWorkoutID, healthID)
        XCTAssertEqual(try first.syncSnapshot(), try second.syncSnapshot())
    }

    @MainActor func testActiveWorkoutIsNeverSynced() async throws {
        let cloud = MemoryCloud()
        let (store, a, _) = try phone(owner: UUID(), cloud: cloud)
        let workout = try store.startSession(activity: .strength)
        await a.syncNow()
        XCTAssertNil(cloud.records[SyncKey(kind: .workout, id: workout.id)])
        XCTAssertTrue(workout.isActive)
    }

    @MainActor func testFreshInstallDoesNotReseedAnAccountContainingOnlyDeletedCatalogEntries() async throws {
        let cloud = MemoryCloud()
        let id = UUID(uuidString: "8BB72B11-63B6-4BF4-9865-000000000001")!
        let key = SyncKey(kind: .exercise, id: id)
        cloud.records[key] = CloudRecord(kind: .exercise, id: id, revision: 1, body: nil)
        cloud.revision = 1
        let (store, sync, _) = try phone(owner: UUID(), cloud: cloud)
        await sync.syncNow()
        XCTAssertNil(sync.message)
        XCTAssertTrue(try store.exercises().isEmpty)
        XCTAssertNil(cloud.records[key]?.body)
        XCTAssertTrue(try store.preferences().catalogSeeded)
    }
}
