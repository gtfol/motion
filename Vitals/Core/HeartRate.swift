import Foundation

enum SensorContact: String, Codable, Sendable {
    case unsupported, notDetected, detected
}

/// A parsed Heart Rate Measurement (GATT characteristic 0x2A37).
struct HeartRateMeasurement: Sendable, Equatable {
    /// The largest value accepted as a reading. A strap sends 0 when it has no reading; that is never stored.
    static let plausibleRange = 1...300

    var bpm: Int
    var sensorContact: SensorContact
    var energyExpendedKilojoules: Int?
    /// RR intervals exactly as received, in 1/1024-second units. Empty when the strap doesn't send them.
    var rrIntervals: [UInt16]

    var isPlausible: Bool { Self.plausibleRange.contains(bpm) }

    /// Flags: bit 0 = 16-bit value, bits 1–2 = sensor contact, bit 3 = energy expended, bit 4 = RR intervals.
    static func parse(_ data: Data) -> HeartRateMeasurement? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        var index = 1
        func uint16() -> UInt16? {
            guard index + 1 < bytes.count else { return nil }
            defer { index += 2 }
            return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
        }
        let bpm: Int
        if flags & 0x01 != 0 {
            guard let value = uint16() else { return nil }
            bpm = Int(value)
        } else {
            guard bytes.count > 1 else { return nil }
            bpm = Int(bytes[1]); index = 2
        }
        let contact: SensorContact = flags & 0x04 == 0 ? .unsupported : (flags & 0x02 == 0 ? .notDetected : .detected)
        var energy: Int?
        if flags & 0x08 != 0 {
            guard let value = uint16() else { return nil }
            energy = Int(value)
        }
        var intervals: [UInt16] = []
        if flags & 0x10 != 0 {
            while let value = uint16() { intervals.append(value) }
        }
        return HeartRateMeasurement(bpm: bpm, sensorContact: contact, energyExpendedKilojoules: energy, rrIntervals: intervals)
    }
}

enum BatteryLevel {
    /// Battery Level (0x2A19): one byte, 0–100 percent.
    static func parse(_ data: Data) -> Int? {
        guard let value = data.first, value <= 100 else { return nil }
        return Int(value)
    }
}

/// Raw RR intervals are stored as little-endian UInt16 values in 1/1024-second units, as received.
enum RRIntervals {
    static func encode(_ values: [UInt16]) -> Data? {
        guard !values.isEmpty else { return nil }
        var data = Data(capacity: values.count * 2)
        for value in values { data.append(UInt8(value & 0xFF)); data.append(UInt8(value >> 8)) }
        return data
    }

    static func decode(_ data: Data?) -> [UInt16] {
        guard let data else { return [] }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
    }

    static func seconds(_ raw: UInt16) -> Double { Double(raw) / 1_024 }
}

struct HeartRatePoint: Sendable, Equatable {
    var date: Date
    var bpm: Int
}

/// Current, average, minimum, and maximum from actually received samples only.
struct HeartRateStats: Sendable, Equatable {
    private(set) var count = 0
    private(set) var total = 0
    private(set) var minimum = Int.max
    private(set) var maximum = Int.min
    private(set) var latest: HeartRatePoint?

    init() {}
    init<S: Sequence>(_ points: S) where S.Element == HeartRatePoint { points.forEach { add($0) } }

    mutating func add(_ point: HeartRatePoint) {
        count += 1; total += point.bpm
        minimum = Swift.min(minimum, point.bpm); maximum = Swift.max(maximum, point.bpm)
        if latest.map({ point.date >= $0.date }) ?? true { latest = point }
    }

    var isEmpty: Bool { count == 0 }
    var average: Int? { count == 0 ? nil : Int((Double(total) / Double(count)).rounded()) }
    var lowest: Int? { count == 0 ? nil : minimum }
    var highest: Int? { count == 0 ? nil : maximum }
}

enum HeartRateSeries {
    /// Straps notify about once per second; a longer silence is shown as a gap and never filled in.
    static let gapThreshold: TimeInterval = 10

    /// Silences longer than the threshold between consecutive received samples.
    static func gaps(in points: [HeartRatePoint], threshold: TimeInterval = gapThreshold) -> [DateInterval] {
        let sorted = points.sorted { $0.date < $1.date }
        return zip(sorted, sorted.dropFirst()).compactMap { earlier, later in
            later.date.timeIntervalSince(earlier.date) > threshold ? DateInterval(start: earlier.date, end: later.date) : nil
        }
    }

    /// Chart segments split at gaps so lines never bridge missing data. Long sessions are thinned by
    /// averaging within time buckets; the summary statistics always use every sample.
    static func segments(_ points: [HeartRatePoint], threshold: TimeInterval = gapThreshold, maxPoints: Int = 240) -> [[HeartRatePoint]] {
        let sorted = points.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        var segments: [[HeartRatePoint]] = [[first]]
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            if later.date.timeIntervalSince(earlier.date) > threshold { segments.append([later]) }
            else { segments[segments.count - 1].append(later) }
        }
        guard sorted.count > maxPoints, maxPoints > 0 else { return segments }
        let bucket = max(1, last.date.timeIntervalSince(first.date) / Double(maxPoints))
        return segments.map { segment in
            var result: [HeartRatePoint] = [], index = 0
            while index < segment.count {
                let bucketIndex = Int(segment[index].date.timeIntervalSince(first.date) / bucket)
                var end = index, time = 0.0, total = 0
                while end < segment.count, Int(segment[end].date.timeIntervalSince(first.date) / bucket) == bucketIndex {
                    time += segment[end].date.timeIntervalSince(first.date); total += segment[end].bpm; end += 1
                }
                let count = Double(end - index)
                result.append(HeartRatePoint(date: first.date.addingTimeInterval(time / count),
                                             bpm: Int((Double(total) / count).rounded())))
                index = end
            }
            return result
        }
    }
}

struct HeartRateSummary: Sendable, Equatable {
    var stats: HeartRateStats
    var gaps: [DateInterval]

    init?(_ points: [HeartRatePoint]) {
        guard !points.isEmpty else { return nil }
        stats = HeartRateStats(points); gaps = HeartRateSeries.gaps(in: points)
    }

    var gapDuration: TimeInterval { gaps.reduce(0) { $0 + $1.duration } }
}

/// Approximate training zones from an age-estimated maximum (220 − age). Not a medical measurement.
enum HeartRateZone {
    static let ages = 13...100

    static func estimatedMaximum(age: Int?) -> Int? {
        guard let age, ages.contains(age) else { return nil }
        return 220 - age
    }

    /// Zones 1–5 at 50/60/70/80/90 percent of the estimated maximum; nil below zone 1 or without an age.
    static func zone(bpm: Int, age: Int?) -> Int? {
        guard let maximum = estimatedMaximum(age: age), bpm > 0 else { return nil }
        let percent = bpm * 100 / maximum
        guard percent >= 50 else { return nil }
        return min(5, (percent - 50) / 10 + 1)
    }
}

/// One notification from the selected strap, stamped when it arrived.
struct HeartRateReading: Sendable, Equatable {
    var peripheralID: UUID
    var receivedAt: Date
    var measurement: HeartRateMeasurement

    var point: HeartRatePoint { HeartRatePoint(date: receivedAt, bpm: measurement.bpm) }
}
