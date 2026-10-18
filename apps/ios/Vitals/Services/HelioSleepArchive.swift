import Foundation
import Security
import CryptoKit
@preconcurrency import ZeppKit

/// Account- and strap-scoped local sleep history. No raw packets, credentials or cloud uploads.
struct HelioSleepArchive: Codable {
    struct Session: Codable {
        let timestamp: Date
        let segments: [SleepSegment]
    }
    var sessions: [Session] = []
    var heartRate: [SleepReading] = []
    var respiratoryRate: [SleepReading] = []
    var cursors: [String: Date] = [:]
    var lastSync: Date?

    var nights: [SleepNight] { SleepSummary.dailySummaries(sessions.flatMap { SleepSummary.sessions($0.segments, maximumGap: .infinity) }) }

    /// Limit chart work to the visible week, with two days of margin for cross-midnight sleep.
    func sleepSessions(endingOn date: Date, calendar: Calendar = .current) -> [SleepNight] {
        let day = calendar.startOfDay(for: date)
        let lower = calendar.date(byAdding: .day, value: -8, to: day)!
        let upper = calendar.date(byAdding: .day, value: 1, to: day)!
        return sessions.filter { $0.segments.contains { $0.end >= lower && $0.start < upper } }
            .flatMap { SleepSummary.sessions($0.segments, calendar: calendar, maximumGap: .infinity) }
            .filter { $0.day >= lower && $0.day <= day }
            .sorted { $0.start < $1.start }
    }

    @discardableResult
    mutating func merge(_ round: ZeppFetchRound, now: Date) throws -> HelioTransferError? {
        guard round.crcVerified else { throw HelioTransferError.unverified }
        let oldest = now.addingTimeInterval(-90 * 86_400)
        func valid(_ date: Date) -> Bool { date >= oldest && date <= now.addingTimeInterval(300) }
        var sleepIssue: HelioTransferError?
        switch round.parsed.records {
        case .sleepSession(let records):
            if round.parsed.skippedRecords != round.parsed.unstagedSleepRecords {
                sleepIssue = .stageFormat
            }
            for record in records {
                do {
                    let segments = try Self.validatedSegments(record, valid: valid)
                    sessions.removeAll { $0.timestamp == record.time }
                    sessions.append(Session(timestamp: record.time, segments: segments))
                } catch let issue as HelioTransferError {
                    // Keep good records from the same transfer and the old copy of this record.
                    if sleepIssue == nil { sleepIssue = issue }
                }
            }
        case .activity(let records):
            guard round.parsed.skippedRecords == 0, records.allSatisfy({ valid($0.time) }) else { throw HelioTransferError.readingDates }
            let points = records.compactMap { record -> SleepReading? in
                guard valid(record.time), record.kind != ZeppActivityMinute.kindNotWorn,
                      record.kind != ZeppActivityMinute.kindCharging, let bpm = record.heartRate,
                      (20...250).contains(bpm) else { return nil }
                return SleepReading(date: record.time, value: Double(bpm))
            }
            heartRate = Self.merged(heartRate, points)
        case .sleepRespiratoryRate(let records):
            guard round.parsed.skippedRecords == 0, records.allSatisfy({ valid($0.time) }) else { throw HelioTransferError.readingDates }
            let points = records.compactMap { record -> SleepReading? in
                guard valid(record.time), (1...80).contains(record.breathsPerMinute) else { return nil }
                return SleepReading(date: record.time, value: Double(record.breathsPerMinute))
            }
            respiratoryRate = Self.merged(respiratoryRate, points)
        default: throw HelioTransferError.unsupportedRecord
        }
        sessions = sessions.filter { $0.timestamp >= oldest }.sorted { $0.timestamp < $1.timestamp }
        heartRate.removeAll { $0.date < oldest }; respiratoryRate.removeAll { $0.date < oldest }
        // A rejected record must be retried, even if later valid sessions were saved.
        if sleepIssue == nil, let next = round.nextSince, valid(next) { cursors[String(round.type.rawValue)] = next }
        return sleepIssue
    }

    private static func validatedSegments(_ record: ZeppSleepSession, valid: (Date) -> Bool) throws -> [SleepSegment] {
        guard valid(record.time), valid(record.sleepStart), valid(record.sleepEnd),
              record.sleepEnd > record.sleepStart,
              record.sleepEnd.timeIntervalSince(record.sleepStart) <= 36 * 3_600 else {
            throw HelioTransferError.sleepDates
        }
        var segments: [SleepSegment] = []
        var previousStart: Date?
        var previousEnd: Date?
        for (index, stage) in record.stages.enumerated() {
            let boundsError = HelioTransferError.stageBounds(
                startOffset: Int(stage.start.timeIntervalSince(record.sleepStart) / 60),
                endOffset: Int(stage.end.timeIntervalSince(record.sleepEnd) / 60),
                duration: Int(stage.end.timeIntervalSince(stage.start) / 60))
            guard stage.end >= stage.start else { throw boundsError }
            if let previousStart, stage.start <= previousStart { throw HelioTransferError.stageOverlap }
            if let previousEnd, stage.start < previousEnd { throw HelioTransferError.stageOverlap }
            previousStart = stage.start
            previousEnd = stage.end
            // The wire fields have minute precision. Accept a one-minute edge overhang by
            // intersecting with the declared session, never shifting or inventing sleep time.
            guard stage.start >= record.sleepStart.addingTimeInterval(-60),
                  stage.end <= record.sleepEnd.addingTimeInterval(60) else { throw boundsError }
            // The stage end names its final recorded minute; the session end is a boundary.
            // Cap at the next start too, so shared-boundary records never double-count time.
            let nextStart = record.stages.indices.contains(index + 1) ? record.stages[index + 1].start : record.sleepEnd
            let start = max(stage.start, record.sleepStart)
            let end = min(stage.endExclusive, nextStart, record.sleepEnd)
            guard end > start else {
                if stage.kind == .awake { continue }
                throw boundsError
            }
            let kind: SleepStage
            switch stage.kind {
            case .light: kind = .core
            case .deep: kind = .deep
            case .rem: kind = .rem
            case .awake: kind = .awake
            case .other: continue
            }
            segments.append(SleepSegment(start: start, end: end, stage: kind))
        }
        guard !segments.isEmpty else { throw HelioTransferError.unknownStages }
        return segments
    }

    private static func merged(_ old: [SleepReading], _ new: [SleepReading]) -> [SleepReading] {
        var byTime = Dictionary(old.map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
        for point in new { byTime[point.date] = point }
        return byTime.values.sorted { $0.date < $1.date }
    }
}

/// Content failures are distinct from a failed write. Never include raw records or keys in errors.
enum HelioTransferError: Error {
    case unverified, stageFormat, sleepDates, stageOverlap, unknownStages, readingDates, unsupportedRecord
    case stageBounds(startOffset: Int, endOffset: Int, duration: Int)

    /// Relative offsets only: no key, packets, absolute timestamps, account or health readings.
    var diagnosticDetails: String {
        switch self {
        case let .stageBounds(start, end, duration):
            return "sleep stage bounds; start offset: \(start) min; end offset: \(end) min; stage duration: \(duration) min"
        default: return String(describing: self)
        }
    }

    func message(for type: ZeppFetchType) -> String {
        switch self {
        case .unverified: return "Motion couldn’t finish downloading from your strap. try syncing again."
        case .stageFormat, .sleepDates, .stageBounds, .stageOverlap, .unknownStages:
            return "Motion couldn’t read some sleep data from your strap. try syncing again."
        case .readingDates:
            let metric = type == .activity ? "heart rate" : "breathing"
            return "Motion couldn’t read some \(metric) data from your strap. try syncing again."
        case .unsupportedRecord: return "Motion couldn’t read some data from your strap. try syncing again."
        }
    }
}

enum HelioSleepError: Error { case storage, keychain }

@MainActor final class HelioSleepRepository {
    let directory: URL
    init(directory: URL) { self.directory = directory.appendingPathComponent("helio-sleep", isDirectory: true) }
    func url(_ strap: UUID) -> URL { directory.appendingPathComponent("\(strap.uuidString).json") }
    func load(_ strap: UUID) throws -> HelioSleepArchive {
        let path = url(strap)
        guard FileManager.default.fileExists(atPath: path.path) else { return HelioSleepArchive() }
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1_024 * 1_024 else { throw HelioSleepError.storage }
        return try JSONDecoder().decode(HelioSleepArchive.self, from: Data(contentsOf: path))
    }
    func save(_ archive: HelioSleepArchive, strap: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url(strap), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
    // The app container's UUID changes on updates. Only the stable account directory identifies keys.
    var keyScope: String { SHA256.hash(data: Data(directory.deletingLastPathComponent().lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// This-device-only, never shown again, never copied to defaults, logs or workout sync.
enum HelioBandKeys {
    static func removeAll(scope: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.gtfol.vitals.helio", kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw HelioSleepError.keychain }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(scope + ".") else { continue }
            let deletion: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.gtfol.vitals.helio", kSecAttrAccount as String: account]
            let removed = SecItemDelete(deletion as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { throw HelioSleepError.keychain }
        }
    }
    private static func query(scope: String, strap: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.gtfol.vitals.helio",
         kSecAttrAccount as String: "\(scope).\(strap.uuidString)"]
    }
    static func read(scope: String, strap: UUID) throws -> ZeppAuthKey? {
        var q = query(scope: scope, strap: strap)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data, let key = ZeppAuthKey(bytes: Array(bytes)) else {
            throw HelioSleepError.keychain
        }
        return key
    }
    static func save(_ text: String, scope: String, strap: UUID) throws {
        guard ZeppAuthKey(hex: text) != nil else { throw HelioSleepError.keychain }
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "0x", with: "")
        let chars = Array(digits)
        let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
        let q = query(scope: scope, strap: strap)
        let attributes: [String: Any] = [kSecValueData as String: Data(bytes), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw HelioSleepError.keychain }
        } else if status != errSecSuccess { throw HelioSleepError.keychain }
    }
    static func remove(scope: String, strap: UUID) throws {
        let status = SecItemDelete(query(scope: scope, strap: strap) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HelioSleepError.keychain }
    }
}
