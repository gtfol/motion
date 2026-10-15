import Foundation
import HealthKit
import Observation

struct SleepSource: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Read-only, on-device HealthKit data. Nothing here enters the workout database or cloud sync.
@MainActor @Observable final class SleepHealthStore {
    private(set) var sources: [SleepSource] = []
    private(set) var nights: [SleepNight] = []
    private(set) var heartRate: [SleepReading] = []
    private(set) var respiratoryRate: [SleepReading] = []
    private(set) var heartSource: String?
    private(set) var respiratorySource: String?
    private(set) var loading = false
    private(set) var message: String?
    var selectedSource = ""
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
        // Clear old dates / source immediately, including on failures or revoked read access.
        nights = []; heartRate = []; respiratoryRate = []; heartSource = nil; respiratorySource = nil
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
        do {
            let query = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)])
            let samples = try await query.result(for: store)
            guard generation == request else { return }
            let usable = samples.filter { Self.stage($0.value) != nil && $0.endDate <= end }
            let grouped = Dictionary(grouping: usable, by: { $0.sourceRevision.source.bundleIdentifier })
            sources = grouped.compactMap { id, values in
                values.first.map { SleepSource(id: id, name: $0.sourceRevision.source.name) }
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if grouped[selectedSource] == nil {
                // Prefer the source with the most recent sleep; the picker always allows an override.
                selectedSource = usable.max(by: { $0.endDate < $1.endDate })?.sourceRevision.source.bundleIdentifier ?? ""
            }
            let selected = grouped[selectedSource] ?? []
            nights = SleepSummary.nights(selected.compactMap { sample in
                Self.stage(sample.value).map { SleepSegment(start: sample.startDate, end: sample.endDate, stage: $0) }
            }).filter { $0.day <= day }
            // A separate failure shouldn't discard readable sleep. Denied types return no samples.
            do {
                let values = try await readings(.heartRate, predicate: predicate)
                guard generation == request else { return }
                heartRate = values.points
                heartSource = values.source
            } catch { if generation == request { message = "sleep loaded, but heart rate couldn’t be read. pull down to retry." } }
            do {
                let values = try await readings(.respiratoryRate, predicate: predicate)
                guard generation == request else { return }
                respiratoryRate = values.points
                respiratorySource = values.source
            } catch { if generation == request { message = "sleep loaded, but breathing rate couldn’t be read. pull down to retry." } }
        } catch {
            guard generation == request else { return }
            sources = []
            message = "couldn’t read Apple Health. unlock your iPhone and pull down to retry."
        }
    }

    private func readings(_ identifier: HKQuantityTypeIdentifier, predicate: NSPredicate) async throws -> (points: [SleepReading], source: String?) {
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(identifier), predicate: predicate)],
                                            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)])
        let samples = try await query.result(for: store)
        // Prefer the sleep recorder. If it provides no readings of this type, use one other source,
        // never interleave measurements from multiple devices into a misleading continuous trace.
        let overnight = samples.filter { sample in nights.contains { $0.start <= sample.startDate && sample.startDate < $0.end } }
        let grouped = Dictionary(grouping: overnight, by: { $0.sourceRevision.source.bundleIdentifier })
        let source = grouped[selectedSource] != nil ? selectedSource :
            grouped.keys.sorted().max(by: { (grouped[$0]?.count ?? 0) < (grouped[$1]?.count ?? 0) })
        let chosen = source.flatMap { grouped[$0] } ?? []
        let points = chosen.map {
            SleepReading(id: $0.uuid, date: $0.startDate, value: $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())))
        }
        return (points, chosen.first?.sourceRevision.source.name)
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
        sources = [SleepSource(id: "test-recorder", name: "sample data · UI test")]
        selectedSource = "test-recorder"
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
            nights.append(SleepNight(day: day, segments: segments))
            for minute in stride(from: 0, to: 480, by: 5) {
                let at = start.addingTimeInterval(Double(minute) * 60)
                heartRate.append(SleepReading(date: at, value: 55 + sin(Double(minute) / 24) * 6))
                if offset != -1 { respiratoryRate.append(SleepReading(date: at, value: 13 + sin(Double(minute) / 34))) }
            }
        }
        heartSource = "sample data · UI test"
        respiratorySource = "sample data · UI test"
    }
    #endif
}
