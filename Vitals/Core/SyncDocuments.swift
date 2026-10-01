import Foundation

struct ExerciseDocument: Codable, Equatable, Sendable {
    var version = 1
    var name: String
    var category: String?
    var isBodyweight: Bool
    var createdAt: Date
}
struct RoutineDocument: Codable, Equatable, Sendable {
    var version = 1
    struct Entry: Codable, Equatable, Sendable {
        var id: UUID
        var exerciseID: UUID
        var targetSets: Int?
        var targetReps: Int?
    }
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var entries: [Entry]
}
struct WorkoutDocument: Codable, Equatable, Sendable {
    var version = 1
    struct Entry: Codable, Equatable, Sendable {
        var id: UUID
        var exerciseID: UUID
        var name: String
        var isBodyweight: Bool
        var targetSets: Int?
        var targetReps: Int?
        var sets: [Set]
    }
    struct Set: Codable, Equatable, Sendable {
        var id: UUID
        var kind: SetKind
        var reps: Int
        var loadKilograms: Double
        var completed: Bool
        var completedAt: Date?
        var createdAt: Date
    }
    struct Sample: Codable, Equatable, Sendable {
        var id: UUID
        var timestamp: Date
        var bpm: Int
        var rrIntervals: Data?
    }
    var activity: ActivityKind
    var startedAt: Date
    var endedAt: Date
    var routineID: UUID?
    var routineName: String?
    var unit: WeightUnit
    var exercises: [Entry]
    var heartRate: [Sample]
}
struct PreferencesDocument: Codable, Equatable, Sendable {
    var version = 1
    var unit: WeightUnit
    var defaultRestSeconds: Int
    var age: Int?
}

/// Validate before touching a model context. IDs are also unique across a workout's children.
enum SyncDocument {
    static func validate(_ record: CloudRecord) throws {
        guard let body = record.body else { return }
        func name(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 1000 }
        func target(_ value: Int?) -> Bool { value.map { (0...10000).contains($0) } ?? true }
        var valid = false
        switch record.kind {
        case .exercise:
            let value = try body.decode(ExerciseDocument.self)
            valid = value.version == 1 && name(value.name) && (value.category?.count ?? 0) <= 1000
        case .routine:
            let value = try body.decode(RoutineDocument.self)
            valid = value.version == 1 && name(value.name) && value.entries.count <= 1000 && Set(value.entries.map(\.id)).count == value.entries.count
                && value.entries.allSatisfy { target($0.targetSets) && target($0.targetReps) }
        case .workout:
            let value = try body.decode(WorkoutDocument.self)
            let ids = value.exercises.map(\.id) + value.exercises.flatMap { $0.sets.map(\.id) } + value.heartRate.map(\.id)
            valid = value.version == 1 && value.endedAt >= value.startedAt && value.exercises.count <= 1000 && value.heartRate.count <= 100000
                && Set(ids).count == ids.count && value.exercises.allSatisfy {
                    name($0.name) && target($0.targetSets) && target($0.targetReps) && $0.sets.count <= 5000
                    && $0.sets.allSatisfy { (0...10000).contains($0.reps) && $0.loadKilograms.isFinite && (0...100000).contains($0.loadKilograms) }
                } && value.heartRate.allSatisfy { (0...65535).contains($0.bpm) && ($0.rrIntervals?.count ?? 0) <= 512 }
        case .preferences:
            let value = try body.decode(PreferencesDocument.self)
            valid = value.version == 1 && record.key == .preferences && RestTimer.targetRange.contains(value.defaultRestSeconds)
                && (value.age.map { HeartRateZone.ages.contains($0) } ?? true)
        }
        guard valid else { throw SyncFailure.invalidDocument }
    }
}
