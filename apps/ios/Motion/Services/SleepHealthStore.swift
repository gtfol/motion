import Foundation
import HealthKit
import Observation

/// Request status says whether iOS will show a prompt; it never exposes read permission decisions.
@MainActor struct SleepHealthAuthorization {
    var available: () -> Bool
    var status: () async throws -> HKAuthorizationRequestStatus
    var request: () async throws -> Void

    static func live(_ store: HKHealthStore) -> Self {
        let read: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis), HKQuantityType(.heartRate), HKQuantityType(.respiratoryRate)]
        return Self(available: { HKHealthStore.isHealthDataAvailable() },
                    status: { try await store.statusForAuthorizationRequest(toShare: [], read: read) },
                    request: { try await store.requestAuthorization(toShare: [], read: read) })
    }
}

/// Read-only, on-device HealthKit data. Nothing here enters the workout database or cloud sync.
@MainActor @Observable final class SleepHealthStore {
    enum ConnectionResult: Equatable {
        case requested, manageAccess, unavailable, failed
    }
    struct LoadResult: Sendable {
        var records: [SleepMeasurements] = []
        var message: String?
    }
    private(set) var records: [SleepMeasurements] = []
    private(set) var loading = false
    private(set) var loadedDay: Date?
    private(set) var revision = 0
    private(set) var message: String?
    var available: Bool { authorization.available() }
    @ObservationIgnored private let store: HKHealthStore
    @ObservationIgnored private let authorization: SleepHealthAuthorization
    @ObservationIgnored private let reader: (@MainActor (Date) async -> LoadResult)?
    @ObservationIgnored private var generation = UUID()
    #if DEBUG
    @ObservationIgnored private var testReadContinuations: [CheckedContinuation<Void, Never>] = []
    var usesControlledTestRead: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-ui-testing") && args.contains("-ui-testing-sleep-loading")
    }
    func finishTestRead() {
        let pending = testReadContinuations
        testReadContinuations = []
        pending.forEach { $0.resume() }
    }
    #endif

    init(authorization: SleepHealthAuthorization? = nil, reader: (@MainActor (Date) async -> LoadResult)? = nil) {
        let store = HKHealthStore()
        self.store = store
        self.reader = reader
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if authorization == nil, args.contains("-ui-testing"), args.contains("-ui-testing-sleep-access") {
            var requested = false
            self.authorization = SleepHealthAuthorization(available: { true },
                status: { requested ? .unnecessary : .shouldRequest }, request: { requested = true })
            return
        }
        #endif
        self.authorization = authorization ?? .live(store)
    }

    var usesTestMeasurements: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-ui-testing") && args.contains("-ui-testing-sleep")
        #else
        false
        #endif
    }

    func connect() async -> ConnectionResult {
        guard available else { return .unavailable }
        do {
            if try await authorization.status() == .unnecessary { return .manageAccess }
            try await authorization.request()
            // Completion does NOT indicate read permission. HealthKit deliberately hides denials.
            return .requested
        } catch {
            return .failed
        }
    }

    func load(endingOn date: Date) async {
        let request = UUID()
        generation = request
        loading = true
        message = nil
        // Retain the last complete result during a refresh. An empty completed read still
        // replaces it, including when Health access has been revoked.
        defer { if generation == request { loading = false } }
        let result: LoadResult?
        if let reader { result = await reader(date) }
        else { result = await readMeasurements(endingOn: date, request: request) }
        guard generation == request, !Task.isCancelled, let result else { return }
        message = result.message
        // A failed query is not a successful empty read. Keep the complete cached
        // page for this date if Health is temporarily unavailable (for example, locked).
        if result.message != nil, loadedDay == Calendar.current.startOfDay(for: date) { return }
        records = result.records
        loadedDay = Calendar.current.startOfDay(for: date)
        revision += 1
    }

    private func readMeasurements(endingOn date: Date, request: UUID) async -> LoadResult? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if usesTestMeasurements || (args.contains("-ui-testing") && args.contains("-ui-testing-sleep-access")) {
            if usesControlledTestRead { await withCheckedContinuation { testReadContinuations.append($0) } }
            return LoadResult(records: testMeasurements(endingOn: date))
        }
        #endif
        guard available else { return LoadResult(message: "Apple Health isn’t available on this device.") }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -8, to: day)!
        let end = min(calendar.date(byAdding: .day, value: 1, to: day)!, .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        var bySource: [String: SleepMeasurements] = [:]
        var failures: [String] = []
        do {
            let query = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)])
            let samples = try await query.result(for: store)
            guard generation == request else { return nil }
            let usable = samples.filter { Self.stage($0.value) != nil && $0.endDate <= end }
            for (id, values) in Dictionary(grouping: usable, by: { $0.sourceRevision.source.bundleIdentifier }) {
                bySource[id, default: SleepMeasurements()].sessions = SleepSummary.sessions(values.compactMap { sample in
                    Self.stage(sample.value).map { SleepSegment(start: sample.startDate, end: sample.endDate, stage: $0) }
                }).filter { $0.day <= day }
            }
        } catch { failures.append("sleep") }
        // Query each metric even if Health has no sleep record: it may fill a Helio night's missing metric.
        for (type, key, label) in [
            (HKQuantityTypeIdentifier.heartRate, \SleepMeasurements.heartRate, "heart rate"),
            (.respiratoryRate, \SleepMeasurements.respiratoryRate, "breathing rate")
        ] {
            guard generation == request else { return nil }
            do {
                let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(type), predicate: predicate)],
                                                    sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)])
                let samples = try await query.result(for: store)
                guard generation == request else { return nil }
                for (id, values) in Dictionary(grouping: samples, by: { $0.sourceRevision.source.bundleIdentifier }) {
                    bySource[id, default: SleepMeasurements()][keyPath: key] = values.map {
                        SleepReading(id: $0.uuid, date: $0.startDate,
                                     value: $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())))
                    }
                }
            } catch { failures.append(label) }
        }
        guard generation == request else { return nil }
        var result = LoadResult(records: bySource.keys.sorted().compactMap { bySource[$0] })
        if !failures.isEmpty {
            result.message = "couldn’t read \(failures.joined(separator: ", ")) from Apple Health. unlock your iPhone and pull down to retry."
        }
        return result
    }

    private static func stage(_ value: Int) -> SleepStage? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .awake: .awake
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .asleepUnspecified: .asleep
        default: nil // In-bed time is not measured sleep.
        }
    }

    #if DEBUG
    private func testMeasurements(endingOn date: Date) -> [SleepMeasurements] {
        var measurements = SleepMeasurements()
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-sleep-empty") { return [] }
        let calendar = Calendar.current
        for offset in -6...0 where offset != -3 {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date))!
            let start = day.addingTimeInterval(-3_600)
            let pattern: [(Double, Double, SleepStage)] = [
                (0, 0.6, .core), (0.6, 1.5, .deep), (1.5, 2.2, .core), (2.2, 2.7, .rem),
                (2.7, 3, .awake), (3, 4, .core), (4, 4.7, .deep), (4.7, 5.4, .core),
                (5.4, 6, .rem), (6, 7, .core), (7, 8, .rem)
            ]
            let segments = pattern.map { SleepSegment(start: start.addingTimeInterval($0.0 * 3_600), end: start.addingTimeInterval($0.1 * 3_600), stage: $0.2) }
            measurements.sessions.append(SleepNight(day: day, segments: segments))
            for minute in stride(from: 0, to: 480, by: 5) {
                let at = start.addingTimeInterval(Double(minute) * 60)
                measurements.heartRate.append(SleepReading(date: at, value: 55 + sin(Double(minute) / 24) * 6))
                if offset != -1 { measurements.respiratoryRate.append(SleepReading(date: at, value: 13 + sin(Double(minute) / 34))) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-naps") {
            let day = calendar.startOfDay(for: date)
            func part(_ start: Int, _ end: Int, _ stage: SleepStage) -> SleepSegment {
                SleepSegment(start: day.addingTimeInterval(Double(start * 60)),
                             end: day.addingTimeInterval(Double(end * 60)), stage: stage)
            }
            measurements.sessions.removeAll { $0.day == day }
            measurements.sessions += SleepSummary.sessions([
                part(174, 230, .deep), part(230, 231, .awake), part(231, 272, .core),
                part(772, 850, .core), part(850, 851, .awake), part(851, 903, .rem)
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-sleep-loading") {
            let day = calendar.startOfDay(for: date)
            measurements.sessions = SleepSummary.sessions([
                SleepSegment(start: day, end: day.addingTimeInterval(6 * 3600), stage: .core),
                SleepSegment(start: day.addingTimeInterval(12 * 3600), end: day.addingTimeInterval(14 * 3600), stage: .core)
            ])
        }
        return [measurements]
    }
    #endif
}
