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
    /// Assigned to the calendar date the main sleep ended, including overnight and daytime sleep.
    let day: Date
    let segments: [SleepSegment]
    var id: Date { day }
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
            guard asleepOnly else { return true }
            guard let stage = stage(at: point.date) else { return false }
            return stage != .awake
        }.sorted { $0.date < $1.date }
    }

    func average(_ values: [SleepReading]) -> Double? {
        let points = readings(values, asleepOnly: true)
        return points.isEmpty ? nil : points.reduce(0) { $0 + $1.value } / Double(points.count)
    }
}

enum SleepSummary {
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

    /// Keep the longest sleep period ending on each day. Separate naps are not added to the night.
    static func nights(_ input: [SleepSegment], calendar: Calendar = .current) -> [SleepNight] {
        let segments = normalized(input)
        var groups: [[SleepSegment]] = []
        for segment in segments {
            if let last = groups.last?.last, segment.start.timeIntervalSince(last.end) <= 3 * 3_600 {
                groups[groups.count - 1].append(segment)
            } else {
                groups.append([segment])
            }
        }
        var byDay: [Date: SleepNight] = [:]
        for group in groups {
            guard let firstSleep = group.firstIndex(where: { $0.stage != .awake }),
                  let lastSleep = group.lastIndex(where: { $0.stage != .awake }) else { continue }
            // Awake records before falling asleep / after waking aren't nighttime awakenings.
            let trimmed = Array(group[firstSleep...lastSleep])
            let day = calendar.startOfDay(for: trimmed[trimmed.count - 1].end)
            let night = SleepNight(day: day, segments: trimmed)
            if night.asleepDuration > (byDay[day]?.asleepDuration ?? 0) { byDay[day] = night }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}
