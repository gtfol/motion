import SwiftUI

/// The workout screen. Heart rate stays in a compact strip at the top so the set log is always reachable,
/// and the rest clock sits above the tab bar within thumb reach.
struct ActiveSessionView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    let session: WorkoutSession
    let finish: (Date) -> Void
    @State private var picking = false
    @State private var reordering = false
    @State private var confirmDiscard = false
    @State private var namingRoutine = false
    @State private var routineName = ""

    var body: some View {
        VStack(spacing: 0) {
            SessionClock(session: session)
                .padding(.horizontal, VitalsStyle.gutter)
                .padding(.top, 4)
            HeartRatePanel(session: session)
                .padding(.horizontal, VitalsStyle.gutter)
                .padding(.vertical, 8)
            Hairline()
            if session.activity.logsSets {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        ForEach(session.orderedExercises) { entry in
                            ExerciseCard(entry: entry)
                        }
                        if session.exercises.isEmpty {
                            Text("add your first exercise. sets you log are saved on this iPhone as you go.")
                                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        }
                        Button { picking = true } label: { Text("add exercise").frame(maxWidth: .infinity) }
                            .vitalsPrimaryAction()
                            .accessibilityIdentifier("add-exercise")
                        if let message = coordinator.message {
                            Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                    .padding(.horizontal, VitalsStyle.gutter)
                    .padding(.vertical, 20)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                HeartRateOnlyBody(session: session)
            }
            RestBar(session: session)
        }
        .vitalsTitle(session.routineName ?? session.activity.label)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if session.activity.logsSets {
                        Button("reorder exercises") { reordering = true }.disabled(session.exercises.count < 2)
                        Button("save as routine") { routineName = session.routineName ?? ""; namingRoutine = true }
                            .disabled(session.exercises.isEmpty)
                    }
                    Button("discard workout", role: .destructive) { confirmDiscard = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("workout options")
            }
            .quietBackground()
            ToolbarItem(placement: .topBarTrailing) {
                Button { Keyboard.dismiss(); finish(.now) } label: { Text("finish").font(VitalsStyle.heading).frame(minHeight: 44) }
                    .accessibilityHint("review and save this workout")
                    .accessibilityIdentifier("finish-workout")
            }
            .quietBackground()
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("done") { Keyboard.dismiss() }.accessibilityIdentifier("keyboard-done")
            }
        }
        .sheet(isPresented: $picking) {
            ExercisePicker { exercise in coordinator.add(exercise) }
        }
        .sheet(isPresented: $reordering) { ReorderExercises(session: session) }
        .confirmationDialog("discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("discard workout", role: .destructive) { coordinator.discard(id: session.id) }
            Button("keep workout", role: .cancel) {}
        } message: {
            Text("its sets and heart rate are deleted from this iPhone.")
        }
        .alert("save as routine", isPresented: $namingRoutine) {
            TextField("name", text: $routineName)
            Button("save") { coordinator.perform { try coordinator.store.saveAsRoutine(session, name: routineName) } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("the routine keeps these exercises and set counts. changing this workout later won’t change it.")
        }
    }
}

struct SessionClock: View {
    let session: WorkoutSession

    var body: some View {
        TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
            let elapsed = ClockText.duration(context.date.timeIntervalSince(session.startedAt))
            HStack(alignment: .firstTextBaseline) {
                Text("started \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                Spacer()
                Text(elapsed).font(VitalsStyle.clock).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("workout time \(elapsed)")
        }
    }
}

/// Rest is computed from the completion time, so it stays right after the screen locks or vitals relaunches.
/// There are no notifications; the clock is in the app only.
struct RestBar: View {
    @Environment(SessionCoordinator.self) private var coordinator
    let session: WorkoutSession

    var body: some View {
        if let timer = session.restTimer {
            VStack(spacing: 0) {
                Hairline()
                TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                    let over = timer.isOver(at: context.date)
                    let elapsed = ClockText.duration(timer.elapsed(at: context.date))
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(over ? "rest done" : "rest").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                            Text("\(elapsed) / \(ClockText.duration(timer.target))").font(VitalsStyle.clock).monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(over ? "rest done, \(elapsed) since the last set"
                                            : "rest \(elapsed) of \(ClockText.duration(timer.target))")
                        Spacer()
                        TextAction("+30s") { coordinator.extendRest() }.accessibilityLabel("add 30 seconds of rest")
                            .accessibilityIdentifier("rest-extend")
                        TextAction(over ? "done" : "skip") { coordinator.skipRest() }.accessibilityIdentifier("rest-skip")
                    }
                }
                .padding(.horizontal, VitalsStyle.gutter)
                .padding(.vertical, 6)
            }
            .background(VitalsStyle.canvas)
        }
    }
}

/// Running, walking, cycling, and other sessions: time and heart rate only in v1.
private struct HeartRateOnlyBody: View {
    @Environment(SessionCoordinator.self) private var coordinator
    let session: WorkoutSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelineView(.periodic(from: session.startedAt, by: 5)) { context in
                    HeartRateChart(points: coordinator.liveSamples, start: session.startedAt, end: context.date, compact: false)
                        .frame(height: 180)
                }
                HeartRateStatsText(stats: coordinator.liveStats, gaps: HeartRateSeries.gaps(in: coordinator.liveSamples))
                Text("\(session.activity.label) records time and heart rate. sets aren’t logged for this activity.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                if let message = coordinator.message {
                    Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
            }
            .padding(.horizontal, VitalsStyle.gutter)
            .padding(.vertical, 20)
        }
    }
}

private struct ReorderExercises: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let session: WorkoutSession

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.orderedExercises) { entry in
                    Text(entry.name).listRowBackground(Color.clear).listRowSeparatorTint(VitalsStyle.divider)
                }
                .onMove { source, destination in
                    coordinator.perform { try coordinator.store.moveExercises(in: session, from: source, to: destination) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .vitalsScreen()
            .vitalsTitle("reorder")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("done") { dismiss() } }
            }
        }
        .presentationBackground(VitalsStyle.canvas)
    }
}
