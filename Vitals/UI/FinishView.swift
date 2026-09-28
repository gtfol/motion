import SwiftUI

/// Confirms the summary, saves locally, then exports to Apple Health, showing each result separately.
struct FinishView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionCoordinator.self) private var coordinator
    let request: FinishRequest
    let onDiscard: () -> Void
    @State private var summary: WorkoutSummary?
    @State private var saving = false
    @State private var confirmDiscard = false

    private var session: WorkoutSession { request.session }

    var body: some View {
        NavigationStack {
            ScrollView {
                if session.isDeleted || session.modelContext == nil {
                    Text("this workout was deleted.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary).padding(VitalsStyle.gutter)
                } else {
                    content
                }
            }
            .vitalsScreen()
            .vitalsTitle(session.modelContext != nil && session.state == .completed ? "workout saved" : "finish workout")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if session.modelContext != nil, session.state == .completed {
                        Button("done") { dismiss() }.accessibilityIdentifier("finish-done")
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .task { summary = coordinator.summary(for: session, endingAt: request.end) }
        }
        .presentationBackground(VitalsStyle.canvas)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let summary {
                SummaryDetails(summary: summary, activity: session.activity, unit: coordinator.unit)
            }
            if session.state == .completed {
                SaveStateView(session: session)
            } else {
                if let summary, summary.incompleteSets > 0 {
                    Text("\(summary.incompleteSets) \(summary.incompleteSets == 1 ? "set isn’t" : "sets aren’t") marked done and won’t count toward volume or records. they stay in the log.")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
                if session.activity.logsSets, let summary, !summary.hasCompletedSets {
                    Text("no completed sets. this saves as a heart-rate workout.")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
                VStack(spacing: 4) {
                    Button {
                        saving = true
                        Task {
                            await coordinator.finish(session, at: request.end)
                            saving = false
                        }
                    } label: {
                        HStack { if saving { ProgressView().tint(VitalsStyle.canvas) }; Text(saving ? "saving…" : "save workout") }
                            .frame(maxWidth: .infinity)
                    }
                    .vitalsPrimaryAction()
                    .disabled(saving)
                    .accessibilityIdentifier("save-workout")
                    TextAction("keep training", secondary: true) { dismiss() }.disabled(saving)
                    TextAction("discard workout", role: .destructive, secondary: true) { confirmDiscard = true }.disabled(saving)
                }
            }
        }
        .padding(VitalsStyle.gutter)
        .confirmationDialog("discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("discard workout", role: .destructive) { onDiscard() }
            Button("keep workout", role: .cancel) {}
        } message: {
            Text("its sets and heart rate are deleted from this iPhone.")
        }
    }
}

struct SummaryDetails: View {
    let summary: WorkoutSummary
    let activity: ActivityKind
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ClockText.summary(summary.duration)).font(VitalsStyle.clock)
                Text("\(activity.label) · \(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(summary.endedAt.formatted(date: .omitted, time: .shortened))")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            if activity.logsSets {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading(title: "lifting")
                    row("exercises", "\(summary.exerciseCount)")
                    row("working sets done", "\(summary.completedWorkingSets)")
                    if summary.completedWarmupSets > 0 { row("warm-up sets", "\(summary.completedWarmupSets)") }
                    row("volume", LoadText.volume(summary.volumeKilograms, unit: unit))
                    Text("volume is reps × the load you entered, over completed working sets. warm-ups and body weight aren’t counted.")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
                if !summary.records.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "new bests")
                        ForEach(summary.records) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name)
                                ForEach(record.hits) { hit in
                                    Text("\(hit.kind.label) \(LoadText.load(hit.value, unit: unit, isBodyweight: false)), was \(LoadText.load(hit.previous, unit: unit, isBodyweight: false))")
                                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                                }
                            }
                        }
                        Text("est. 1RM is an Epley estimate from 1–10 reps, not a tested max.")
                            .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: "heart rate")
                if let heartRate = summary.heartRate {
                    HeartRateStatsText(stats: heartRate.stats, gaps: heartRate.gaps)
                } else {
                    Text("no heart rate was recorded for this workout.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(VitalsStyle.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Local save and Apple Health export are separate results.
struct SaveStateView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    let session: WorkoutSession

    var body: some View {
        let exporting = coordinator.exporting.contains(session.id)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "saved")
            HStack {
                Text("on this iPhone").foregroundStyle(VitalsStyle.secondary)
                Spacer()
                Text(session.localSavedAt.map { "saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "saved")
            }
            .accessibilityElement(children: .combine)
            HStack {
                Text("Apple Health").foregroundStyle(VitalsStyle.secondary)
                Spacer()
                if exporting { ProgressView().controlSize(.small) }
                Text(exporting ? "saving…" : session.healthState.label)
                    .foregroundStyle(session.healthState == .failed && !exporting ? VitalsStyle.caution : VitalsStyle.text)
            }
            .accessibilityElement(children: .combine)
            if let message = session.healthMessage, !exporting {
                Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            if session.healthState.canRetry, !exporting {
                TextAction(session.healthState == .pending ? "save to Apple Health" : "retry Apple Health") {
                    Task { await coordinator.exportToHealth(session) }
                }
            }
        }
    }
}
