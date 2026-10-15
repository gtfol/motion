import Charts
import SwiftUI

struct SleepTab: View {
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sleep-health-requested") private var requested = false
    @State private var health = SleepHealthStore()
    @State private var date = Calendar.current.startOfDay(for: Date.now)
    @State private var selectedTime: Date?
    @State private var connecting = false

    private var night: SleepNight? { health.nights.first { Calendar.current.isDate($0.day, inSameDayAs: date) } }
    private var week: [SleepNight] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: date)!
        return health.nights.filter { $0.day >= start && $0.day <= date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    datePicker
                    if !requested {
                        connection
                    } else {
                        if health.sources.count > 1 {
                            Picker("sleep source", selection: $health.selectedSource) {
                                ForEach(health.sources) { Text($0.name).tag($0.id) }
                            }
                            .tint(VitalsStyle.accent)
                            .onChange(of: health.selectedSource) { old, _ in
                                if !old.isEmpty && !health.loading { Task { await reload() } }
                            }
                        }
                        if health.loading {
                            ProgressView("reading Apple Health…").frame(maxWidth: .infinity)
                        } else if let night {
                            nightSummary(night)
                            stageChart(night)
                            SleepRateCard(title: "sleep heart rate", unit: "bpm", color: VitalsStyle.heart,
                                          night: night, values: health.heartRate, source: health.heartSource)
                            SleepRateCard(title: "breathing rate", unit: "breaths/min", color: .cyan,
                                          night: night, values: health.respiratoryRate, source: health.respiratorySource)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("no sleep measurements for this date", systemImage: "moon.zzz").font(VitalsStyle.heading)
                                Text("check another date, or allow Motion to read sleep in Apple Health. your recorder must share measurements with Health first.")
                                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                                TextAction("refresh measurements") { Task { await reload() } }
                            }
                            .accessibilityIdentifier("sleep-empty")
                        }
                        if let message = health.message {
                            Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                        }
                        if !week.isEmpty && !health.loading { weeklyCharts }
                        Text("from Apple Health · stays on this iPhone\nshows the longest sleep period ending on each date. missing records stay blank.")
                            .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    }
                }
                .padding(VitalsStyle.gutter)
            }
            .refreshable { await reload() }
            .vitalsScreen()
            .vitalsTitle("sleep")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    InfoButton(title: "sleep & breathing", paragraphs: [
                        "Motion reads recorded sleep stages, heart rate and respiratory rate from Apple Health. it doesn’t record sleep directly from your strap.",
                        "if Zepp shares a measurement with Apple Health, Motion can display it. data available only inside Zepp won’t appear here.",
                        "breathing rate is breaths per minute, not a breath-by-breath waveform. Motion doesn’t estimate hypopnea, diagnose breathing problems, or reproduce Zepp’s sleep scores.",
                        "sleep totals exclude awake time. nightly averages use samples recorded during measured sleep. choose one sleep source to avoid counting overlapping recordings twice."
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
            Button { changeDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("previous sleep date").accessibilityIdentifier("sleep-previous")
            Spacer(minLength: 0)
            DatePicker("wake date", selection: $date, in: ...Date.now, displayedComponents: .date)
                .labelsHidden().accessibilityLabel("wake date")
            Spacer(minLength: 0)
            Button { changeDay(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(Calendar.current.isDateInToday(date)).accessibilityLabel("next sleep date")
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "moon.stars.fill").font(.system(size: 42)).foregroundStyle(SleepStage.deep.tint)
            Text("your night, in motion").font(VitalsStyle.clock)
            Text("see your sleep stages, overnight heart rate and breathing rate together, with a week of trends.")
            Text("connect Apple Health to read measurements from your sleep recorder. availability depends on what it shares with Health.")
                .foregroundStyle(VitalsStyle.secondary)
            Button(connecting ? "connecting…" : "connect Apple Health") { Task { await connect() } }
                .vitalsPrimaryAction().disabled(connecting || !health.available)
                .accessibilityIdentifier("sleep-connect")
            if !health.available { Text("Apple Health isn’t available on this device.") }
            if let message = health.message { Text(message).foregroundStyle(VitalsStyle.caution) }
        }
        .accessibilityIdentifier("sleep-connect-intro")
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
            if let source = health.sources.first(where: { $0.id == health.selectedSource }) {
                Text(source.name).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
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

    private var weeklyCharts: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: "last 7 days", detail: "ending \(date.formatted(.dateTime.month(.abbreviated).day()))")
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
            weeklyRate("sleep heart rate", values: health.heartRate, unit: "bpm", color: VitalsStyle.heart)
            weeklyRate("breathing rate", values: health.respiratoryRate, unit: "breaths/min", color: .cyan)
        }
    }

    private func weeklyRate(_ title: String, values: [SleepReading], unit: String, color: Color) -> some View {
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
            } else { Text("no measurements shared with Apple Health").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary) }
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

    private func changeDay(_ amount: Int) { date = Calendar.current.date(byAdding: .day, value: amount, to: date)! }
    private func reload() async { if requested { await health.load(endingOn: date) } }
    private func connect() async {
        connecting = true
        defer { connecting = false }
        if await health.connect() { requested = true; await reload() }
    }
}

private struct SleepRateCard: View {
    let title: String
    let unit: String
    let color: Color
    let night: SleepNight
    let values: [SleepReading]
    let source: String?
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
                Text("no measurements shared with Apple Health for this sleep period.")
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
                if let source { Text(source).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary) }
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
