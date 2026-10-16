import Foundation
import Observation

struct SyncReply: Codable, Sendable { var applied: Bool; var record: CloudRecord }
@MainActor protocol SyncTransport {
    func pull(after: Int64) async throws -> [CloudRecord]
    func get(_ key: SyncKey) async throws -> CloudRecord?
    func apply(_ mutation: SyncMutation) async throws -> SyncReply
}

@MainActor @Observable final class CloudSync {
    let owner: UUID
    private(set) var ledger: SyncLedger
    private(set) var busy = false
    private(set) var lastSynced: Date?
    private(set) var message: String?
    @ObservationIgnored private let store: WorkoutStore
    @ObservationIgnored private let transport: any SyncTransport
    @ObservationIgnored private let journalURL: URL
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var changed = false
    @ObservationIgnored private var needsPull = false

    init(owner: UUID, store: WorkoutStore, directory: URL, transport: any SyncTransport) throws {
        self.owner = owner; self.store = store; self.transport = transport
        journalURL = directory.appendingPathComponent("motion-sync.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                ledger = try SyncCoding.decoder().decode(SyncLedger.self, from: Data(contentsOf: journalURL))
                try ledger.validate(owner: owner)
            } catch { throw SyncFailure.invalidState }
        } else { ledger = SyncLedger(owner: owner) }
    }

    var conflicts: [SyncKey] { ledger.conflicts.keys.sorted { $0.id.uuidString < $1.id.uuidString } }
    var pendingCount: Int { ledger.pending.count }

    func schedule(immediate: Bool = false) {
        guard !stopped else { return }
        changed = true
        needsPull = needsPull || immediate
        guard !busy else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled, let self else { return }
            let pullIfUnchanged = self.needsPull
            self.needsPull = false
            self.running = Task { await self.syncNow(pullIfUnchanged: pullIfUnchanged) }
        }
    }

    func stop() { stopped = true; scheduled?.cancel(); running?.cancel(); store.onSaved = nil }
    private func check() throws { try Task.checkCancellation(); if stopped { throw SyncFailure.accountChanged } }

    private func persist(_ next: SyncLedger) throws {
        try SyncCoding.encoder().encode(next).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        ledger = next
    }

    /// Public for deterministic transport tests. UI uses schedule so overlapping requests coalesce.
    func syncNow(pullIfUnchanged: Bool = true) async {
        guard !busy, !stopped else { return }
        busy = true; message = nil
        defer { busy = false }
        var firstPass = true
        do {
            repeat {
                changed = false
                try check()
                // Persist request identities before any upload. A timeout can then retry exactly once.
                var next = ledger; next.prepare(local: try store.syncSnapshot()); try persist(next)
                // Live heart-rate batches and Health export state are local-only changes. Do not
                // send a request every time those save; foreground/manual refreshes still pull.
                if firstPass && !pullIfUnchanged && ledger.pending.isEmpty { return }
                firstPass = false
                while true {
                    let page = try await transport.pull(after: ledger.cursor)
                    try check()
                    guard page.count <= 100, zip(page, page.dropFirst()).allSatisfy({ $0.revision < $1.revision }),
                          page.allSatisfy({ $0.revision > ledger.cursor }) else { throw SyncFailure.invalidDocument }
                    for record in page { try await merge(record) }
                    if let last = page.last { var next = ledger; next.cursor = last.revision; try persist(next) }
                    // The server can return a short page to stay within response byte limits.
                    if page.isEmpty { break }
                }
                // Only seed after the first successful restore, to avoid creating defaults on top of cloud data.
                if !ledger.records.isEmpty, try !store.preferences().catalogSeeded {
                    // Even an account containing only tombstones has already had a catalog.
                    // Missing preferences must not resurrect deleted starter exercises.
                    try store.updatePreferences { $0.catalogSeeded = true }
                } else { try store.seedCatalogIfNeeded() }
                next = ledger; next.prepare(local: try store.syncSnapshot()); try persist(next)
                let requests = ledger.pending.values.sorted {
                    let kinds: [SyncKind] = [.exercise, .routine, .workout, .preferences]
                    return kinds.firstIndex(of: $0.key.kind)! < kinds.firstIndex(of: $1.key.kind)!
                }
                for request in requests {
                    try check()
                    guard ledger.pending[request.key]?.mutationID == request.mutationID else { continue }
                    if let body = request.body { try SyncDocument.validate(CloudRecord(kind: request.key.kind, id: request.key.id, revision: 1, body: body)) }
                    let reply = try await transport.apply(request)
                    try check()
                    if reply.applied {
                        var next = ledger
                        try next.acknowledge(request, record: reply.record)
                        next.prepare(local: try store.syncSnapshot()); try persist(next)
                    } else { try await merge(reply.record) }
                }
                next = ledger; next.prepare(local: try store.syncSnapshot()); try persist(next)
                changed = changed || !ledger.pending.isEmpty
                // A change made during an awaited upload is included in another pass.
            } while changed
            lastSynced = .now
        } catch is CancellationError { }
        catch { if !stopped { message = (error as? SyncFailure)?.errorDescription ?? SyncFailure.unavailable.errorDescription } }
    }

    private func merge(_ record: CloudRecord) async throws {
        try SyncDocument.validate(record)
        if record.kind == .routine, let body = record.body {
            let routine = try body.decode(RoutineDocument.self)
            for entry in routine.entries where try store.exercise(id: entry.exerciseID) == nil {
                let key = SyncKey(kind: .exercise, id: entry.exerciseID)
                if ledger.records[key] == nil, ledger.conflicts[key] == nil {
                    guard let exercise = try await transport.get(key) else { throw SyncFailure.invalidDocument }
                    try check()
                    guard exercise.key == key else { throw SyncFailure.invalidDocument }
                    try await merge(exercise)
                }
            }
        }
        try check()
        var next = ledger
        let result = try next.receive(record, local: store.syncSnapshot())
        if case .apply(let record) = result { try store.applyCloud([record]) }
        try persist(next)
    }

    func resolve(_ key: SyncKey, keepLocal: Bool) {
        guard !busy, !stopped else { return }
        do {
            var next = ledger
            if let record = next.resolve(key, keepLocal: keepLocal, local: try store.syncSnapshot()) { try store.applyCloud([record]) }
            try persist(next); schedule(immediate: true)
        } catch { message = error.localizedDescription }
    }

    func conflictSummary(_ key: SyncKey, cloud: Bool) -> String {
        let conflict = ledger.conflicts[key]
        let body = cloud ? conflict?.remote.body : conflict?.local
        guard let body else { return "deleted" }
        switch key.kind {
        case .exercise: return (try? body.decode(ExerciseDocument.self).name) ?? "exercise"
        case .routine: return (try? body.decode(RoutineDocument.self).name) ?? "routine"
        case .preferences: return "units, rest time and age"
        case .workout:
            guard let workout = try? body.decode(WorkoutDocument.self) else { return "workout" }
            return "\(workout.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(workout.exercises.flatMap(\.sets).count) sets"
        }
    }

    func conflictDetails(_ key: SyncKey, cloud: Bool) -> [String] {
        let conflict = ledger.conflicts[key]
        guard let body = cloud ? conflict?.remote.body : conflict?.local else { return ["deleted"] }
        switch key.kind {
        case .exercise:
            guard let item = try? body.decode(ExerciseDocument.self) else { return [] }
            return [item.name, item.category ?? "no category", item.isBodyweight ? "bodyweight movement" : "weighted movement"]
        case .preferences:
            guard let item = try? body.decode(PreferencesDocument.self) else { return [] }
            return [item.unit.rawValue, "rest: \(item.defaultRestSeconds) seconds", "age: \(item.age.map(String.init) ?? "not set")"]
        case .routine:
            guard let item = try? body.decode(RoutineDocument.self) else { return [] }
            return [item.name] + item.entries.map {
                let name = (try? store.exercise(id: $0.exerciseID)?.name) ?? "removed exercise"
                return "\(name): \($0.targetSets.map(String.init) ?? "—") sets × \($0.targetReps.map(String.init) ?? "—") reps"
            }
        case .workout:
            guard let item = try? body.decode(WorkoutDocument.self) else { return [] }
            return ["\(item.activity.rawValue) · \(item.startedAt.formatted()) – \(item.endedAt.formatted(date: .omitted, time: .shortened))",
                    "\(item.heartRate.count) heart-rate samples"] + item.exercises.flatMap { entry in
                [entry.name] + entry.sets.map { set in
                    "\(set.kind.rawValue): \(set.reps) reps × \(LoadText.load(set.loadKilograms, unit: item.unit, isBodyweight: entry.isBodyweight)) · \(set.completed ? "done" : "not done")"
                }
            }
        }
    }
}
