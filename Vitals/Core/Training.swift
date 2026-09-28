import Foundation

enum SetKind: String, CaseIterable, Codable, Sendable {
    case working, warmup

    var label: String { self == .working ? "working" : "warm-up" }
}

/// A plain copy of a logged set, so calculations can run without SwiftData.
struct SetEntry: Sendable, Equatable, Identifiable {
    var id: UUID
    var kind: SetKind
    var reps: Int
    var loadKilograms: Double
    var completed: Bool
    var completedAt: Date?

    init(id: UUID = UUID(), kind: SetKind = .working, reps: Int, loadKilograms: Double, completed: Bool = false, completedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.reps = reps; self.loadKilograms = loadKilograms
        self.completed = completed; self.completedAt = completedAt
    }

    /// Completed working sets count toward volume, set totals, and records. Warm-ups never do.
    var countsAsWork: Bool { completed && kind == .working }
}

/// One exercise's sets within one session, in order.
struct ExerciseLog: Sendable, Equatable {
    var exerciseID: UUID
    var name: String
    var isBodyweight: Bool
    var sets: [SetEntry]
}

enum TrainingMath {
    /// Loads closer than this (in kilograms) are treated as equal, so unit round trips never create records.
    static let tolerance = 0.000_1
    static let estimatedOneRepMaxReps = 1...10

    /// Reps × external load over completed working sets, in kilograms. Bodyweight contributes nothing.
    static func volumeKilograms<S: Sequence>(_ sets: S) -> Double where S.Element == SetEntry {
        sets.reduce(0) { $1.countsAsWork ? $0 + Double($1.reps) * $1.loadKilograms : $0 }
    }

    /// Epley estimate, load × (1 + reps / 30), for 1–10 reps with external load. A single is its own estimate.
    /// This is an estimate, not a measured maximum.
    static func estimatedOneRepMax(reps: Int, loadKilograms: Double) -> Double? {
        guard estimatedOneRepMaxReps.contains(reps), loadKilograms > 0 else { return nil }
        return reps == 1 ? loadKilograms : loadKilograms * (1 + Double(reps) / 30)
    }

    /// Sets eligible for weighted comparisons: completed working sets with reps and external load,
    /// on exercises not marked bodyweight (their added-load semantics aren't designed yet).
    static func isComparable(_ set: SetEntry, bodyweightExercise: Bool) -> Bool {
        !bodyweightExercise && set.countsAsWork && set.reps > 0 && set.loadKilograms > 0
    }
}

enum RecordKind: String, Codable, Sendable {
    case heaviestLoad, estimatedOneRepMax

    var label: String { self == .heaviestLoad ? "heaviest" : "est. 1RM" }
}

struct ExerciseBests: Sendable, Equatable {
    var heaviestLoad: Double?
    var heaviestLoadSetID: UUID?
    var estimatedOneRepMax: Double?
    var estimatedOneRepMaxSetID: UUID?

    static let none = ExerciseBests()

    var isEmpty: Bool { heaviestLoad == nil && estimatedOneRepMax == nil }

    static func of<S: Sequence>(_ sets: S, isBodyweight: Bool) -> ExerciseBests where S.Element == SetEntry {
        var bests = ExerciseBests()
        for set in sets where TrainingMath.isComparable(set, bodyweightExercise: isBodyweight) {
            if bests.heaviestLoad.map({ set.loadKilograms > $0 + TrainingMath.tolerance }) ?? true {
                bests.heaviestLoad = set.loadKilograms; bests.heaviestLoadSetID = set.id
            }
            if let estimate = TrainingMath.estimatedOneRepMax(reps: set.reps, loadKilograms: set.loadKilograms),
               bests.estimatedOneRepMax.map({ estimate > $0 + TrainingMath.tolerance }) ?? true {
                bests.estimatedOneRepMax = estimate; bests.estimatedOneRepMaxSetID = set.id
            }
        }
        return bests
    }

    /// Keeps the larger value of each best; an equal later value does not replace an earlier one.
    func merged(with later: ExerciseBests) -> ExerciseBests {
        var result = self
        if let load = later.heaviestLoad, heaviestLoad.map({ load > $0 + TrainingMath.tolerance }) ?? true {
            result.heaviestLoad = load; result.heaviestLoadSetID = later.heaviestLoadSetID
        }
        if let estimate = later.estimatedOneRepMax, estimatedOneRepMax.map({ estimate > $0 + TrainingMath.tolerance }) ?? true {
            result.estimatedOneRepMax = estimate; result.estimatedOneRepMaxSetID = later.estimatedOneRepMaxSetID
        }
        return result
    }
}

/// A new best in one session compared with earlier sessions only.
struct RecordHit: Sendable, Equatable, Identifiable {
    var kind: RecordKind
    var setID: UUID
    var previous: Double
    var value: Double

    var id: String { "\(kind.rawValue)-\(setID.uuidString)" }
}

enum PersonalRecords {
    /// Records need earlier comparable history: a first weighted session sets a baseline, not a record.
    /// Ties are not records. Only the session's best set for each kind is marked.
    static func hits<S: Sequence>(in sets: S, isBodyweight: Bool, prior: ExerciseBests) -> [RecordHit] where S.Element == SetEntry {
        guard !isBodyweight else { return [] }
        let session = ExerciseBests.of(sets, isBodyweight: false)
        var hits: [RecordHit] = []
        if let previous = prior.heaviestLoad, let value = session.heaviestLoad, let id = session.heaviestLoadSetID,
           value > previous + TrainingMath.tolerance {
            hits.append(RecordHit(kind: .heaviestLoad, setID: id, previous: previous, value: value))
        }
        if let previous = prior.estimatedOneRepMax, let value = session.estimatedOneRepMax, let id = session.estimatedOneRepMaxSetID,
           value > previous + TrainingMath.tolerance {
            hits.append(RecordHit(kind: .estimatedOneRepMax, setID: id, previous: previous, value: value))
        }
        return hits
    }
}

/// One exercise as it appeared in one session (an exercise added twice appears as two logs).
struct ExerciseSessionLog: Sendable, Equatable {
    var sessionID: UUID
    var startedAt: Date
    var log: ExerciseLog
}

struct ExerciseHistoryRow: Sendable, Equatable, Identifiable {
    var sessionID: UUID
    var startedAt: Date
    var sets: [SetEntry]
    var bests: ExerciseBests
    var hits: [RecordHit]

    var id: UUID { sessionID }
}

/// Past sets and bests for one exercise, with records evaluated in chronological order.
struct ExerciseHistory: Sendable, Equatable {
    var rows: [ExerciseHistoryRow]
    var allTime: ExerciseBests
    var mostBodyweightReps: Int?

    static func build(_ logs: [ExerciseSessionLog], isBodyweight: Bool) -> ExerciseHistory {
        var order: [UUID] = [], grouped: [UUID: (Date, [SetEntry])] = [:]
        for entry in logs {
            if grouped[entry.sessionID] == nil { order.append(entry.sessionID); grouped[entry.sessionID] = (entry.startedAt, []) }
            grouped[entry.sessionID]?.1.append(contentsOf: entry.log.sets)
        }
        let chronological = order.sorted { (grouped[$0]!.0, $0.uuidString) < (grouped[$1]!.0, $1.uuidString) }
        var prior = ExerciseBests.none, rows: [ExerciseHistoryRow] = [], mostReps: Int?
        for id in chronological {
            let (startedAt, sets) = grouped[id]!
            let bests = ExerciseBests.of(sets, isBodyweight: isBodyweight)
            rows.append(ExerciseHistoryRow(sessionID: id, startedAt: startedAt, sets: sets, bests: bests,
                                           hits: PersonalRecords.hits(in: sets, isBodyweight: isBodyweight, prior: prior)))
            prior = prior.merged(with: bests)
            for set in sets where set.countsAsWork && set.loadKilograms <= 0 { mostReps = max(mostReps ?? 0, set.reps) }
        }
        return ExerciseHistory(rows: rows.reversed(), allTime: prior, mostBodyweightReps: mostReps)
    }
}

enum PreviousPerformance {
    /// Pairs each current set with the previous session's completed set at the same position among sets of its kind.
    static func matches(current: [SetEntry], previous: [SetEntry]) -> [UUID: SetEntry] {
        var result: [UUID: SetEntry] = [:]
        for kind in SetKind.allCases {
            let earlier = previous.filter { $0.completed && $0.kind == kind }
            for (index, set) in current.filter({ $0.kind == kind }).enumerated() where index < earlier.count {
                result[set.id] = earlier[index]
            }
        }
        return result
    }

    /// "135 × 5 · 135 × 5 · 145 × 3" for the previous session's completed working sets.
    static func summary(_ previous: [SetEntry], unit: WeightUnit, isBodyweight: Bool, locale: Locale = .current) -> String? {
        let working = previous.filter(\.countsAsWork)
        guard !working.isEmpty else { return nil }
        return working.map { LoadText.set(reps: $0.reps, kilograms: $0.loadKilograms, unit: unit, isBodyweight: isBodyweight, locale: locale) }
            .joined(separator: " · ")
    }
}

struct ExerciseRecords: Sendable, Equatable, Identifiable {
    var exerciseID: UUID
    var name: String
    var hits: [RecordHit]

    var id: UUID { exerciseID }
}

struct WorkoutSummary: Sendable, Equatable {
    var startedAt: Date
    var endedAt: Date
    var exerciseCount: Int
    var completedWorkingSets: Int
    var completedWarmupSets: Int
    var incompleteSets: Int
    var volumeKilograms: Double
    var records: [ExerciseRecords]
    var heartRate: HeartRateSummary?

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var hasCompletedSets: Bool { completedWorkingSets + completedWarmupSets > 0 }

    /// `priorBests` must come from sessions that started before this one.
    static func build(startedAt: Date, endedAt: Date, exercises: [ExerciseLog], priorBests: [UUID: ExerciseBests],
                      heartRate: [HeartRatePoint]) -> WorkoutSummary {
        var order: [UUID] = [], combined: [UUID: ExerciseLog] = [:]
        for log in exercises {
            if var existing = combined[log.exerciseID] { existing.sets += log.sets; combined[log.exerciseID] = existing }
            else { order.append(log.exerciseID); combined[log.exerciseID] = log }
        }
        let allSets = exercises.flatMap(\.sets)
        let records: [ExerciseRecords] = order.compactMap { id in
            guard let log = combined[id] else { return nil }
            let hits = PersonalRecords.hits(in: log.sets, isBodyweight: log.isBodyweight, prior: priorBests[id] ?? .none)
            return hits.isEmpty ? nil : ExerciseRecords(exerciseID: id, name: log.name, hits: hits)
        }
        return WorkoutSummary(
            startedAt: startedAt, endedAt: endedAt,
            exerciseCount: order.filter { id in combined[id]?.sets.contains(where: \.completed) == true }.count,
            completedWorkingSets: allSets.filter(\.countsAsWork).count,
            completedWarmupSets: allSets.filter { $0.completed && $0.kind == .warmup }.count,
            incompleteSets: allSets.filter { !$0.completed }.count,
            volumeKilograms: TrainingMath.volumeKilograms(allSets),
            records: records,
            heartRate: HeartRateSummary(heartRate))
    }
}
