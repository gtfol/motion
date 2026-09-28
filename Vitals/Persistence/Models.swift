import Foundation
import SwiftData

// One local store owns the catalog, routines, the active session, and history.
// Apple Health only receives a copy of finished workouts; it never owns sets.
//
// Delete rules, deliberately:
// - WorkoutSession → SessionExercise → LoggedSet: cascade. Deleting a session removes its log.
// - WorkoutSession → HRSample: cascade.
// - Routine → RoutineExercise: cascade.
// - Exercise → RoutineExercise: cascade. A deleted exercise leaves routines.
// - Exercise → SessionExercise: nullify. Past sessions keep a name snapshot and the exercise ID.
// Routines and sessions are never linked, so editing a session can't rewrite a routine.

@Model final class Exercise {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    /// Optional free-form muscle or category label. Never required.
    var category: String?
    /// Load for this movement is added to bodyweight. Excluded from weighted records until those semantics are designed.
    var isBodyweight: Bool = false
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .nullify, inverse: \SessionExercise.exercise) var sessionEntries: [SessionExercise] = []
    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.exercise) var routineEntries: [RoutineExercise] = []

    init(id: UUID = UUID(), name: String, category: String? = nil, isBodyweight: Bool = false, createdAt: Date = .now) {
        self.id = id; self.name = name; self.category = category; self.isBodyweight = isBodyweight; self.createdAt = createdAt
    }
}

@Model final class Routine {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.routine) var entries: [RoutineExercise] = []

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = createdAt
    }

    var orderedEntries: [RoutineExercise] { entries.sorted { $0.order < $1.order } }
}

@Model final class RoutineExercise {
    @Attribute(.unique) var id: UUID = UUID()
    var order: Int = 0
    var targetSets: Int?
    var targetReps: Int?
    var routine: Routine?
    var exercise: Exercise?

    /// Link `routine` and `exercise` after inserting the entry into a context.
    init(id: UUID = UUID(), order: Int, targetSets: Int? = nil, targetReps: Int? = nil) {
        self.id = id; self.order = order; self.targetSets = targetSets; self.targetReps = targetReps
    }
}

@Model final class WorkoutSession {
    @Attribute(.unique) var id: UUID = UUID()
    var activityRaw: String = ActivityKind.strength.rawValue
    var stateRaw: String = SessionState.active.rawValue
    var startedAt: Date = Date.now
    var endedAt: Date?
    /// The last time the app was known to be running this session, for finishing an interrupted one honestly.
    var lastSeenAt: Date = Date.now
    /// The routine this session was copied from. A reference only: the session never writes back to it.
    var routineID: UUID?
    var routineName: String?
    /// The display unit when the session started. Loads are stored in kilograms regardless.
    var unitRaw: String = WeightUnit.pounds.rawValue
    /// The strap selected when the session started, if any.
    var strapID: UUID?
    var strapName: String?
    var restStartedAt: Date?
    var restTarget: Double?
    var restSetID: UUID?
    var localSavedAt: Date?
    var healthStateRaw: String = HealthExportState.pending.rawValue
    var healthWorkoutID: UUID?
    var healthMessage: String?
    var healthUpdatedAt: Date?
    /// Heart-rate summary from received samples, written when the session finishes so lists don't load every sample.
    var heartRateSampleCount: Int = 0
    var heartRateAverage: Int?
    var heartRateMinimum: Int?
    var heartRateMaximum: Int?
    @Relationship(deleteRule: .cascade, inverse: \SessionExercise.session) var exercises: [SessionExercise] = []
    @Relationship(deleteRule: .cascade, inverse: \HRSample.session) var heartRateSamples: [HRSample] = []

    init(id: UUID = UUID(), activity: ActivityKind, startedAt: Date, unit: WeightUnit) {
        self.id = id; self.activityRaw = activity.rawValue; self.startedAt = startedAt; self.lastSeenAt = startedAt
        self.unitRaw = unit.rawValue
    }

    var activity: ActivityKind { ActivityKind(rawValue: activityRaw) ?? .other }
    var state: SessionState { SessionState(rawValue: stateRaw) ?? .completed }
    var isActive: Bool { state == .active }
    var healthState: HealthExportState {
        get { HealthExportState(rawValue: healthStateRaw) ?? .pending }
        set { healthStateRaw = newValue.rawValue }
    }
    var orderedExercises: [SessionExercise] { exercises.sorted { $0.order < $1.order } }
    var restTimer: RestTimer? {
        guard let restStartedAt, let restTarget else { return nil }
        return RestTimer(startedAt: restStartedAt, target: restTarget)
    }
    var heartRatePoints: [HeartRatePoint] {
        heartRateSamples.map { HeartRatePoint(date: $0.timestamp, bpm: $0.bpm) }.sorted { $0.date < $1.date }
    }
    var exerciseLogs: [ExerciseLog] { orderedExercises.map(\.log) }
}

@Model final class SessionExercise {
    @Attribute(.unique) var id: UUID = UUID()
    var order: Int = 0
    /// Stable grouping key for exercise history, kept even if the catalog entry is deleted.
    var exerciseID: UUID = UUID()
    /// Name and bodyweight flag at the time it was logged; used if the catalog entry is deleted.
    var nameSnapshot: String = ""
    var bodyweightSnapshot: Bool = false
    var targetSets: Int?
    var targetReps: Int?
    var session: WorkoutSession?
    var exercise: Exercise?
    @Relationship(deleteRule: .cascade, inverse: \LoggedSet.sessionExercise) var sets: [LoggedSet] = []

    /// Link `session` and `exercise` after inserting the entry into a context.
    init(id: UUID = UUID(), order: Int, exerciseID: UUID, name: String, isBodyweight: Bool, targetSets: Int? = nil, targetReps: Int? = nil) {
        self.id = id; self.order = order; self.exerciseID = exerciseID
        self.nameSnapshot = name; self.bodyweightSnapshot = isBodyweight
        self.targetSets = targetSets; self.targetReps = targetReps
    }

    var name: String { exercise?.name ?? nameSnapshot }
    var isBodyweight: Bool { exercise?.isBodyweight ?? bodyweightSnapshot }
    var orderedSets: [LoggedSet] { sets.sorted { $0.order < $1.order } }
    var log: ExerciseLog { ExerciseLog(exerciseID: exerciseID, name: name, isBodyweight: isBodyweight, sets: orderedSets.map(\.entry)) }
}

@Model final class LoggedSet {
    @Attribute(.unique) var id: UUID = UUID()
    var order: Int = 0
    var kindRaw: String = SetKind.working.rawValue
    var reps: Int = 0
    /// External load in kilograms. Zero is bodyweight, not zero effort.
    var loadKilograms: Double = 0
    var completed: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date.now
    var sessionExercise: SessionExercise?

    init(id: UUID = UUID(), order: Int, kind: SetKind = .working, reps: Int, loadKilograms: Double, createdAt: Date = .now) {
        self.id = id; self.order = order; self.kindRaw = kind.rawValue; self.reps = reps
        self.loadKilograms = loadKilograms; self.createdAt = createdAt
    }

    var kind: SetKind {
        get { SetKind(rawValue: kindRaw) ?? .working }
        set { kindRaw = newValue.rawValue }
    }
    var entry: SetEntry {
        SetEntry(id: id, kind: kind, reps: reps, loadKilograms: loadKilograms, completed: completed, completedAt: completedAt)
    }
}

/// A heart-rate sample as received from the strap. Missing periods are never filled in.
@Model final class HRSample {
    @Attribute(.unique) var id: UUID = UUID()
    var timestamp: Date = Date.now
    var bpm: Int = 0
    /// Raw RR intervals: little-endian UInt16 values in 1/1024-second units. Stored, not analyzed.
    var rrIntervals: Data?
    var session: WorkoutSession?

    init(id: UUID = UUID(), timestamp: Date, bpm: Int, rrIntervals: Data?) {
        self.id = id; self.timestamp = timestamp; self.bpm = bpm; self.rrIntervals = rrIntervals
    }
}

/// App settings, kept in the same local store as everything else.
@Model final class AppPreferences {
    @Attribute(.unique) var key: String = AppPreferences.singletonKey
    var unitRaw: String = WeightUnit.pounds.rawValue
    var defaultRestSeconds: Int = RestTimer.defaultTarget
    /// Optional, only for an approximate heart-rate zone tint.
    var age: Int?
    /// The chosen strap's CoreBluetooth identifier. vitals only connects to this device.
    var strapID: UUID?
    var strapName: String?
    var catalogSeeded: Bool = false

    static let singletonKey = "preferences"

    init() {}

    var unit: WeightUnit {
        get { WeightUnit(rawValue: unitRaw) ?? .pounds }
        set { unitRaw = newValue.rawValue }
    }
}

enum VitalsSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Exercise.self, Routine.self, RoutineExercise.self, WorkoutSession.self, SessionExercise.self,
         LoggedSet.self, HRSample.self, AppPreferences.self]
    }
}

enum VitalsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [VitalsSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum VitalsContainer {
    static func make(directory: URL) throws -> ModelContainer {
        // Create the directory before Core Data opens its SQLite files on first launch.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("vitals.store"), cloudKitDatabase: .none)
        return try ModelContainer(for: Schema(versionedSchema: VitalsSchemaV1.self), migrationPlan: VitalsMigrationPlan.self,
                                  configurations: configuration)
    }

    static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: VitalsSchemaV1.self),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
}
