import Foundation
import HealthKit

enum HealthAccess: Equatable, Sendable {
    case unavailable
    case notDetermined
    case denied
    case allowed(heartRate: Bool)
}

enum HealthExportOutcome: Equatable, Sendable {
    /// `workoutID` is nil when HealthKit saved the workout but couldn't return it (the iPhone was locked).
    case saved(workoutID: UUID?, heartRateSamples: Int)
    /// A workout from an earlier attempt was found, so nothing new was written.
    case alreadySaved(workoutID: UUID)
    case notAllowed
    case unavailable
    case failed(String)
}

protocol WorkoutExporting: Sendable {
    func access() -> HealthAccess
    func requestAccess() async -> HealthAccess
    func export(_ payload: HealthWorkoutPayload) async -> HealthExportOutcome
}

/// Saves a finished session as one Apple Health workout with `HKWorkoutBuilder`, available on iOS 12+.
/// `HKWorkoutSession` and `HKLiveWorkoutBuilder` on iPhone require iOS 26, so they aren't used.
///
/// Retrying is idempotent: the workout and every heart-rate sample carry a HealthKit sync identifier and version,
/// so HealthKit ignores a repeated save of the same object, and a retry first looks for the workout.
final class HealthKitExporter: WorkoutExporting {
    private let store = HKHealthStore()
    private static let chunkSize = 500

    func access() -> HealthAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .notDetermined: return .notDetermined
        case .sharingAuthorized:
            return .allowed(heartRate: store.authorizationStatus(for: HKQuantityType(.heartRate)) == .sharingAuthorized)
        default: return .denied
        }
    }

    /// Asks to write workouts and heart rate, and to read workouts only so a retry can find an earlier save.
    /// No energy, route, or other types are requested.
    func requestAccess() async -> HealthAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.heartRate)]
        let read: Set<HKObjectType> = [HKObjectType.workoutType()]
        do { try await store.requestAuthorization(toShare: share, read: read) } catch { return access() }
        return access()
    }

    func export(_ payload: HealthWorkoutPayload) async -> HealthExportOutcome {
        var current = access()
        if current == .notDetermined { current = await requestAccess() }
        let includeHeartRate: Bool
        switch current {
        case .unavailable: return .unavailable
        case .notDetermined, .denied: return .notAllowed
        case .allowed(let heartRate): includeHeartRate = heartRate
        }
        let syncIdentifier = HealthSync.workoutIdentifier(session: payload.sessionID)
        do {
            // Read access may be denied, which makes this find nothing. The sync identifier still prevents a duplicate.
            if let existing = try await existingWorkout(syncIdentifier: syncIdentifier) {
                return .alreadySaved(workoutID: existing.uuid)
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = Self.activityType(payload.activity)
            configuration.locationType = payload.activity == .strength ? .indoor : .unknown
            let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
            do {
                try await builder.beginCollection(at: payload.start)
                let samples = includeHeartRate ? Self.heartRateSamples(payload) : []
                for start in stride(from: 0, to: samples.count, by: Self.chunkSize) {
                    try await builder.addSamples(Array(samples[start..<min(start + Self.chunkSize, samples.count)]))
                }
                try await builder.addMetadata([HKMetadataKeySyncIdentifier: syncIdentifier, HKMetadataKeySyncVersion: HealthSync.version])
                try await builder.endCollection(at: payload.end)
                let workout = try await builder.finishWorkout()
                return .saved(workoutID: workout?.uuid, heartRateSamples: samples.count)
            } catch {
                builder.discardWorkout()
                throw error
            }
        } catch {
            return Self.outcome(for: error)
        }
    }

    private func existingWorkout(syncIdentifier: String) async throws -> HKWorkout? {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncIdentifier]),
            HKQuery.predicateForObjects(from: HKSource.default())
        ])
        let query = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [], limit: 1)
        return try await query.result(for: store).first
    }

    private static func heartRateSamples(_ payload: HealthWorkoutPayload) -> [HKSample] {
        let device = HKDevice(name: payload.strapName ?? "heart rate strap", manufacturer: nil, model: nil, hardwareVersion: nil,
                              firmwareVersion: nil, softwareVersion: nil, localIdentifier: payload.strapID?.uuidString,
                              udiDeviceIdentifier: nil)
        let type = HKQuantityType(.heartRate), unit = HKUnit.count().unitDivided(by: .minute())
        return payload.samples.map { sample in
            HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: Double(sample.bpm)),
                             start: sample.date, end: sample.date, device: device,
                             metadata: [HKMetadataKeySyncIdentifier: HealthSync.sampleIdentifier(sample: sample.id),
                                        HKMetadataKeySyncVersion: HealthSync.version])
        }
    }

    private static func activityType(_ activity: ActivityKind) -> HKWorkoutActivityType {
        switch activity {
        case .strength: .traditionalStrengthTraining
        case .running: .running
        case .walking: .walking
        case .cycling: .cycling
        case .other: .other
        }
    }

    private static func outcome(for error: any Error) -> HealthExportOutcome {
        switch (error as? HKError)?.code {
        case .errorAuthorizationDenied?, .errorAuthorizationNotDetermined?, .errorRequiredAuthorizationDenied?:
            return .notAllowed
        case .errorHealthDataUnavailable?, .errorHealthDataRestricted?:
            return .unavailable
        case .errorDatabaseInaccessible?:
            return .failed("Apple Health can’t be written while this iPhone is locked. unlock it and retry.")
        default:
            return .failed("Apple Health didn’t save the workout. retry.")
        }
    }
}
