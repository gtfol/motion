import Foundation
import SwiftData

extension WorkoutStore {
    func syncSnapshot() throws -> [SyncKey: SyncValue] {
        var result: [SyncKey: SyncValue] = [:]
        for item in try exercises() {
            result[SyncKey(kind: .exercise, id: item.id)] = try .document(ExerciseDocument(
                name: item.name, category: item.category, isBodyweight: item.isBodyweight, createdAt: item.createdAt))
        }
        for item in try context.fetch(FetchDescriptor<Routine>()) {
            result[SyncKey(kind: .routine, id: item.id)] = try .document(RoutineDocument(
                name: item.name, createdAt: item.createdAt, updatedAt: item.updatedAt,
                entries: item.orderedEntries.compactMap { entry in
                    entry.exercise.map { RoutineDocument.Entry(id: entry.id, exerciseID: $0.id, targetSets: entry.targetSets, targetReps: entry.targetReps) }
                }))
        }
        for item in try context.fetch(FetchDescriptor<WorkoutSession>()) where !item.isActive {
            guard let endedAt = item.endedAt else { throw SyncFailure.invalidDocument }
            result[SyncKey(kind: .workout, id: item.id)] = try .document(WorkoutDocument(
                activity: item.activity, startedAt: item.startedAt, endedAt: endedAt, routineID: item.routineID,
                routineName: item.routineName, unit: WeightUnit(rawValue: item.unitRaw) ?? .pounds,
                exercises: item.orderedExercises.map { entry in
                    WorkoutDocument.Entry(id: entry.id, exerciseID: entry.exerciseID, name: entry.nameSnapshot,
                        isBodyweight: entry.bodyweightSnapshot, targetSets: entry.targetSets, targetReps: entry.targetReps,
                        sets: entry.orderedSets.map { WorkoutDocument.Set(id: $0.id, kind: $0.kind, reps: $0.reps,
                            loadKilograms: $0.loadKilograms, completed: $0.completed, completedAt: $0.completedAt, createdAt: $0.createdAt) })
                }, heartRate: item.heartRateSamples.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                    WorkoutDocument.Sample(id: $0.id, timestamp: $0.timestamp, bpm: $0.bpm, rrIntervals: $0.rrIntervals)
                }))
        }
        let settings = try preferences()
        // An uninitialized account must first download its settings, rather than uploading defaults.
        if settings.catalogSeeded {
            result[.preferences] = try .document(PreferencesDocument(unit: settings.unit, defaultRestSeconds: settings.defaultRestSeconds, age: settings.age))
        }
        return result
    }

    /// The caller stages a merge ledger and commits it only after this local transaction succeeds.
    func applyCloud(_ records: [CloudRecord]) throws {
        try records.forEach(SyncDocument.validate)
        applyingCloud = true
        defer { applyingCloud = false }
        do {
            for record in records { try applyCloudRecord(record) }
            try save()
        } catch { context.rollback(); throw error }
    }

    private func applyCloudRecord(_ record: CloudRecord) throws {
        let id = record.id
        switch record.kind {
        case .exercise:
            let old = try exercise(id: id)
            guard let body = record.body else {
                if let old {
                    for entry in old.sessionEntries { entry.nameSnapshot = old.name; entry.bodyweightSnapshot = old.isBodyweight }
                    context.delete(old)
                }
                return
            }
            let data = try body.decode(ExerciseDocument.self)
            let item = old ?? Exercise(id: id, name: data.name)
            if old == nil { context.insert(item) }
            item.name = data.name; item.category = data.category; item.isBodyweight = data.isBodyweight; item.createdAt = data.createdAt
            let entries = try context.fetch(FetchDescriptor<SessionExercise>(predicate: #Predicate { $0.exerciseID == id }))
            for entry in entries { entry.exercise = item }
        case .routine:
            let old = try context.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.id == id })).first
            guard let body = record.body else { if let old { context.delete(old) }; return }
            let data = try body.decode(RoutineDocument.self)
            let item = old ?? Routine(id: id, name: data.name)
            if old == nil { context.insert(item) }
            item.name = data.name; item.createdAt = data.createdAt; item.updatedAt = data.updatedAt
            let wanted = Set(data.entries.map(\.id))
            for entry in item.entries where !wanted.contains(entry.id) { context.delete(entry) }
            for (index, source) in data.entries.enumerated() {
                // A deleted exercise is intentionally omitted, just like a local catalog deletion.
                guard let exercise = try exercise(id: source.exerciseID) else { continue }
                let entry = item.entries.first { $0.id == source.id } ?? RoutineExercise(id: source.id, order: index)
                if entry.modelContext == nil { context.insert(entry) }
                entry.order = index; entry.targetSets = source.targetSets; entry.targetReps = source.targetReps
                entry.routine = item; entry.exercise = exercise
            }
        case .workout:
            let old = try session(id: id)
            guard old?.isActive != true else { throw SyncFailure.staleResponse }
            guard let body = record.body else { if let old { context.delete(old) }; return }
            let data = try body.decode(WorkoutDocument.self)
            let item = old ?? WorkoutSession(id: id, activity: data.activity, startedAt: data.startedAt, unit: data.unit)
            if old == nil { context.insert(item) }
            item.activityRaw = data.activity.rawValue; item.unitRaw = data.unit.rawValue
            item.stateRaw = SessionState.completed.rawValue; item.startedAt = data.startedAt; item.endedAt = data.endedAt
            item.lastSeenAt = data.endedAt; item.localSavedAt = .now; item.routineID = data.routineID; item.routineName = data.routineName
            // Apple Health export state and Bluetooth identifiers belong to this installation.
            let wanted = Set(data.exercises.map(\.id))
            for entry in item.exercises where !wanted.contains(entry.id) { context.delete(entry) }
            for (index, source) in data.exercises.enumerated() {
                let entry = item.exercises.first { $0.id == source.id } ?? SessionExercise(id: source.id, order: index,
                    exerciseID: source.exerciseID, name: source.name, isBodyweight: source.isBodyweight)
                if entry.modelContext == nil { context.insert(entry) }
                entry.order = index; entry.exerciseID = source.exerciseID; entry.nameSnapshot = source.name
                entry.bodyweightSnapshot = source.isBodyweight; entry.targetSets = source.targetSets; entry.targetReps = source.targetReps
                entry.session = item; entry.exercise = try exercise(id: source.exerciseID)
                let wantedSets = Set(source.sets.map(\.id))
                for set in entry.sets where !wantedSets.contains(set.id) { context.delete(set) }
                for (order, sourceSet) in source.sets.enumerated() {
                    let set = entry.sets.first { $0.id == sourceSet.id } ?? LoggedSet(id: sourceSet.id, order: order, reps: sourceSet.reps, loadKilograms: sourceSet.loadKilograms)
                    if set.modelContext == nil { context.insert(set) }
                    set.order = order; set.kind = sourceSet.kind; set.reps = sourceSet.reps; set.loadKilograms = sourceSet.loadKilograms
                    set.completed = sourceSet.completed; set.completedAt = sourceSet.completedAt; set.createdAt = sourceSet.createdAt; set.sessionExercise = entry
                }
            }
            let wantedSamples = Set(data.heartRate.map(\.id))
            for sample in item.heartRateSamples where !wantedSamples.contains(sample.id) { context.delete(sample) }
            let existingSamples = Dictionary(uniqueKeysWithValues: item.heartRateSamples.map { ($0.id, $0) })
            for source in data.heartRate {
                let sample = existingSamples[source.id] ?? HRSample(id: source.id, timestamp: source.timestamp, bpm: source.bpm, rrIntervals: source.rrIntervals)
                if sample.modelContext == nil { context.insert(sample) }
                sample.timestamp = source.timestamp; sample.bpm = source.bpm; sample.rrIntervals = source.rrIntervals; sample.session = item
            }
            let values = data.heartRate.map(\.bpm)
            item.heartRateSampleCount = values.count; item.heartRateMinimum = values.min(); item.heartRateMaximum = values.max()
            item.heartRateAverage = values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        case .preferences:
            guard let body = record.body else { throw SyncFailure.invalidDocument }
            let data = try body.decode(PreferencesDocument.self)
            let item = try preferences()
            item.unit = data.unit; item.defaultRestSeconds = data.defaultRestSeconds; item.age = data.age; item.catalogSeeded = true
        }
    }
}
