import Foundation
import SwiftData

enum StoreError: LocalizedError, Equatable {
    case activeSessionExists
    case emptyName
    case invalidValue
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .activeSessionExists: "a workout is already in progress. continue or finish it first."
        case .emptyName: "enter a name."
        case .invalidValue: "that value can’t be saved."
        case .saveFailed: "couldn’t save on this iPhone. try again."
        }
    }
}

/// Every local change goes through here and is saved immediately, so an active session survives
/// the app being closed at any point. Heart-rate samples are the exception: see `insertSample`.
@MainActor final class WorkoutStore {
    /// Held here because a context doesn't keep its container alive; using a context whose container was
    /// released crashes.
    let container: ModelContainer
    let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
        context.autosaveEnabled = false
    }

    func save() throws {
        guard context.hasChanges else { return }
        do { try context.save() } catch { context.rollback(); throw StoreError.saveFailed }
    }

    // MARK: Preferences and catalog

    func preferences() throws -> AppPreferences {
        let key = AppPreferences.singletonKey
        if let existing = try context.fetch(FetchDescriptor<AppPreferences>(predicate: #Predicate { $0.key == key })).first {
            return existing
        }
        let created = AppPreferences()
        context.insert(created)
        try save()
        return created
    }

    func updatePreferences(_ change: (AppPreferences) -> Void) throws {
        change(try preferences())
        try save()
    }

    static let starterCatalog: [(name: String, category: String?, bodyweight: Bool)] = [
        ("bench press", "chest", false), ("squat", "legs", false), ("deadlift", "back", false),
        ("overhead press", "shoulders", false), ("barbell row", "back", false), ("romanian deadlift", "legs", false),
        ("lat pulldown", "back", false), ("dumbbell curl", "arms", false),
        ("pull-up", "back", true), ("push-up", "chest", true), ("dip", "chest", true)
    ]

    /// A small editable starting catalog, added once. Deleted entries don't come back.
    func seedCatalogIfNeeded() throws {
        let preferences = try preferences()
        guard !preferences.catalogSeeded else { return }
        if try context.fetchCount(FetchDescriptor<Exercise>()) == 0 {
            for (offset, item) in Self.starterCatalog.enumerated() {
                context.insert(Exercise(name: item.name, category: item.category, isBodyweight: item.bodyweight,
                                        createdAt: Date(timeIntervalSince1970: TimeInterval(offset))))
            }
        }
        preferences.catalogSeeded = true
        try save()
    }

    func exercises() throws -> [Exercise] {
        try context.fetch(FetchDescriptor<Exercise>(sortBy: [SortDescriptor(\Exercise.name)]))
    }

    func exercise(id: UUID) throws -> Exercise? {
        try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })).first
    }

    /// Creates a catalog exercise, or returns the existing one with the same name (ignoring case).
    @discardableResult func createExercise(name: String, category: String? = nil, isBodyweight: Bool = false) throws -> Exercise {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        if let existing = try exercises().first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let exercise = Exercise(name: trimmed, category: Self.cleaned(category), isBodyweight: isBodyweight)
        context.insert(exercise)
        try save()
        return exercise
    }

    func update(_ exercise: Exercise, name: String, category: String?, isBodyweight: Bool) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        exercise.name = trimmed; exercise.category = Self.cleaned(category); exercise.isBodyweight = isBodyweight
        try save()
    }

    /// Removes the exercise from the catalog and from routines. Past sessions keep their sets under the
    /// last known name.
    func delete(_ exercise: Exercise) throws {
        for entry in exercise.sessionEntries {
            entry.nameSnapshot = exercise.name; entry.bodyweightSnapshot = exercise.isBodyweight
        }
        context.delete(exercise)
        try save()
    }

    /// Exercises from the most recent sessions, most recent first.
    func recentExercises(limit: Int = 8) throws -> [Exercise] {
        var descriptor = FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\WorkoutSession.startedAt, order: .reverse)])
        descriptor.fetchLimit = 30
        var seen = Set<UUID>(), recent: [Exercise] = []
        for session in try context.fetch(descriptor) {
            for entry in session.orderedExercises {
                if let exercise = entry.exercise, seen.insert(exercise.id).inserted { recent.append(exercise) }
            }
            if recent.count >= limit { break }
        }
        return Array(recent.prefix(limit))
    }

    // MARK: Sessions

    func activeSession() throws -> WorkoutSession? {
        try activeSessions().first
    }

    func session(id: UUID) throws -> WorkoutSession? {
        try context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })).first
    }

    private func activeSessions() throws -> [WorkoutSession] {
        let active = SessionState.active.rawValue
        return try context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.stateRaw == active },
                                                                 sortBy: [SortDescriptor(\WorkoutSession.startedAt, order: .reverse)]))
    }

    /// Starts a session. Refuses while another is active so a relaunch can never start a second workout silently.
    /// A routine is copied: later edits to the session never change the routine.
    func startSession(activity: ActivityKind, routine: Routine? = nil, at date: Date = .now) throws -> WorkoutSession {
        guard try activeSession() == nil else { throw StoreError.activeSessionExists }
        let preferences = try preferences()
        let session = WorkoutSession(activity: activity, startedAt: date, unit: preferences.unit)
        session.strapID = preferences.strapID; session.strapName = preferences.strapName
        context.insert(session)
        if let routine, activity.logsSets {
            session.routineID = routine.id; session.routineName = routine.name
            for (index, template) in routine.orderedEntries.enumerated() {
                guard let exercise = template.exercise else { continue }
                let entry = insertEntry(exercise, order: index, in: session, targetSets: template.targetSets, targetReps: template.targetReps)
                let previous = try previousSets(for: exercise.id, before: session)?.filter(\.countsAsWork) ?? []
                for setIndex in 0..<max(0, template.targetSets ?? 0) {
                    let source = setIndex < previous.count ? previous[setIndex] : previous.last
                    insertSet(in: entry, order: setIndex, reps: template.targetReps ?? source?.reps ?? 0, loadKilograms: source?.loadKilograms ?? 0)
                }
            }
        }
        try save()
        return session
    }

    /// Adds an exercise at the end of the session with one set to start from, taken from the last session
    /// that included it. The set is never marked complete automatically.
    @discardableResult func addExercise(_ exercise: Exercise, to session: WorkoutSession) throws -> SessionExercise {
        let order = (session.exercises.map(\.order).max() ?? -1) + 1
        let entry = insertEntry(exercise, order: order, in: session)
        let first = try previousSets(for: exercise.id, before: session)?.first(where: \.countsAsWork)
        insertSet(in: entry, order: 0, reps: first?.reps ?? 0, loadKilograms: first?.loadKilograms ?? 0)
        try save()
        return entry
    }

    func moveExercises(in session: WorkoutSession, from source: IndexSet, to destination: Int) throws {
        var ordered = session.orderedExercises
        let moving = source.sorted().map { ordered[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { ordered.remove(at: index) }
        ordered.insert(contentsOf: moving, at: min(max(0, insertion), ordered.count))
        for (index, entry) in ordered.enumerated() { entry.order = index }
        try save()
    }

    func remove(_ entry: SessionExercise) throws {
        let session = entry.session
        if let session, let restSetID = session.restSetID, entry.sets.contains(where: { $0.id == restSetID }) { clearRest(session) }
        context.delete(entry)
        if let session { for (index, remaining) in session.orderedExercises.filter({ $0.id != entry.id }).enumerated() { remaining.order = index } }
        try save()
    }

    /// Adds a set copying the preceding set's reps and load (or, for a first set, the previous session's),
    /// as a working set that is not complete.
    @discardableResult func addSet(to entry: SessionExercise) throws -> LoggedSet {
        let existing = entry.orderedSets
        var reps = entry.targetReps ?? 0, load = 0.0
        if let last = existing.last {
            reps = last.reps; load = last.loadKilograms
        } else if let session = entry.session, let first = try previousSets(for: entry.exerciseID, before: session)?.first(where: \.countsAsWork) {
            reps = entry.targetReps ?? first.reps; load = first.loadKilograms
        }
        let set = insertSet(in: entry, order: (existing.last?.order ?? -1) + 1, reps: reps, loadKilograms: load)
        try save()
        return set
    }

    func update(_ set: LoggedSet, reps: Int? = nil, loadKilograms: Double? = nil, kind: SetKind? = nil) throws {
        if let reps {
            guard (0...NumberText.maximumReps).contains(reps) else { throw StoreError.invalidValue }
            set.reps = reps
        }
        if let loadKilograms {
            guard loadKilograms.isFinite, (0...NumberText.maximumLoadKilograms).contains(loadKilograms) else { throw StoreError.invalidValue }
            set.loadKilograms = loadKilograms
        }
        if let kind { set.kind = kind }
        try save()
    }

    /// Completing a set starts the rest timer from the completion time. Undoing it stops that timer.
    func setCompleted(_ set: LoggedSet, _ completed: Bool, at date: Date = .now, restTarget: TimeInterval) throws {
        set.completed = completed
        set.completedAt = completed ? date : nil
        if let session = set.sessionExercise?.session, session.isActive {
            if completed {
                session.restStartedAt = date; session.restTarget = restTarget; session.restSetID = set.id
            } else if session.restSetID == set.id {
                clearRest(session)
            }
            session.lastSeenAt = max(session.lastSeenAt, date)
        }
        try save()
    }

    func delete(_ set: LoggedSet) throws {
        let entry = set.sessionExercise
        if let session = entry?.session, session.restSetID == set.id { clearRest(session) }
        context.delete(set)
        if let entry { for (index, remaining) in entry.orderedSets.filter({ $0.id != set.id }).enumerated() { remaining.order = index } }
        try save()
    }

    func extendRest(_ session: WorkoutSession, by seconds: TimeInterval = RestTimer.quickAdd) throws {
        guard let target = session.restTarget else { return }
        session.restTarget = target + seconds
        try save()
    }

    func skipRest(_ session: WorkoutSession) throws {
        clearRest(session)
        try save()
    }

    private func clearRest(_ session: WorkoutSession) {
        session.restStartedAt = nil; session.restTarget = nil; session.restSetID = nil
    }

    /// Inserts a received sample. The caller saves in small batches so a sample every second doesn't
    /// mean a disk write every second; any set change saves pending samples too.
    func insertSample(_ reading: HeartRateReading, into session: WorkoutSession) {
        let sample = HRSample(timestamp: reading.receivedAt, bpm: reading.measurement.bpm,
                              rrIntervals: RRIntervals.encode(reading.measurement.rrIntervals))
        context.insert(sample)
        sample.session = session
    }

    func markSeen(_ session: WorkoutSession, at date: Date = .now) {
        session.lastSeenAt = max(session.lastSeenAt, date)
    }

    /// Saves the finished session locally. Apple Health export is a separate step with its own state.
    func finish(_ session: WorkoutSession, at end: Date) throws {
        // Samples received after the finish time (while the summary was open) aren't part of the workout.
        for sample in session.heartRateSamples where sample.timestamp > end { context.delete(sample) }
        session.endedAt = max(end, session.startedAt)
        session.lastSeenAt = max(session.lastSeenAt, session.endedAt ?? end)
        session.stateRaw = SessionState.completed.rawValue
        session.localSavedAt = .now
        session.healthState = .pending
        clearRest(session)
        summarizeHeartRate(session)
        try save()
    }

    private func summarizeHeartRate(_ session: WorkoutSession) {
        let end = session.endedAt ?? .distantFuture
        let stats = HeartRateStats(session.heartRatePoints.filter { $0.date <= end })
        session.heartRateSampleCount = stats.count
        session.heartRateAverage = stats.average; session.heartRateMinimum = stats.lowest; session.heartRateMaximum = stats.highest
    }

    /// When an interrupted session was last known to be running.
    func lastActivity(of session: WorkoutSession) -> Date {
        SessionRecovery.lastActivity(startedAt: session.startedAt, lastSeenAt: session.lastSeenAt,
                                     setCompletions: session.exercises.flatMap(\.sets).compactMap(\.completedAt),
                                     lastSample: session.heartRateSamples.map(\.timestamp).max())
    }

    /// Deletes a session with its sets and heart-rate samples. A copy already in Apple Health is not touched.
    func delete(_ session: WorkoutSession) throws {
        context.delete(session)
        try save()
    }

    func setHealthState(_ session: WorkoutSession, _ state: HealthExportState, workoutID: UUID? = nil, message: String? = nil) throws {
        session.healthState = state
        if let workoutID { session.healthWorkoutID = workoutID }
        session.healthMessage = message
        session.healthUpdatedAt = .now
        try save()
    }

    /// Launch repair. An export found "saving" was interrupted: it becomes retryable, and a retry checks Apple
    /// Health first. Extra active sessions (never created by this app) are finished at their last activity.
    func recoverAfterLaunch() throws {
        for session in try context.fetch(FetchDescriptor<WorkoutSession>()) where session.healthState == .saving {
            session.healthState = .failed
            session.healthMessage = "the export was interrupted. retry to check Apple Health."
        }
        for extra in try activeSessions().dropFirst() {
            extra.endedAt = lastActivity(of: extra)
            extra.stateRaw = SessionState.completed.rawValue
            extra.localSavedAt = .now
            extra.healthState = .pending
            clearRest(extra)
            summarizeHeartRate(extra)
        }
        try save()
    }

    // MARK: Routines

    @discardableResult func createRoutine(name: String) throws -> Routine {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        let routine = Routine(name: trimmed)
        context.insert(routine)
        try save()
        return routine
    }

    /// Copies the session's exercises into a new routine, with each exercise's working-set count and first
    /// working reps as targets.
    @discardableResult func saveAsRoutine(_ session: WorkoutSession, name: String) throws -> Routine {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        let routine = Routine(name: trimmed)
        context.insert(routine)
        var order = 0
        for entry in session.orderedExercises {
            guard let exercise = entry.exercise else { continue }
            let working = entry.orderedSets.filter { $0.kind == .working }
            let counted = working.filter(\.completed)
            let template = RoutineExercise(order: order, targetSets: (counted.isEmpty ? working : counted).count,
                                           targetReps: (counted.first ?? working.first).flatMap { $0.reps > 0 ? $0.reps : nil })
            context.insert(template)
            template.routine = routine; template.exercise = exercise
            order += 1
        }
        try save()
        return routine
    }

    func rename(_ routine: Routine, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        routine.name = trimmed; routine.updatedAt = .now
        try save()
    }

    func addExercise(_ exercise: Exercise, to routine: Routine) throws {
        let template = RoutineExercise(order: (routine.entries.map(\.order).max() ?? -1) + 1, targetSets: 3)
        context.insert(template)
        template.routine = routine; template.exercise = exercise
        routine.updatedAt = .now
        try save()
    }

    func setTargets(_ template: RoutineExercise, sets: Int?, reps: Int?) throws {
        template.targetSets = sets.map { min(max($0, 1), 20) }
        template.targetReps = reps.map { min(max($0, 1), NumberText.maximumReps) }
        template.routine?.updatedAt = .now
        try save()
    }

    func moveEntries(in routine: Routine, from source: IndexSet, to destination: Int) throws {
        var ordered = routine.orderedEntries
        let moving = source.sorted().map { ordered[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { ordered.remove(at: index) }
        ordered.insert(contentsOf: moving, at: min(max(0, insertion), ordered.count))
        for (index, entry) in ordered.enumerated() { entry.order = index }
        routine.updatedAt = .now
        try save()
    }

    func remove(_ template: RoutineExercise) throws {
        let routine = template.routine
        context.delete(template)
        if let routine {
            for (index, remaining) in routine.orderedEntries.filter({ $0.id != template.id }).enumerated() { remaining.order = index }
            routine.updatedAt = .now
        }
        try save()
    }

    func delete(_ routine: Routine) throws {
        context.delete(routine)
        try save()
    }

    // MARK: Calculations from persisted logs

    /// Finished sessions that started before `session`, newest first.
    private func earlierEntries(for exerciseIDs: [UUID], before session: WorkoutSession) throws -> [SessionExercise] {
        let entries = try context.fetch(FetchDescriptor<SessionExercise>(predicate: #Predicate { exerciseIDs.contains($0.exerciseID) }))
        return entries.filter { entry in
            guard let other = entry.session else { return false }
            return other.id != session.id && other.state == .completed && other.startedAt < session.startedAt
        }
    }

    /// The previous finished session's sets for this exercise, in order, or nil if it was never logged before.
    func previousSets(for exerciseID: UUID, before session: WorkoutSession) throws -> [SetEntry]? {
        let entries = try earlierEntries(for: [exerciseID], before: session)
        guard let latest = entries.compactMap(\.session).max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        return entries.filter { $0.session?.id == latest.id }.sorted { $0.order < $1.order }.flatMap { $0.orderedSets.map(\.entry) }
    }

    /// Bests from finished sessions that started before `session`.
    func priorBests(for exerciseIDs: [UUID], before session: WorkoutSession) throws -> [UUID: ExerciseBests] {
        var bests: [UUID: ExerciseBests] = [:]
        for entry in try earlierEntries(for: exerciseIDs, before: session) {
            bests[entry.exerciseID] = (bests[entry.exerciseID] ?? .none).merged(with: ExerciseBests.of(entry.orderedSets.map(\.entry), isBodyweight: entry.isBodyweight))
        }
        return bests
    }

    func summary(for session: WorkoutSession, endingAt end: Date) throws -> WorkoutSummary {
        let logs = session.exerciseLogs
        return WorkoutSummary.build(startedAt: session.startedAt, endedAt: max(end, session.startedAt), exercises: logs,
                                    priorBests: try priorBests(for: Array(Set(logs.map(\.exerciseID))), before: session),
                                    heartRate: session.heartRatePoints.filter { $0.date <= end })
    }

    /// Finished sessions only, so an in-progress workout never counts as history.
    func history(for exerciseID: UUID) throws -> ExerciseHistory {
        let entries = try context.fetch(FetchDescriptor<SessionExercise>(predicate: #Predicate { $0.exerciseID == exerciseID }))
        let logs: [ExerciseSessionLog] = entries.compactMap { entry in
            guard let session = entry.session, session.state == .completed else { return nil }
            return ExerciseSessionLog(sessionID: session.id, startedAt: session.startedAt, log: entry.log)
        }
        let bodyweight = try exercise(id: exerciseID)?.isBodyweight ?? entries.first?.isBodyweight ?? false
        return ExerciseHistory.build(logs, isBodyweight: bodyweight)
    }

    func healthPayload(for session: WorkoutSession) -> HealthWorkoutPayload {
        HealthWorkoutPayload(sessionID: session.id, activity: session.activity, start: session.startedAt,
                             end: session.endedAt ?? lastActivity(of: session),
                             samples: session.heartRateSamples.map { .init(id: $0.id, date: $0.timestamp, bpm: $0.bpm) },
                             strapName: session.strapName, strapID: session.strapID)
    }

    // MARK: Helpers

    private func insertEntry(_ exercise: Exercise, order: Int, in session: WorkoutSession,
                             targetSets: Int? = nil, targetReps: Int? = nil) -> SessionExercise {
        let entry = SessionExercise(order: order, exerciseID: exercise.id, name: exercise.name, isBodyweight: exercise.isBodyweight,
                                    targetSets: targetSets, targetReps: targetReps)
        context.insert(entry)
        entry.session = session; entry.exercise = exercise
        return entry
    }

    @discardableResult private func insertSet(in entry: SessionExercise, order: Int, reps: Int, loadKilograms: Double) -> LoggedSet {
        let set = LoggedSet(order: order, reps: reps, loadKilograms: loadKilograms)
        context.insert(set)
        set.sessionExercise = entry
        return set
    }

    private static func cleaned(_ category: String?) -> String? {
        guard let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
