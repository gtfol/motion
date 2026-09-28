import Charts
import SwiftUI

/// Live heart rate from the chosen strap. With a session it also shows that session's statistics and chart;
/// without one it only shows the live number, which isn't saved.
struct HeartRatePanel: View {
    @Environment(HeartRateMonitor.self) private var monitor
    @Environment(SessionCoordinator.self) private var coordinator
    let session: WorkoutSession?
    /// A reading older than this is shown as missing rather than as the current heart rate.
    static let staleAfter: TimeInterval = 5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let reading = monitor.latest
            let fresh = reading.map { context.date.timeIntervalSince($0.receivedAt) < Self.staleAfter } ?? false
            let bpm = fresh ? reading?.measurement.bpm : nil
            let zone = bpm.flatMap { HeartRateZone.zone(bpm: $0, age: coordinator.age) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bpm.map { "\($0)" } ?? "–")
                        .font(VitalsStyle.live).monospacedDigit()
                        .foregroundStyle(bpm == nil ? VitalsStyle.secondary : VitalsStyle.zoneTint(zone))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("bpm").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        if let zone {
                            Text("zone \(zone)").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.zoneTint(zone))
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(status(at: context.date, fresh: fresh)).font(VitalsStyle.caption).multilineTextAlignment(.trailing)
                        Text(detail).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary).multilineTextAlignment(.trailing)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(bpm: bpm, zone: zone, at: context.date, fresh: fresh))
                if let session {
                    HeartRateChart(points: coordinator.liveSamples, start: session.startedAt, end: context.date, compact: true)
                        .frame(height: 36)
                }
            }
        }
    }

    private func status(at now: Date, fresh: Bool) -> String {
        let name = monitor.strapName ?? "strap"
        switch monitor.status {
        case .connected:
            var text = "connected · waiting for heart rate"
            if let latest = monitor.latest {
                text = "connected · \(fresh ? "" : "last ")\(ClockText.ago(latest.receivedAt, now: now))"
            }
            if monitor.sensorContact == .notDetected { text = "connected · no skin contact" }
            if let battery = monitor.batteryPercent { text += " · battery \(battery)%" }
            return text
        case .searching: return "searching for \(name)…"
        case .reconnecting:
            if let lostAt = monitor.lostAt { return "reconnecting · no heart rate for \(ClockText.duration(now.timeIntervalSince(lostAt)))" }
            return "reconnecting…"
        case .noHeartRateService: return "no heart rate · turn on Heart Rate Push in Zepp"
        case .noStrap: return "no strap · choose one in settings"
        default: return monitor.status.label
        }
    }

    private var detail: String {
        guard session != nil else { return "live only, not recorded" }
        let stats = coordinator.liveStats
        guard let average = stats.average, let highest = stats.highest else { return "no heart rate recorded yet" }
        return "avg \(average) · max \(highest)"
    }

    private func accessibilityText(bpm: Int?, zone: Int?, at now: Date, fresh: Bool) -> String {
        var parts = [bpm.map { "heart rate \($0) beats per minute" } ?? "no current heart rate"]
        if let zone { parts.append("approximate zone \(zone)") }
        parts.append(status(at: now, fresh: fresh))
        parts.append(detail)
        return parts.joined(separator: ", ")
    }
}

/// Received samples only. Lines break at gaps instead of bridging them.
struct HeartRateChart: View {
    let points: [HeartRatePoint]
    let start: Date
    let end: Date
    var compact = true

    var body: some View {
        let segments = HeartRateSeries.segments(points, maxPoints: compact ? 180 : 300)
        let values = points.map(\.bpm)
        if let low = values.min(), let high = values.max() {
            Chart {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if segment.count == 1, let point = segment.first {
                        PointMark(x: .value("time", point.date), y: .value("bpm", point.bpm)).symbolSize(10)
                    } else {
                        ForEach(segment, id: \.date) { point in
                            LineMark(x: .value("time", point.date), y: .value("bpm", point.bpm), series: .value("segment", index))
                                .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2))
                        }
                    }
                }
            }
            .foregroundStyle(VitalsStyle.text)
            .chartXScale(domain: start...max(end, start.addingTimeInterval(60)))
            .chartYScale(domain: (low - 5)...(high + 5))
            .chartXAxis(compact ? .hidden : .automatic)
            .chartYAxis(compact ? .hidden : .automatic)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("heart rate chart")
            .accessibilityValue("\(points.count) samples, \(HeartRateSeries.gaps(in: points).count) gaps, from \(low) to \(high) beats per minute")
        } else {
            Text(compact ? "" : "no heart rate recorded")
                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityHidden(compact)
        }
    }
}

struct HeartRateStatsText: View {
    let stats: HeartRateStats
    let gaps: [DateInterval]

    var body: some View {
        if let average = stats.average, let lowest = stats.lowest, let highest = stats.highest {
            VStack(alignment: .leading, spacing: 4) {
                Text("avg \(average) · min \(lowest) · max \(highest) bpm")
                Text(sampleLine).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        } else {
            Text("no heart rate recorded").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
        }
    }

    private var sampleLine: String {
        let samples = "\(stats.count.formatted()) \(stats.count == 1 ? "sample" : "samples")"
        guard !gaps.isEmpty else { return "\(samples) · no gaps" }
        let total = gaps.reduce(0) { $0 + $1.duration }
        return "\(samples) · \(gaps.count) \(gaps.count == 1 ? "gap" : "gaps") (\(ClockText.summary(total))) without heart rate"
    }
}
