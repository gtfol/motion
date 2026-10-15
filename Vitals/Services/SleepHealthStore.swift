import Foundation
import HealthKit
import Observation

/// Read-only, on-device HealthKit data. Nothing here enters the workout database or cloud sync.
@MainActor @Observable final class SleepHealthStore {
    private(set) var records: [SleepMeasurements] = []
    private(set) var loading = false
    private(set) var message: String?
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var generation = UUID()

    var usesTestMeasurements: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing") && ProcessInfo.processInfo.arguments.contains("-ui-testing-sleep")
        #else
        false
        #endif
    }

    func connect() async -> Bool {
        guard available else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [
                HKCategoryType(.sleepAnalysis), HKQuantityType(.heartRate), HKQuantityType(.respiratoryRate)
            ])
            // Completion does NOT indicate read permission. HealthKit deliberately hides denials.
            return true
        } catch {
            message = "couldn’t open Apple Health permissions. try again."
            return false
        }
    }

    func load(endingOn date: Date) async {
        let request = UUID()
        generation = request
        loading = true
        message = nil
        // Clear old dates immediately, including on failures or revoked read access.
        records = []
        defer { if generation == request { loading = false } }
        #if DEBUG
        if usesTestMeasurements { loadTestMeasurements(endingOn: date); return }
        #endif
        guard available else { message = "Apple Health isn’t available on this device."; return }
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
            guard generation == request else { return }
            let usable = samples.filter { Self.stage($0.value) != nil && $0.endDate <= end }
            for (id, values) in Dictionary(grouping: usable, by: { $0.sourceRevision.source.bundleIdentifier }) {
                bySource[id, default: SleepMeasurements()].nights = SleepSummary.nights(values.compactMap { sample in
                    Self.stage(sample.value).map { SleepSegment(start: sample.startDate, end: sample.endDate, stage: $0) }
                }).filter { $0.day <= day }
            }
        } catch { failures.append("sleep") }
        // Query each metric even if Health has no sleep record: it may fill a Helio night's missing metric.
        for (type, key, label) in [
            (HKQuantityTypeIdentifier.heartRate, \SleepMeasurements.heartRate, "heart rate"),
            (.respiratoryRate, \SleepMeasurements.respiratoryRate, "breathing rate")
        ] {
            guard generation == request else { return }
            do {
                let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(type), predicate: predicate)],
                                                    sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)])
                let samples = try await query.result(for: store)
                guard generation == request else { return }
                for (id, values) in Dictionary(grouping: samples, by: { $0.sourceRevision.source.bundleIdentifier }) {
                    bySource[id, default: SleepMeasurements()][keyPath: key] = values.map {
                        SleepReading(id: $0.uuid, date: $0.startDate,
                                     value: $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())))
                    }
                }
            } catch { failures.append(label) }
        }
        guard generation == request else { return }
        records = bySource.keys.sorted().compactMap { bySource[$0] }
        if !failures.isEmpty {
            message = "couldn’t read \(failures.joined(separator: ", ")) from Apple Health. unlock your iPhone and pull down to retry."
        }
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
    private func loadTestMeasurements(endingOn date: Date) {
        var measurements = SleepMeasurements()
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-sleep-empty") { return }
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
            measurements.nights.append(SleepNight(day: day, segments: segments))
            for minute in stride(from: 0, to: 480, by: 5) {
                let at = start.addingTimeInterval(Double(minute) * 60)
                measurements.heartRate.append(SleepReading(date: at, value: 55 + sin(Double(minute) / 24) * 6))
                if offset != -1 { measurements.respiratoryRate.append(SleepReading(date: at, value: 13 + sin(Double(minute) / 34))) }
            }
        }
        records = [measurements]
    }
    #endif
}
