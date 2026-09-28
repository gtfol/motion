import Foundation
import Observation
import SwiftData

/// Ties the local log, the strap, and Apple Health together for one workout at a time.
/// Local logging never waits for heart rate or Health: both are optional.
@MainActor @Observable final class SessionCoordinator {
    let store: WorkoutStore
    let exporter: any WorkoutExporting
    /// The stored settings. A model, so views reading the unit or rest time update when settings change.
    let settings: AppPreferences?

    private(set) var activeSession: WorkoutSession?
    /// Set at launch when an unfinished session was found; the user chooses to continue or finish it.
    private(set) var recoveredSession: WorkoutSession?
    /// Received samples of the active session, in memory for the live chart and statistics.
    private(set) var liveSamples: [HeartRatePoint] = []
    private(set) var liveStats = HeartRateStats()
    private(set) var exporting: Set<UUID> = []
    private(set) var healthAccess: HealthAccess = .notDetermined
    var message: String?

    @ObservationIgnored private var lastSampleSave = Date.distantPast
    static let sampleSaveInterval: TimeInterval = 5

    init(store: WorkoutStore, exporter: any WorkoutExporting) {
        self.store = store
        self.exporter = exporter
        self.settings = try? store.preferences()
    }

    var unit: WeightUnit { settings?.unit ?? .pounds }
    var restTarget: TimeInterval { TimeInterval(RestTimer.clampedTarget(settings?.defaultRestSeconds ?? RestTimer.defaultTarget)) }
    var age: Int? { settings?.age }

    func updateSettings(_ change: (AppPreferences) -> Void) {
        perform { try store.updatePreferences(change) }
    }

    /// Recovers local state first: interrupted exports become retryable and an unfinished session is restored,
    /// never replaced by a new one.
    func launch() {
        do {
            try store.recoverAfterLaunch()
            try store.seedCatalogIfNeeded()
            if let session = try store.activeSession() {
                activeSession = session
                recoveredSession = session
                liveSamples = session.heartRatePoints
                liveStats = HeartRateStats(liveSamples)
            }
        } catch {
            message = error.localizedDescription
        }
        healthAccess = exporter.access()
    }

    // MARK: Session lifecycle

    @discardableResult func start(_ activity: ActivityKind, routine: Routine? = nil, at date: Date = .now) -> Bool {
        do {
            let session = try store.startSession(activity: activity, routine: routine, at: date)
            activeSession = session
            recoveredSession = nil
            liveSamples = []; liveStats = HeartRateStats()
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func continueRecovered() {
        recoveredSession = nil
    }

    /// The honest end time for a session restored after the app was closed: its last known activity.
    func recoveredEnd(for session: WorkoutSession) -> Date {
        store.lastActivity(of: session)
    }

    func summary(for session: WorkoutSession, endingAt end: Date) -> WorkoutSummary? {
        do { return try store.summary(for: session, endingAt: end) } catch { message = error.localizedDescription; return nil }
    }

    /// Saves locally first, then exports to Apple Health. Each has its own state.
    func finish(_ session: WorkoutSession, at end: Date) async {
        do {
            try store.finish(session, at: end)
        } catch {
            message = error.localizedDescription
            return
        }
        if activeSession?.id == session.id {
            activeSession = nil; recoveredSession = nil
            liveSamples = []; liveStats = HeartRateStats()
        }
        await exportToHealth(session)
    }

    /// Deletes a session with its sets and samples, by identifier so no view keeps a deleted model.
    /// A copy already in Apple Health stays there.
    func discard(id: UUID) {
        do {
            if activeSession?.id == id {
                activeSession = nil; recoveredSession = nil
                liveSamples = []; liveStats = HeartRateStats()
            }
            if let session = try store.session(id: id) { try store.delete(session) }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Logging

    func perform(_ change: () throws -> Void) {
        do { try change(); message = nil } catch { message = error.localizedDescription }
    }

    func add(_ exercise: Exercise) {
        guard let session = activeSession else { return }
        perform { try store.addExercise(exercise, to: session) }
    }

    func addSet(to entry: SessionExercise) {
        perform { try store.addSet(to: entry) }
    }

    func toggleCompleted(_ set: LoggedSet, at date: Date = .now) {
        perform { try store.setCompleted(set, !set.completed, at: date, restTarget: restTarget) }
    }

    func extendRest() {
        guard let session = activeSession else { return }
        perform { try store.extendRest(session) }
    }

    func skipRest() {
        guard let session = activeSession else { return }
        perform { try store.skipRest(session) }
    }

    // MARK: Heart rate

    /// Records a reading into the active session. Samples are saved in small batches; missing periods are never filled.
    func receive(_ reading: HeartRateReading, strapName: String? = nil) {
        guard let session = activeSession, session.isActive else { return }
        if session.strapID != reading.peripheralID { session.strapID = reading.peripheralID; session.strapName = strapName }
        store.insertSample(reading, into: session)
        store.markSeen(session, at: reading.receivedAt)
        liveSamples.append(reading.point)
        liveStats.add(reading.point)
        if reading.receivedAt.timeIntervalSince(lastSampleSave) >= Self.sampleSaveInterval {
            lastSampleSave = reading.receivedAt
            perform { try store.save() }
        }
    }

    /// Called periodically and when the app leaves the foreground, so an interrupted session knows when it last ran.
    func heartbeat(at date: Date = .now) {
        guard let session = activeSession else { return }
        store.markSeen(session, at: date)
        perform { try store.save() }
    }

    // MARK: Apple Health

    func refreshHealthAccess() {
        healthAccess = exporter.access()
    }

    func requestHealthAccess() async {
        healthAccess = await exporter.requestAccess()
    }

    /// Exports one finished session. The "saving" state is stored before anything is written to Health, so an
    /// interrupted attempt is detected at launch; a retry looks for the earlier workout before writing again.
    func exportToHealth(_ session: WorkoutSession) async {
        guard session.state == .completed, session.healthState != .saved, !exporting.contains(session.id) else { return }
        exporting.insert(session.id)
        defer { exporting.remove(session.id) }
        do {
            try store.setHealthState(session, .saving)
            let payload = store.healthPayload(for: session)
            let outcome = await exporter.export(payload)
            switch outcome {
            case .saved(let workoutID, let samples):
                let note: String? = if payload.samples.isEmpty { "no heart-rate samples were recorded." }
                    else if samples == 0 { "heart rate wasn’t included: writing heart rate isn’t allowed." }
                    else { nil }
                try store.setHealthState(session, .saved, workoutID: workoutID, message: note)
            case .alreadySaved(let workoutID):
                try store.setHealthState(session, .saved, workoutID: workoutID, message: "already in Apple Health; nothing new was written.")
            case .notAllowed:
                try store.setHealthState(session, .notAllowed,
                                         message: "allow vitals to write workouts in the Health app: tap your profile, then Apps → vitals.")
            case .unavailable:
                try store.setHealthState(session, .unavailable) // the state reads "unavailable on this device"
            case .failed(let reason):
                try store.setHealthState(session, .failed, message: reason)
            }
        } catch {
            message = error.localizedDescription
        }
        healthAccess = exporter.access()
    }
}
