import Charts
import SwiftUI

struct SleepTab: View {
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HelioSleepSync.self) private var helio
    @AppStorage("sleep-health-requested") private var requested = false
    @Environment(SleepHealthStore.self) private var health
    @State private var period: SleepPeriod = .daily
    @State private var date = Calendar.current.startOfDay(for: Date.now)
    @State private var selectedTime: Date?
    private var measurements: SleepMeasurements {
        SleepSummary.combined(
            helio: SleepMeasurements(nights: helio.archive.nights(endingOn: date),
                                     heartRate: helio.archive.heartRate, respiratoryRate: helio.archive.respiratoryRate),
            health: health.records
        )
    }

    var body: some View {
        let data = measurements
        let night = data.nights.first { Calendar.current.isDate($0.day, inSameDayAs: date) }
        let week = data.nights.filter { $0.day >= weekDomain.lowerBound && $0.day <= date }
        NavigationStack {
            VStack(spacing: 0) {
                Picker("sleep view", selection: $period) {
                    ForEach(SleepPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sleep-period")
                .padding(.horizontal, VitalsStyle.gutter)
                .padding(.vertical, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        datePicker
                        if helio.busy {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(helio.status).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                            }
                        }
                        if period == .weekly, !week.isEmpty {
                            weeklyCharts(data, week: week)
                        } else if period == .daily, let night {
                            nightSummary(night)
                            stageChart(night)
                            SleepRateCard(title: "sleep heart rate", unit: "bpm", color: VitalsStyle.heart,
                                          night: night, values: data.heartRate)
                            SleepRateCard(title: "breathing rate", unit: "breaths/min", color: .cyan,
                                          night: night, values: data.respiratoryRate)
                        } else if health.loading {
                            ProgressView("loading sleep…").frame(maxWidth: .infinity)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(period == .daily ? "no sleep measurements for this date" : "no sleep measurements for this week",
                                      systemImage: "moon.zzz").font(VitalsStyle.heading)
                                Text(!helio.hasKey && !requested
                                     ? "set up your strap or Apple Health in settings."
                                     : period == .daily ? "check another date, or pull down to sync." : "check another week, or pull down to sync.")
                                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                            }
                            .accessibilityIdentifier("sleep-empty")
                        }
                        if let message = helio.message {
                            Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                        }
                        if let message = health.message {
                            Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                        }
                    }
                    .padding(VitalsStyle.gutter)
                }
                .refreshable { await reload(force: true) }
                // Each period starts at its own header instead of inheriting the other page's scroll offset.
                .id(period)
            }
            .vitalsScreen()
            .vitalsTitle("sleep")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    InfoButton(title: "sleep & breathing", paragraphs: [
                        "set up your Helio Strap and optional Apple Health access in settings. pull down here to sync.",
                        "Helio is preferred for each night’s sleep, heart rate and breathing rate. Apple Health fills missing nights or metrics. each night uses one sleep recording, so overlapping records aren’t counted twice.",
                        "keep the strap nearby and close Zepp if it holds the Bluetooth connection. Motion leaves recordings on the band and stores its copy on this iPhone.",
                        "breathing rate is breaths per minute, not a breath-by-breath waveform. Motion doesn’t estimate hypopnea, diagnose breathing problems, or reproduce Zepp’s sleep scores.",
                        "shows the longest sleep period ending on each date. missing measurements stay blank. sleep totals exclude awake time. nightly averages use samples recorded during measured sleep."
                    ])
                }.quietBackground()
            }
        }
        .task(id: date) {
            selectedTime = nil
            if health.usesTestMeasurements { requested = true }
            if active { await reload() }
        }
        .onChange(of: active) { _, visible in if visible { Task { await reload() } } }
        .onChange(of: scenePhase) { _, phase in if phase == .active && active { Task { await reload() } } }
    }

    private var datePicker: some View {
        HStack {
            Button { changeDay(period == .daily ? -1 : -7) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(period == .daily ? "previous sleep date" : "previous sleep week")
                .accessibilityIdentifier("sleep-previous")
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                if period == .weekly {
                    Text("week ending").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
                DatePicker(period == .daily ? "wake date" : "week ending", selection: $date,
                           in: ...Date.now, displayedComponents: .date)
                    .labelsHidden().accessibilityLabel(period == .daily ? "wake date" : "week ending")
            }
            Spacer(minLength: 0)
            Button { changeDay(period == .daily ? 1 : 7) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(Calendar.current.isDateInToday(date))
                .accessibilityLabel(period == .daily ? "next sleep date" : "next sleep week")
                .accessibilityIdentifier("sleep-next")
        }
    }

    private func nightSummary(_ night: SleepNight) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("time asleep").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    Text(sleepDuration(night.asleepDuration)).font(VitalsStyle.live).minimumScaleFactor(0.6).lineLimit(1)
                        .accessibilityIdentifier("sleep-duration")
                }
                Spacer()
                Image(systemName: "moon.fill").font(.system(size: 32)).foregroundStyle(SleepStage.deep.tint)
            }
            Text("\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))")
                .font(VitalsStyle.heading)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                ForEach([SleepStage.deep, .rem, .core, .awake], id: \.self) { stage in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(stage.label, systemImage: "circle.fill").font(VitalsStyle.caption).foregroundStyle(stage.tint)
                        Text(night.hasStages || night.duration(stage) > 0 ? sleepDuration(night.duration(stage)) : "—")
                            .font(VitalsStyle.entry).monospacedDigit()
                        if stage != .awake && night.hasStages {
                            Text("\(Int((night.duration(stage) / night.asleepDuration * 100).rounded()))% of sleep")
                                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        } else if stage == .awake && night.awakeCount > 0 {
                            Text("\(night.awakeCount) recorded \(night.awakeCount == 1 ? "awakening" : "awakenings")").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        }
                    }
                }
            }
            if !night.hasStages {
                Text("this recording includes sleep duration, but no stage breakdown.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        }
        .sleepCard()
    }

    private func stageChart(_ night: SleepNight) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "through the night", detail: "touch to explore")
            Chart {
                ForEach(night.segments) { segment in
                    RectangleMark(xStart: .value("start", segment.start), xEnd: .value("end", segment.end),
                                  y: .value("stage", segment.stage.label), height: .ratio(0.8))
                        .foregroundStyle(segment.stage.tint).cornerRadius(3)
                        .accessibilityLabel("\(segment.stage.label), \(sleepDuration(segment.duration))")
                }
                if let selectedTime {
                    RuleMark(x: .value("selected time", selectedTime)).foregroundStyle(VitalsStyle.text.opacity(0.6))
                }
            }
            .chartYScale(domain: (night.hasStages ? [SleepStage.awake, .rem, .core, .deep] + (night.duration(.asleep) > 0 ? [.asleep] : []) : [.awake, .asleep]).map(\.label))
            .chartXScale(domain: night.start...night.end)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisValueLabel(format: .dateTime.hour().minute()) } }
            .chartXSelection(value: $selectedTime)
            .frame(height: 170)
            .accessibilityIdentifier("sleep-stages-chart")
            if let time = selectedTime {
                Text("\(time.formatted(date: .omitted, time: .shortened)) · \(night.stage(at: time)?.label ?? "no measurement")")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        }.sleepCard()
    }

    private func weeklyCharts(_ data: SleepMeasurements, week: [SleepNight]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(weekDomain.lowerBound.formatted(.dateTime.month(.abbreviated).day())) – \(date.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(VitalsStyle.heading).accessibilityIdentifier("sleep-week-range")
                Text("\(week.count) \(week.count == 1 ? "night" : "nights") recorded")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("time asleep").font(VitalsStyle.heading)
                Chart {
                    ForEach(week) { night in
                        ForEach([SleepStage.deep, .core, .rem, .asleep], id: \.self) { stage in
                            if night.duration(stage) > 0 {
                                BarMark(x: .value("date", night.day, unit: .day), y: .value("hours", night.duration(stage) / 3_600))
                                    .foregroundStyle(stage.tint)
                                    .accessibilityLabel("\(night.day.formatted(date: .abbreviated, time: .omitted)), \(stage.label), \(sleepDuration(night.duration(stage)))")
                            }
                        }
                    }
                }
                .chartXScale(domain: weekDomain)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) } }
                .chartYAxisLabel("hours").frame(height: 150)
            }.sleepCard()
            VStack(alignment: .leading, spacing: 12) {
                Text("sleep schedule").font(VitalsStyle.heading)
                Text("bedtime → wake time").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                Chart(week) { night in
                    RectangleMark(x: .value("date", night.day, unit: .day),
                                  yStart: .value("bedtime", clockHour(night.start, relativeTo: night.day)),
                                  yEnd: .value("wake time", clockHour(night.end, relativeTo: night.day)), width: .ratio(0.5))
                        .foregroundStyle(VitalsStyle.accent).cornerRadius(4)
                        .accessibilityLabel("\(night.day.formatted(date: .abbreviated, time: .omitted)), \(night.start.formatted(date: .omitted, time: .shortened)) to \(night.end.formatted(date: .omitted, time: .shortened))")
                }
                .chartXScale(domain: weekDomain)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) } }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let hour = value.as(Double.self) { Text(String(format: "%02d:00", (Int(hour) % 24 + 24) % 24)) } }
                    }
                }.frame(height: 160)
            }.sleepCard()
            weeklyRate("sleep heart rate", week: week, values: data.heartRate, unit: "bpm", color: VitalsStyle.heart)
            weeklyRate("breathing rate", week: week, values: data.respiratoryRate, unit: "breaths/min", color: .cyan)
        }
    }

    private func weeklyRate(_ title: String, week: [SleepNight], values: [SleepReading], unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(VitalsStyle.heading)
            if week.contains(where: { $0.average(values) != nil }) {
                Chart(week) { night in
                    if let value = night.average(values) {
                        PointMark(x: .value("date", night.day, unit: .day), y: .value(unit, value))
                            .foregroundStyle(color).symbolSize(40)
                            .annotation(position: .top) { Text(value.formatted(.number.precision(.fractionLength(0...1)))).font(VitalsStyle.caption) }
                    }
                }
                .chartXScale(domain: weekDomain)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) } }
                .chartYScale(domain: sleepRateDomain(week.compactMap { $0.average(values) }))
                .chartYAxisLabel(unit).frame(height: 130)
            } else { Text("no recorded measurements").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary) }
        }.sleepCard()
    }

    private var weekDomain: ClosedRange<Date> {
        Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: date))!...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))!
    }

    private func clockHour(_ time: Date, relativeTo day: Date) -> Double {
        let calendar = Calendar.current
        let offset = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: time)).day ?? 0
        return Double(offset * 24 + calendar.component(.hour, from: time)) + Double(calendar.component(.minute, from: time)) / 60
    }

    private func changeDay(_ amount: Int) {
        date = min(Calendar.current.date(byAdding: .day, value: amount, to: date)!,
                   Calendar.current.startOfDay(for: .now))
    }
    private func reload(force: Bool = false) async {
        helio.sync(force: force)
        if requested { await health.load(endingOn: date) }
    }

}

private enum SleepPeriod: String, CaseIterable {
    case daily, weekly
}

private struct SleepRateCard: View {
    let title: String
    let unit: String
    let color: Color
    let night: SleepNight
    let values: [SleepReading]
    @State private var selectedTime: Date?

    var body: some View {
        let points = night.readings(values)
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(VitalsStyle.heading).foregroundStyle(color)
            if let average = night.average(values) {
                HStack(alignment: .firstTextBaseline) {
                    Text(average.formatted(.number.precision(.fractionLength(0...1)))).font(VitalsStyle.clock)
                    Text("\(unit) · asleep average").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
            }
            if points.isEmpty {
                Text("no measurements recorded for this sleep period.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        // Samples, not an invented continuous waveform across unrecorded intervals.
                        PointMark(x: .value("time", point.date), y: .value(unit, point.value)).symbolSize(12).foregroundStyle(color)
                    }
                    if let selectedTime { RuleMark(x: .value("selected time", selectedTime)).foregroundStyle(VitalsStyle.secondary) }
                }
                .chartXScale(domain: night.start...night.end)
                .chartYScale(domain: sleepRateDomain(points.map(\.value)))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisValueLabel(format: .dateTime.hour().minute()) } }
                .chartXSelection(value: $selectedTime).frame(height: 130)
                if let time = selectedTime, let point = points.min(by: { abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time)) }) {
                    Text("\(point.date.formatted(date: .omitted, time: .shortened)) · \(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                        .font(VitalsStyle.caption)
                }
            }
        }.sleepCard()
    }
}

private extension SleepStage {
    var tint: Color {
        switch self {
        case .awake: VitalsStyle.heart
        case .rem: Color(red: 0.32, green: 0.82, blue: 0.73)
        case .core: VitalsStyle.accent
        case .deep: Color(red: 0.68, green: 0.55, blue: 1)
        case .asleep: VitalsStyle.secondary
        }
    }
}

private extension View {
    func sleepCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(VitalsStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private func sleepDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

/// A nonzero ascending range also handles a week of identical values without an inverted auto axis.
private func sleepRateDomain(_ values: [Double]) -> ClosedRange<Double> {
    let low = values.min() ?? 0
    let high = values.max() ?? 1
    let padding = max(1, (high - low) * 0.15)
    return max(0, low - padding)...(high + padding)
}
