import XCTest
import SwiftData
@testable import Vitals

/// A stand-in for Apple Health that records what it was asked to write.
final class FakeExporter: WorkoutExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var currentAccess: HealthAccess
    private var outcomes: [HealthExportOutcome]
    private var received: [HealthWorkoutPayload] = []

    init(access: HealthAccess, outcomes: [HealthExportOutcome] = []) {
        currentAccess = access
        self.outcomes = outcomes
    }

    var payloads: [HealthWorkoutPayload] { lock.withLock { received } }

    func access() -> HealthAccess { lock.withLock { currentAccess } }
    func requestAccess() async -> HealthAccess { access() }

    func export(_ payload: HealthWorkoutPayload) async -> HealthExportOutcome {
        lock.withLock {
            received.append(payload)
            if case .denied = currentAccess { return .notAllowed }
            return outcomes.isEmpty ? .saved(workoutID: UUID(), heartRateSamples: payload.samples.count) : outcomes.removeFirst()
        }
    }
}

final class CoordinatorTests: XCTestCase {
    @MainActor private func makeCoordinator(_ exporter: FakeExporter, directory: URL) throws -> SessionCoordinator {
        let store = WorkoutStore(container: try VitalsContainer.make(directory: directory))
        let coordinator = SessionCoordinator(store: store, exporter: exporter)
        coordinator.launch()
        return coordinator
    }

    private func reading(_ bpm: Int, at date: Date, strap: UUID = UUID()) -> HeartRateReading {
        HeartRateReading(peripheralID: strap, receivedAt: date,
                         measurement: HeartRateMeasurement(bpm: bpm, sensorContact: .unsupported, energyExpendedKilojoules: nil, rrIntervals: []))
    }

    @MainActor func testWorkoutWithoutStrapAndWithHealthDeniedIsFullyUsable() async throws {
        let directory = temporaryStoreDirectory(for: self)
        let exporter = FakeExporter(access: .denied)
        let coordinator = try makeCoordinator(exporter, directory: directory)
        let bench = try XCTUnwrap(try coordinator.store.exercises().first { $0.name == "bench press" }, "the starter catalog is seeded")
        XCTAssertTrue(coordinator.start(.strength))
        coordinator.add(bench)
        let session = try XCTUnwrap(coordinator.activeSession)
        let set = try XCTUnwrap(session.orderedExercises.first?.orderedSets.first)
        try coordinator.store.update(set, reps: 5, loadKilograms: 60)
        coordinator.toggleCompleted(set)
        XCTAssertNotNil(session.restTimer, "completing a set starts rest")
        XCTAssertEqual(session.restTimer?.target, coordinator.restTarget)
        coordinator.extendRest()
        XCTAssertEqual(session.restTimer?.target, coordinator.restTarget + 30)
        coordinator.skipRest()
        XCTAssertNil(session.restTimer)
        await coordinator.finish(session, at: session.startedAt.addingTimeInterval(1_200))
        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(session.state, .completed)
        XCTAssertNotNil(session.localSavedAt)
        XCTAssertEqual(session.healthState, .notAllowed, "a denied export is recorded separately from the local save")
        XCTAssertEqual(session.exercises.first?.sets.first?.completed, true)
    }

    @MainActor func testHeartRateIsRecordedOnlyDuringASessionAndGapsStay() throws {
        let directory = temporaryStoreDirectory(for: self)
        let coordinator = try makeCoordinator(FakeExporter(access: .allowed(heartRate: true)), directory: directory)
        let start = Date.now
        coordinator.receive(reading(80, at: start.addingTimeInterval(-30)))
        XCTAssertEqual(try coordinator.store.context.fetchCount(FetchDescriptor<HRSample>()), 0, "live readings outside a workout aren't saved")
        XCTAssertTrue(coordinator.start(.running, at: start))
        for offset in [1.0, 2, 3, 40, 41] { coordinator.receive(reading(120, at: start.addingTimeInterval(offset)), strapName: "helio strap") }
        try coordinator.store.save()
        let session = try XCTUnwrap(coordinator.activeSession)
        XCTAssertEqual(session.heartRateSamples.count, 5)
        XCTAssertEqual(session.strapName, "helio strap")
        XCTAssertEqual(coordinator.liveStats.count, 5)
        XCTAssertEqual(HeartRateSeries.gaps(in: coordinator.liveSamples).count, 1, "the disconnect shows as a gap, not filled in")
    }

    @MainActor func testRetryNeverCreatesASecondHealthWorkout() async throws {
        let directory = temporaryStoreDirectory(for: self)
        let exporter = FakeExporter(access: .allowed(heartRate: true),
                                    outcomes: [.failed("apple health didn’t save the workout. retry."), .alreadySaved(workoutID: UUID())])
        let coordinator = try makeCoordinator(exporter, directory: directory)
        XCTAssertTrue(coordinator.start(.cycling))
        let session = try XCTUnwrap(coordinator.activeSession)
        await coordinator.finish(session, at: session.startedAt.addingTimeInterval(900))
        XCTAssertEqual(session.healthState, .failed)
        XCTAssertEqual(session.localSavedAt != nil, true, "the local save stands even though export failed")
        await coordinator.exportToHealth(session)
        XCTAssertEqual(session.healthState, .saved)
        await coordinator.exportToHealth(session)
        XCTAssertEqual(exporter.payloads.count, 2, "a saved workout is never exported again")
        XCTAssertEqual(Set(exporter.payloads.map(\.sessionID)), [session.id], "every attempt uses the same session identity")
    }

    @MainActor func testRelaunchRestoresTheActiveSessionInsteadOfStartingAnother() async throws {
        let directory = temporaryStoreDirectory(for: self)
        let start = Date.now.addingTimeInterval(-600)
        var sessionID = UUID()
        do {
            let coordinator = try makeCoordinator(FakeExporter(access: .notDetermined), directory: directory)
            XCTAssertTrue(coordinator.start(.strength, at: start))
            let session = try XCTUnwrap(coordinator.activeSession)
            sessionID = session.id
            coordinator.add(try XCTUnwrap(try coordinator.store.exercises().first))
            let set = try XCTUnwrap(session.orderedExercises.first?.orderedSets.first)
            coordinator.toggleCompleted(set, at: start.addingTimeInterval(120))
            coordinator.receive(reading(130, at: start.addingTimeInterval(125)))
            coordinator.heartbeat(at: start.addingTimeInterval(150))
        }
        let relaunched = try makeCoordinator(FakeExporter(access: .notDetermined), directory: directory)
        let session = try XCTUnwrap(relaunched.activeSession)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(relaunched.recoveredSession?.id, sessionID, "the user is asked to continue or finish")
        XCTAssertEqual(session.orderedExercises.first?.orderedSets.first?.completed, true)
        XCTAssertEqual(session.restTimer?.startedAt, start.addingTimeInterval(120), "rest continues from its stored start")
        XCTAssertEqual(relaunched.liveSamples.count, 1)
        XCTAssertEqual(relaunched.recoveredEnd(for: session), start.addingTimeInterval(150))
        XCTAssertFalse(relaunched.start(.strength), "no second workout while one is unfinished")
        XCTAssertEqual(try relaunched.store.context.fetchCount(FetchDescriptor<WorkoutSession>()), 1)
        await relaunched.finish(session, at: relaunched.recoveredEnd(for: session))
        XCTAssertEqual(session.endedAt, start.addingTimeInterval(150))
    }

    @MainActor func testDiscardRemovesTheSessionById() throws {
        let directory = temporaryStoreDirectory(for: self)
        let coordinator = try makeCoordinator(FakeExporter(access: .unavailable), directory: directory)
        XCTAssertTrue(coordinator.start(.other))
        let id = try XCTUnwrap(coordinator.activeSession?.id)
        coordinator.discard(id: id)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertNil(try coordinator.store.session(id: id))
    }
}
