import Foundation

/// JSON values let the sync protocol preserve a document without depending on SwiftData.
indirect enum SyncValue: Codable, Equatable, Sendable {
    case object([String: SyncValue]), array([SyncValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([SyncValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: SyncValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }
    static func document<T: Encodable>(_ value: T) throws -> SyncValue {
        try SyncCoding.decoder().decode(SyncValue.self, from: SyncCoding.encoder().encode(value))
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try SyncCoding.decoder().decode(type, from: SyncCoding.encoder().encode(self))
    }
}

enum SyncCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

enum SyncKind: String, Codable, CaseIterable, Sendable { case exercise, routine, workout, preferences }
struct SyncKey: Codable, Hashable, Sendable {
    var kind: SyncKind
    var id: UUID
    static let preferences = SyncKey(kind: .preferences, id: UUID(uuidString: "453CA844-9412-43E5-95A4-862FAEAB4686")!)
}
struct CloudRecord: Codable, Equatable, Sendable {
    var kind: SyncKind
    var id: UUID
    var revision: Int64
    /// A nil body is a durable deletion marker. Deleted IDs are never silently reused.
    var body: SyncValue?
    var key: SyncKey { SyncKey(kind: kind, id: id) }
}
struct SyncMutation: Codable, Equatable, Sendable {
    var mutationID: UUID = UUID()
    var key: SyncKey
    var expectedRevision: Int64
    var body: SyncValue?
}
struct SyncConflict: Codable, Equatable, Sendable {
    var local: SyncValue?
    var remote: CloudRecord
}
enum SyncMerge: Equatable, Sendable { case unchanged, apply(CloudRecord), conflict }
enum SyncFailure: Error, LocalizedError, Sendable {
    case accountChanged, invalidDocument, invalidState, notConfigured, unauthorized, unavailable, staleResponse
    var errorDescription: String? {
        switch self {
        case .accountChanged: "your account changed. sync was stopped."
        case .invalidDocument: "one cloud record couldn’t be read. your local log hasn’t been replaced."
        case .invalidState: "couldn’t read sync history on this iPhone. your workouts are still saved."
        case .notConfigured: "cloud sync isn’t available in this build yet."
        case .unauthorized: "sign in again to continue syncing. your local log is saved."
        case .unavailable: "couldn’t sync right now. your changes are saved on this iPhone."
        case .staleResponse: "the cloud changed while syncing. try again."
        }
    }
}

/// A persisted three-way merge base, pending requests, and unresolved copies for exactly one account.
/// Server revisions, not device clocks, order edits. The phone's current log remains authoritative
/// for unsent edits, so a crash between a local save and journaling never loses a change.
struct SyncLedger: Codable, Equatable, Sendable {
    var formatVersion = 1
    let owner: UUID
    var cursor: Int64 = 0
    var records: [SyncKey: CloudRecord] = [:]
    var pending: [SyncKey: SyncMutation] = [:]
    var conflicts: [SyncKey: SyncConflict] = [:]

    mutating func prepare(local: [SyncKey: SyncValue]) {
        let keys = Set(local.keys).union(records.keys).union(pending.keys).union(conflicts.keys)
        for key in keys {
            if var conflict = conflicts[key] {
                if local[key] == conflict.remote.body {
                    records[key] = conflict.remote; conflicts[key] = nil
                } else {
                    conflict.local = local[key]; conflicts[key] = conflict; pending[key] = nil
                    continue
                }
            }
            let base = records[key]
            guard local[key] != base?.body else { pending[key] = nil; continue }
            if let request = pending[key], request.body == local[key], request.expectedRevision == (base?.revision ?? 0) { continue }
            pending[key] = SyncMutation(key: key, expectedRevision: base?.revision ?? 0, body: local[key])
        }
    }

    /// Call against a fresh local snapshot after every awaited network operation.
    mutating func receive(_ remote: CloudRecord, local: [SyncKey: SyncValue]) throws -> SyncMerge {
        guard remote.revision > 0 else { throw SyncFailure.invalidDocument }
        let key = remote.key
        let newest = max(records[key]?.revision ?? 0, conflicts[key]?.remote.revision ?? 0)
        guard remote.revision > newest else { return .unchanged }
        let base = records[key]?.body
        let current = local[key]
        if current == remote.body || (records[key] != nil && base == remote.body) {
            records[key] = remote; conflicts[key] = nil
            prepare(local: local)
            return .unchanged
        }
        if current == base {
            records[key] = remote; conflicts[key] = nil; pending[key] = nil
            return .apply(remote)
        }
        conflicts[key] = SyncConflict(local: current, remote: remote)
        pending[key] = nil
        return .conflict
    }

    /// An acknowledged request establishes its own merge base, even if the phone was edited again
    /// while the request was in flight. Only that exact pending request is retired.
    mutating func acknowledge(_ mutation: SyncMutation, record: CloudRecord) throws {
        guard record.key == mutation.key, record.body == mutation.body, record.revision > mutation.expectedRevision else {
            throw SyncFailure.invalidDocument
        }
        if record.revision >= (records[record.key]?.revision ?? 0) { records[record.key] = record }
        if pending[record.key]?.mutationID == mutation.mutationID { pending[record.key] = nil }
    }

    mutating func resolve(_ key: SyncKey, keepLocal: Bool, local: [SyncKey: SyncValue]) -> CloudRecord? {
        guard let conflict = conflicts.removeValue(forKey: key) else { return nil }
        records[key] = conflict.remote; pending[key] = nil
        if keepLocal {
            prepare(local: local)
            return nil
        }
        return conflict.remote
    }

    func validate(owner expected: UUID) throws {
        guard formatVersion == 1, owner == expected, cursor >= 0,
              records.allSatisfy({ $0.key == $0.value.key && $0.value.revision > 0 }),
              pending.allSatisfy({ $0.key == $0.value.key && $0.value.expectedRevision >= 0 }),
              conflicts.allSatisfy({ $0.key == $0.value.remote.key && $0.value.remote.revision > 0 }) else {
            throw SyncFailure.invalidState
        }
    }
}
