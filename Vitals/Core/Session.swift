import Foundation

enum ActivityKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case strength, running, walking, cycling, other

    static let heartRateOnly: [ActivityKind] = [.running, .walking, .cycling, .other]

    var id: String { rawValue }
    var label: String { rawValue }
    /// Only strength sessions log exercises and sets in v1; the others record heart rate and time.
    var logsSets: Bool { self == .strength }
}

enum SessionState: String, Codable, Sendable {
    case active, completed
}

/// Apple Health export state, stored separately from the local save.
enum HealthExportState: String, Codable, Sendable {
    /// Saved locally; export not attempted yet.
    case pending
    /// An attempt is in flight. Found at launch, it means the attempt was interrupted.
    case saving
    case saved
    case failed
    case notAllowed
    case unavailable

    var label: String {
        switch self {
        case .pending: "not exported yet"
        case .saving: "saving…"
        case .saved: "saved"
        case .failed: "not saved"
        case .notAllowed: "not allowed"
        case .unavailable: "unavailable on this device"
        }
    }

    var canRetry: Bool { self == .pending || self == .failed || self == .notAllowed }
}

/// Identifiers that let HealthKit ignore a repeated save instead of creating a duplicate.
enum HealthSync {
    static let version = 1

    static func workoutIdentifier(session: UUID) -> String { "vitals.workout.\(session.uuidString.lowercased())" }
    static func sampleIdentifier(sample: UUID) -> String { "vitals.hr.\(sample.uuidString.lowercased())" }
}

/// Everything needed to write one workout to Apple Health, copied out of SwiftData.
struct HealthWorkoutPayload: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        var id: UUID
        var date: Date
        var bpm: Int
    }

    var sessionID: UUID
    var activity: ActivityKind
    var start: Date
    var end: Date
    var samples: [Sample]
    var strapName: String?
    var strapID: UUID?

    /// Keeps only samples HealthKit accepts for a builder: after the start date and not after the end date.
    init(sessionID: UUID, activity: ActivityKind, start: Date, end: Date, samples: [Sample], strapName: String?, strapID: UUID?) {
        self.sessionID = sessionID; self.activity = activity; self.start = start; self.end = max(start, end)
        self.samples = samples.filter { $0.date > start && $0.date <= max(start, end) }.sorted { $0.date < $1.date }
        self.strapName = strapName; self.strapID = strapID
    }
}

enum SessionRecovery {
    /// The last moment an interrupted session is known to have been running: its start, the app's last
    /// heartbeat, a completed set, or a received sample, whichever is latest.
    static func lastActivity(startedAt: Date, lastSeenAt: Date?, setCompletions: [Date], lastSample: Date?) -> Date {
        ([startedAt, lastSeenAt, lastSample].compactMap { $0 } + setCompletions).max() ?? startedAt
    }
}
