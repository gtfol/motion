import Foundation

enum SleepStage: String, CaseIterable, Codable, Sendable {
    case awake, rem, core, deep, asleep

    var label: String {
        switch self {
        case .awake: "awake"
        case .rem: "REM"
        case .core: "light / core"
        case .deep: "deep"
        case .asleep: "asleep"
        }
    }

    var priority: Int {
        switch self {
        case .awake: 5
        case .deep: 4
        case .rem: 3
        case .core: 2
        case .asleep: 1
        }
    }
}

struct SleepSegment: Identifiable, Equatable, Codable, Sendable {
    let start: Date
    let end: Date
    let stage: SleepStage
    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct SleepReading: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let value: Double

    init(id: UUID = UUID(), date: Date, value: Double) {
        self.id = id
        self.date = date
        self.value = value
    }
}

struct SleepNight: Identifiable, Sendable {
    /// Recorded sleep assigned to its wake date, either one period or a full day's timeline.
    let day: Date
    let segments: [SleepSegment]
    var id: Date { start }
    var start: Date { segments[0].start }
    var end: Date { segments[segments.count - 1].end }
    var asleepDuration: TimeInterval { segments.filter { $0.stage != .awake }.reduce(0) { $0 + $1.duration } }
    var awakeCount: Int { segments.filter { $0.stage == .awake }.count }
    var hasStages: Bool { segments.contains { [.core, .deep, .rem].contains($0.stage) } }

    func duration(_ stage: SleepStage) -> TimeInterval {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
    }

    func stage(at date: Date) -> SleepStage? {
        segments.first { $0.start <= date && date < $0.end }?.stage
    }

    func readings(_ values: [SleepReading], asleepOnly: Bool = false) -> [SleepReading] {
        values.filter { point in
            guard point.value.isFinite, point.value > 0, point.date >= start, point.date < end else { return false }
            guard let stage = stage(at: point.date) else { return false }
            return !asleepOnly || stage != .awake
        }.sorted { $0.date < $1.date }
    }

    func average(_ values: [SleepReading]) -> Double? {
        let points = readings(values, asleepOnly: true)
        return points.isEmpty ? nil : points.reduce(0) { $0 + $1.value } / Double(points.count)
    }
}

struct SleepMeasurements: Sendable {
    var sessions: [SleepNight] = []
    var heartRate: [SleepReading] = []
    var respiratoryRate: [SleepReading] = []

    var days: [SleepNight] { SleepSummary.dailySummaries(sessions) }
}

enum SleepSummary {
    /// Choose a whole record for each sleep period; never splice stages from two recorders.
    /// Helio wins overlapping periods. Health can fill separate naps on the same wake date.
    static func combined(helio: SleepMeasurements, health: [SleepMeasurements]) -> SleepMeasurements {
        typealias Candidate = (night: SleepNight, recorder: Int?)
        let primary: [Candidate] = helio.sessions.filter { !$0.segments.isEmpty && $0.asleepDuration > 0 }
            .sorted {
                if $0.asleepDuration != $1.asleepDuration { return $0.asleepDuration > $1.asleepDuration }
                return $0.start < $1.start
            }.map { ($0, nil) }
        let fallback: [Candidate] = health.enumerated().flatMap { index, data in
            data.sessions.map { ($0, index) }
        }.filter { !$0.night.segments.isEmpty && $0.night.asleepDuration > 0 }.sorted {
            // Prefer a staged Health record, then the most complete night; source order breaks ties.
            if $0.night.hasStages != $1.night.hasStages { return $0.night.hasStages }
            if $0.night.asleepDuration != $1.night.asleepDuration { return $0.night.asleepDuration > $1.night.asleepDuration }
            if $0.night.end != $1.night.end { return $0.night.end > $1.night.end }
            return $0.recorder! < $1.recorder!
        }
        var chosen: [Candidate] = []
        for candidate in primary + fallback {
            let night = candidate.night
            guard !night.segments.isEmpty, night.asleepDuration > 0 else { continue }
            // A recorder can put the same sleep on a neighboring date; reject that duplicate too.
            guard !chosen.contains(where: {
                $0.night.start < night.end && night.start < $0.night.end
            }) else { continue }
            chosen.append(candidate)
        }
        chosen.sort { $0.night.start < $1.night.start }
        var result = SleepMeasurements(sessions: chosen.map(\.night))
        for candidate in chosen {
            func readings(_ key: KeyPath<SleepMeasurements, [SleepReading]>) -> [SleepReading] {
                let night = candidate.night
                let direct = night.readings(helio[keyPath: key])
                if night.average(direct) != nil { return direct }
                let options = health.enumerated().map { index, data in
                    (index: index, points: night.readings(data[keyPath: key]),
                     asleepCount: night.readings(data[keyPath: key], asleepOnly: true).count)
                }.filter { $0.asleepCount > 0 }.sorted {
                    if ($0.index == candidate.recorder) != ($1.index == candidate.recorder) {
                        return $0.index == candidate.recorder
                    }
                    if $0.asleepCount != $1.asleepCount { return $0.asleepCount > $1.asleepCount }
                    return $0.index < $1.index
                }
                // Keep a single recorder's trace, rather than averaging duplicate device readings.
                return options.first?.points ?? direct
            }
            result.heartRate += readings(\.heartRate)
            result.respiratoryRate += readings(\.respiratoryRate)
        }
        return result
    }

    /// Resolve overlaps within ONE source. Detailed stages replace generic asleep summaries;
    /// duplicate records never inflate totals. Missing intervals remain gaps, not inferred sleep.
    static func normalized(_ input: [SleepSegment]) -> [SleepSegment] {
        let valid = input.filter { $0.end > $0.start }
        let boundaries = Set(valid.flatMap { [$0.start, $0.end] }).sorted()
        guard boundaries.count > 1 else { return [] }
        var result: [SleepSegment] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard let stage = valid.filter({ $0.start < end && $0.end > start })
                .map(\.stage).max(by: { $0.priority < $1.priority }) else { continue }
            if let last = result.last, last.end == start, last.stage == stage {
                result[result.count - 1] = SleepSegment(start: last.start, end: end, stage: stage)
            } else {
                result.append(SleepSegment(start: start, end: end, stage: stage))
            }
        }
        return result
    }

    /// Include every sleep period ending on each date, leaving unrecorded intervals empty.
    static func nights(_ input: [SleepSegment], calendar: Calendar = .current) -> [SleepNight] {
        dailySummaries(sessions(input, calendar: calendar))
    }

    static func dailySummaries(_ sessions: [SleepNight]) -> [SleepNight] {
        let valid = sessions.filter { !$0.segments.isEmpty && $0.asleepDuration > 0 }
        return Dictionary(grouping: valid, by: \.day).map { day, periods in
            SleepNight(day: day, segments: normalized(periods.flatMap(\.segments)))
        }.sorted { $0.day < $1.day }
    }

    /// Health provides stage samples without session IDs. Group nearby stages, retaining every period.
    /// Call separately for each Helio record so explicit strap session boundaries are preserved.
    static func sessions(_ input: [SleepSegment], calendar: Calendar = .current, maximumGap: TimeInterval = 3_600) -> [SleepNight] {
        let segments = normalized(input)
        var groups: [[SleepSegment]] = []
        for segment in segments {
            if let last = groups.last?.last, segment.start.timeIntervalSince(last.end) <= maximumGap {
                groups[groups.count - 1].append(segment)
            } else {
                groups.append([segment])
            }
        }
        var result: [SleepNight] = []
        for group in groups {
            guard let firstSleep = group.firstIndex(where: { $0.stage != .awake }),
                  let lastSleep = group.lastIndex(where: { $0.stage != .awake }) else { continue }
            // Awake records before falling asleep / after waking aren't nighttime awakenings.
            let trimmed = Array(group[firstSleep...lastSleep])
            let day = calendar.startOfDay(for: trimmed[trimmed.count - 1].end)
            let night = SleepNight(day: day, segments: trimmed)
            result.append(night)
        }
        return result
    }
}
