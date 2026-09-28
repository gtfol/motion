import Foundation

/// Elapsed-time text computed from timestamps, never from a running counter.
enum ClockText {
    /// "0:07", "12:34", "1:02:03". Floors to whole seconds; negative intervals read as zero.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Summary form: "45 s", "43 min", "1 h 5 min".
    static func summary(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        if total < 60 { return "\(total) s" }
        let hours = total / 3_600, minutes = (total % 3_600) / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    /// "now", "12 s ago", "3 min ago" for the last received heart-rate sample.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded(.down)))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3_600) h ago"
    }
}

/// A rest period derived from its start time, so it stays correct across screen locks and relaunches.
struct RestTimer: Sendable, Equatable {
    static let defaultTarget = 120
    static let targetRange = 15...600
    static let quickAdd = 30.0

    var startedAt: Date
    var target: TimeInterval

    func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }
    func remaining(at now: Date) -> TimeInterval { max(0, target - elapsed(at: now)) }
    func isOver(at now: Date) -> Bool { elapsed(at: now) >= target }
    func extended(by seconds: TimeInterval = RestTimer.quickAdd) -> RestTimer {
        RestTimer(startedAt: startedAt, target: target + seconds)
    }

    /// Clamps a user preference to the supported range.
    static func clampedTarget(_ seconds: Int) -> Int {
        min(max(seconds, targetRange.lowerBound), targetRange.upperBound)
    }
}
