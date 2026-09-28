import XCTest
import SwiftData
@testable import Vitals

/// Creates a temporary on-disk store location that is removed after the test.
func temporaryStoreDirectory(for test: XCTestCase) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

final class PersistenceTests: XCTestCase {
    @MainActor private func makeStore(_ directory: URL) throws -> WorkoutStore {
        WorkoutStore(container: try VitalsContainer.make(directory: directory))
    }

    @MainActor func testStrengthLogReopensWithTheSameValuesAndOrder() throws {
        let directory = temporaryStoreDirectory(for: self)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var sessionID = UUID()
        do {
            let store = try makeStore(directory)
            try store.updatePreferences { $0.unit = .pounds }
            let bench = try store.createExercise(name: "bench press")
            let pullup = try store.createExercise(name: "pull-up", isBodyweight: true)
            let session = try store.startSession(activity: .strength, at: start)
            sessionID = session.id
            let benchEntry = try store.addExercise(bench, to: session)
            let warmup = try XCTUnwrap(benchEntry.orderedSets.first)
            try store.update(warmup, reps: 8, loadKilograms: WeightUnit.pounds.kilograms(fromDisplayed: 95), kind: .warmup)
            let first = try store.addSet(to: benchEntry)
            try store.update(first, reps: 5, loadKilograms: WeightUnit.pounds.kilograms(fromDisplayed: 135), kind: .working)
            let second = try store.addSet(to: benchEntry)
            XCTAssertEqual(second.reps, 5, "a new set copies the preceding set")
            XCTAssertEqual(second.loadKilograms, first.loadKilograms)
            XCTAssertFalse(second.completed, "a copied set is never completed automatically")
            for set in [warmup, first, second] { try store.setCompleted(set, true, at: start.addingTimeInterval(60), restTarget: 90) }
            let pullupEntry = try store.addExercise(pullup, to: session)
            try store.update(try XCTUnwrap(pullupEntry.orderedSets.first), reps: 10, loadKilograms: 0)
            try store.moveExercises(in: session, from: IndexSet(integer: 1), to: 0)
            try store.finish(session, at: start.addingTimeInterval(1_800))
            // Switching the display unit never touches stored loads.
            try store.updatePreferences { $0.unit = .kilograms }
        }
        let reopened = try makeStore(directory)
        let session = try XCTUnwrap(try reopened.session(id: sessionID))
        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(session.orderedExercises.map(\.name), ["pull-up", "bench press"])
        let bench = session.orderedExercises[1].orderedSets
        XCTAssertEqual(bench.map(\.kind), [.warmup, .working, .working])
        XCTAssertEqual(bench.map(\.reps), [8, 5, 5])
        XCTAssertEqual(bench.map { LoadText.number($0.loadKilograms, unit: .pounds, locale: Locale(identifier: "en_US")) }, ["95", "135", "135"])
        XCTAssertEqual(bench.map(\.completed), [true, true, true])
        XCTAssertEqual(try reopened.preferences().unit, .kilograms)
        let summary = try reopened.summary(for: session, endingAt: session.endedAt!)
        XCTAssertEqual(summary.completedWorkingSets, 2)
        XCTAssertEqual(summary.volumeKilograms, 2 * 5 * WeightUnit.pounds.kilograms(fromDisplayed: 135), accuracy: 0.001)
        XCTAssertEqual(summary.duration, 1_800)
    }

    @MainActor func testRoutineIsCopiedAndNeverRewrittenBySessionEdits() throws {
        let directory = temporaryStoreDirectory(for: self)
        let store = try makeStore(directory)
        let squat = try store.createExercise(name: "squat")
        let routine = try store.createRoutine(name: "legs")
        try store.addExercise(squat, to: routine)
        try store.setTargets(try XCTUnwrap(routine.entries.first), sets: 3, reps: 5)
        let session = try store.startSession(activity: .strength, routine: routine)
        let entry = try XCTUnwrap(session.orderedExercises.first)
        XCTAssertEqual(entry.orderedSets.count, 3)
        XCTAssertEqual(entry.orderedSets.map(\.reps), [5, 5, 5])
        try store.update(entry.orderedSets[0], reps: 12)
        try store.delete(entry.orderedSets[2])
        try store.remove(entry)
        XCTAssertEqual(routine.entries.count, 1)
        XCTAssertEqual(routine.entries.first?.targetSets, 3)
        XCTAssertEqual(routine.entries.first?.targetReps, 5)
        XCTAssertEqual(session.routineName, "legs")
    }

    @MainActor func testOnlyOneActiveSessionAndItSurvivesLaunchRepair() throws {
        let directory = temporaryStoreDirectory(for: self)
        let store = try makeStore(directory)
        let session = try store.startSession(activity: .strength)
        XCTAssertThrowsError(try store.startSession(activity: .running)) { XCTAssertEqual($0 as? StoreError, .activeSessionExists) }
        try store.recoverAfterLaunch()
        XCTAssertEqual(try store.activeSession()?.id, session.id)
        XCTAssertTrue(session.isActive)
    }

    @MainActor func testDeleteRulesAreIntentional() throws {
        let directory = temporaryStoreDirectory(for: self)
        let store = try makeStore(directory)
        let row = try store.createExercise(name: "barbell row")
        let routine = try store.createRoutine(name: "pull")
        try store.addExercise(row, to: routine)
        let session = try store.startSession(activity: .strength)
        let entry = try store.addExercise(row, to: session)
        store.insertSample(HeartRateReading(peripheralID: UUID(), receivedAt: session.startedAt.addingTimeInterval(1),
                                            measurement: HeartRateMeasurement(bpm: 120, sensorContact: .detected, energyExpendedKilojoules: nil, rrIntervals: [800])),
                           into: session)
        try store.save()
        // Deleting a catalog exercise keeps the logged entry under its name and removes it from routines.
        try store.delete(row)
        XCTAssertNil(entry.exercise)
        XCTAssertEqual(entry.name, "barbell row")
        XCTAssertTrue(routine.entries.isEmpty)
        XCTAssertEqual(entry.orderedSets.count, 1)
        // Deleting a session removes its exercises, sets, and samples.
        try store.delete(session)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<SessionExercise>()), 0)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<LoggedSet>()), 0)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<HRSample>()), 0)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Routine>()), 1)
    }

    @MainActor func testRecordsAndVolumeAreRecomputedFromPersistedSets() throws {
        let directory = temporaryStoreDirectory(for: self)
        let store = try makeStore(directory)
        let bench = try store.createExercise(name: "bench press")
        let first = try store.startSession(activity: .strength, at: Date(timeIntervalSince1970: 1_000))
        let baseline = try XCTUnwrap(try store.addExercise(bench, to: first).orderedSets.first)
        try store.update(baseline, reps: 5, loadKilograms: 100)
        try store.setCompleted(baseline, true, restTarget: 90)
        try store.finish(first, at: Date(timeIntervalSince1970: 2_000))

        let second = try store.startSession(activity: .strength, at: Date(timeIntervalSince1970: 10_000))
        let entry = try store.addExercise(bench, to: second)
        let heavy = try XCTUnwrap(entry.orderedSets.first)
        XCTAssertEqual(heavy.loadKilograms, 100, "the first set starts from last time's load")
        try store.update(heavy, reps: 3, loadKilograms: 110)
        try store.setCompleted(heavy, true, restTarget: 90)
        // 110 × 3 beats both the 100 kg load and the 100 × 5 estimate (116.7 kg): 110 × (1 + 3/30) = 121 kg.
        let hits = try XCTUnwrap(try store.summary(for: second, endingAt: .now).records.first?.hits)
        XCTAssertEqual(hits.map(\.kind), [.heaviestLoad, .estimatedOneRepMax])
        XCTAssertEqual(hits.last?.value ?? 0, 121, accuracy: 0.001)
        XCTAssertEqual(hits.last?.previous ?? 0, 100 * (1 + 5.0 / 30), accuracy: 0.001)
        try store.finish(second, at: Date(timeIntervalSince1970: 11_000))
        XCTAssertEqual(try store.history(for: bench.id).rows.first?.hits.first?.value, 110)

        try store.update(heavy, loadKilograms: 95)
        XCTAssertTrue(try store.history(for: bench.id).rows.first?.hits.isEmpty ?? false, "editing the set removes the record")
        XCTAssertEqual(try store.summary(for: second, endingAt: second.endedAt!).volumeKilograms, 285, accuracy: 0.001)
        try store.delete(heavy)
        XCTAssertEqual(try store.summary(for: second, endingAt: second.endedAt!).volumeKilograms, 0)
        XCTAssertEqual(try store.history(for: bench.id).allTime.heaviestLoad, 100)
    }

    @MainActor func testBodyweightMovementsAreLoggedButNotComparedForRecords() throws {
        let directory = temporaryStoreDirectory(for: self)
        let store = try makeStore(directory)
        let dip = try store.createExercise(name: "dip", isBodyweight: true)
        let first = try store.startSession(activity: .strength, at: Date(timeIntervalSince1970: 1_000))
        let set = try XCTUnwrap(try store.addExercise(dip, to: first).orderedSets.first)
        try store.update(set, reps: 12, loadKilograms: 0)
        try store.setCompleted(set, true, restTarget: 90)
        try store.finish(first, at: Date(timeIntervalSince1970: 2_000))
        let second = try store.startSession(activity: .strength, at: Date(timeIntervalSince1970: 3_000))
        let weighted = try XCTUnwrap(try store.addExercise(dip, to: second).orderedSets.first)
        try store.update(weighted, reps: 8, loadKilograms: 20)
        try store.setCompleted(weighted, true, restTarget: 90)
        let summary = try store.summary(for: second, endingAt: .now)
        XCTAssertTrue(summary.records.isEmpty)
        XCTAssertEqual(summary.volumeKilograms, 160, "volume counts added external load only")
        XCTAssertEqual(try store.history(for: dip.id).mostBodyweightReps, 12)
    }

    @MainActor func testInterruptedExportBecomesRetryableAtLaunch() throws {
        let directory = temporaryStoreDirectory(for: self)
        let store = try makeStore(directory)
        let session = try store.startSession(activity: .walking)
        try store.finish(session, at: session.startedAt.addingTimeInterval(600))
        try store.setHealthState(session, .saving)
        try store.recoverAfterLaunch()
        XCTAssertEqual(session.healthState, .failed)
        XCTAssertNotNil(session.healthMessage)
    }
}
