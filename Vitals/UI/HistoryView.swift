import SwiftData
import SwiftUI

struct SessionRoute: Hashable { let id: UUID }
struct ExerciseRoute: Hashable { let id: UUID; let name: String }

struct HistoryTab: View {
    private enum Page: String, CaseIterable, Identifiable {
        case sessions, exercises
        var id: String { rawValue }
    }

    @State private var page: Page = .sessions
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    ForEach(Page.allCases) { item in
                        Button { page = item } label: {
                            Text(item.rawValue).font(VitalsStyle.caption)
                                .foregroundStyle(page == item ? VitalsStyle.text : VitalsStyle.secondary)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                        .accessibilityIdentifier("history-\(item.rawValue)")
                    }
                    Spacer()
                }
                .padding(.horizontal, VitalsStyle.gutter)
                switch page {
                case .sessions: SessionList()
                case .exercises: ExerciseList()
                }
            }
            .vitalsScreen()
            .vitalsTitle("history")
            .navigationDestination(for: SessionRoute.self) { route in SessionDetailView(sessionID: route.id) }
            .navigationDestination(for: ExerciseRoute.self) { route in ExerciseHistoryView(exerciseID: route.id, name: route.name) }
        }
    }
}

private struct SessionList: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Query(filter: #Predicate<WorkoutSession> { $0.stateRaw == "completed" }, sort: \WorkoutSession.startedAt, order: .reverse)
    private var sessions: [WorkoutSession]

    var body: some View {
        ScrollView {
            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("no finished workouts yet").font(VitalsStyle.heading)
                    Text("finish a workout in train and it appears here with its sets and heart rate.")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(VitalsStyle.gutter)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions) { session in
                        NavigationLink(value: SessionRoute(id: session.id)) { SessionRow(session: session, unit: coordinator.unit) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session-row")
                        Hairline()
                    }
                }
                .padding(.horizontal, VitalsStyle.gutter)
            }
        }
    }
}

private struct SessionRow: View {
    let session: WorkoutSession
    let unit: WeightUnit

    var body: some View {
        let logs = session.exerciseLogs
        let sets = logs.flatMap(\.sets)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                Spacer()
                Text(ClockText.summary((session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)))
                    .monospacedDigit()
            }
            Text(lines(logs: logs, sets: sets).joined(separator: " · "))
                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            if let average = session.heartRateAverage, let maximum = session.heartRateMaximum {
                Text("heart rate avg \(average) · max \(maximum)").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            if session.healthState != .saved {
                Text("Apple Health: \(session.healthState.label)").font(VitalsStyle.caption)
                    .foregroundStyle(session.healthState == .failed ? VitalsStyle.caution : VitalsStyle.secondary)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func lines(logs: [ExerciseLog], sets: [SetEntry]) -> [String] {
        var parts = [session.routineName ?? session.activity.label]
        if session.activity.logsSets {
            let exercises = logs.filter { $0.sets.contains(where: \.completed) }.count
            let working = sets.filter(\.countsAsWork).count
            parts.append("\(exercises) \(exercises == 1 ? "exercise" : "exercises")")
            parts.append("\(working) working \(working == 1 ? "set" : "sets")")
            let volume = TrainingMath.volumeKilograms(sets)
            if volume > 0 { parts.append(LoadText.volume(volume, unit: unit)) }
        }
        return parts
    }
}

struct SessionDetailView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [WorkoutSession]
    @State private var confirmDelete = false
    @State private var naming = false
    @State private var routineName = ""
    @State private var picking = false

    init(sessionID: UUID) {
        _sessions = Query(filter: #Predicate<WorkoutSession> { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session = sessions.first, session.state == .completed {
                detail(session)
            } else {
                Text("this workout isn’t available.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .vitalsScreen()
        .vitalsTitle("workout")
    }

    private func detail(_ session: WorkoutSession) -> some View {
        let unit = coordinator.unit
        let end = session.endedAt ?? session.startedAt
        let summary = coordinator.summary(for: session, endingAt: end)
        return ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if let summary { SummaryDetails(summary: summary, activity: session.activity, unit: unit) }
                if !session.heartRateSamples.isEmpty {
                    HeartRateChart(points: session.heartRatePoints, start: session.startedAt, end: end, compact: false)
                        .frame(height: 160)
                }
                if session.activity.logsSets {
                    VStack(alignment: .leading, spacing: 28) {
                        SectionHeading(title: "sets", detail: "edits update volume and bests")
                        ForEach(session.orderedExercises) { entry in ExerciseCard(entry: entry) }
                        TextAction("add exercise") { picking = true }
                    }
                }
                SaveStateView(session: session)
                VStack(alignment: .leading, spacing: 0) {
                    if session.activity.logsSets, !session.exercises.isEmpty {
                        TextAction("save as routine") { routineName = session.routineName ?? ""; naming = true }
                    }
                    TextAction("delete workout", role: .destructive, secondary: true) { confirmDelete = true }
                }
            }
            .padding(VitalsStyle.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("done") { Keyboard.dismiss() }.accessibilityIdentifier("keyboard-done")
            }
        }
        .sheet(isPresented: $picking) {
            ExercisePicker { exercise in coordinator.perform { try coordinator.store.addExercise(exercise, to: session) } }
        }
        .alert("save as routine", isPresented: $naming) {
            TextField("name", text: $routineName)
            Button("save") { coordinator.perform { try coordinator.store.saveAsRoutine(session, name: routineName) } }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog("delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("delete workout", role: .destructive) {
                let id = session.id
                dismiss()
                coordinator.discard(id: id)
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(session.healthState == .saved
                 ? "its sets and heart rate are deleted from vitals. the copy in Apple Health stays; delete it in the Health app if you want."
                 : "its sets and heart rate are deleted from vitals.")
        }
    }
}

private struct ExerciseList: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(exercises) { exercise in
                    NavigationLink(value: ExerciseRoute(id: exercise.id, name: exercise.name)) {
                        HStack {
                            Text(exercise.name)
                            Spacer()
                            Text([exercise.category, exercise.isBodyweight ? "bodyweight" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("exercise-\(exercise.name)")
                    Hairline()
                }
                TextAction("new exercise") { name = ""; creating = true }
            }
            .padding(.horizontal, VitalsStyle.gutter)
        }
        .alert("new exercise", isPresented: $creating) {
            TextField("name", text: $name)
            Button("create") { coordinator.perform { try coordinator.store.createExercise(name: name) } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("add a muscle or category and bodyweight details from the exercise page.")
        }
    }
}

/// Past sets and bests for one exercise, from finished sessions only. Works for exercises removed from the catalog.
struct ExerciseHistoryView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let exerciseID: UUID
    let name: String
    var closable = false
    @Query private var matches: [Exercise]
    @State private var history: ExerciseHistory?
    @State private var editing = false

    init(exerciseID: UUID, name: String, closable: Bool = false) {
        self.exerciseID = exerciseID; self.name = name; self.closable = closable
        _matches = Query(filter: #Predicate<Exercise> { $0.id == exerciseID })
    }

    var body: some View {
        let exercise = matches.first
        let unit = coordinator.unit
        let bodyweight = exercise?.isBodyweight ?? false
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise?.name ?? name).font(VitalsStyle.heading)
                    let details = [exercise?.category, bodyweight ? "bodyweight, load is added weight" : nil,
                                   exercise == nil ? "removed from the catalog" : nil].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    }
                }
                if let history {
                    bests(history, unit: unit, bodyweight: bodyweight)
                    if history.rows.isEmpty {
                        Text("no finished sessions with this exercise yet.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    }
                    ForEach(history.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.startedAt.formatted(date: .abbreviated, time: .shortened)).font(VitalsStyle.caption)
                                .foregroundStyle(VitalsStyle.secondary)
                            Text(row.sets.filter(\.completed).map { set in
                                let text = LoadText.set(reps: set.reps, kilograms: set.loadKilograms, unit: unit, isBodyweight: bodyweight)
                                return set.kind == .warmup ? "w \(text)" : text
                            }.joined(separator: " · ").nonEmpty ?? "no completed sets")
                            ForEach(row.hits) { hit in
                                Text("new best · \(hit.kind.label) \(LoadText.load(hit.value, unit: unit, isBodyweight: false)), was \(LoadText.load(hit.previous, unit: unit, isBodyweight: false))")
                                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        Hairline()
                    }
                }
            }
            .padding(VitalsStyle.gutter)
        }
        .vitalsScreen()
        .vitalsTitle("exercise")
        .toolbar {
            if closable {
                ToolbarItem(placement: .cancellationAction) { Button("close") { dismiss() } }
            }
            if exercise != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("edit") { editing = true } }
            }
        }
        .task { reload() }
        .sheet(isPresented: $editing, onDismiss: reload) {
            if let exercise { ExerciseEditor(exercise: exercise) }
        }
    }

    private func reload() {
        history = try? coordinator.store.history(for: exerciseID)
    }

    @ViewBuilder private func bests(_ history: ExerciseHistory, unit: WeightUnit, bodyweight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(title: "bests")
            if bodyweight {
                Text(history.mostBodyweightReps.map { "most reps at bodyweight: \($0)" } ?? "no bodyweight sets yet")
                Text("records for bodyweight movements aren’t compared yet, including sets with added load.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            } else if let heaviest = history.allTime.heaviestLoad {
                Text("heaviest \(LoadText.load(heaviest, unit: unit, isBodyweight: false))")
                if let estimate = history.allTime.estimatedOneRepMax {
                    Text("est. 1RM \(LoadText.load(estimate, unit: unit, isBodyweight: false))")
                    Text("an Epley estimate from 1–10 reps, not a tested max.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
            } else {
                Text("no weighted working sets yet.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        }
    }
}

private struct ExerciseEditor: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let exercise: Exercise
    @State private var name = ""
    @State private var category = ""
    @State private var bodyweight = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("name", text: $name)
                    TextField("muscle or category (optional)", text: $category)
                    Toggle("bodyweight movement", isOn: $bodyweight).tint(VitalsStyle.secondary)
                } footer: {
                    Text("for bodyweight movements, the load you enter is added weight. they’re tracked but not compared for records yet.")
                        .font(VitalsStyle.caption)
                }
                .listRowBackground(VitalsStyle.surface)
                Section {
                    Button("delete exercise", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("removes it from the catalog and from routines. past sets keep this name.").font(VitalsStyle.caption)
                }
                .listRowBackground(VitalsStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .vitalsScreen()
            .vitalsTitle("edit exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        coordinator.perform { try coordinator.store.update(exercise, name: name, category: category, isBodyweight: bodyweight) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { name = exercise.name; category = exercise.category ?? ""; bodyweight = exercise.isBodyweight }
            .confirmationDialog("delete \(exercise.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("delete exercise", role: .destructive) {
                    let target = exercise
                    dismiss()
                    coordinator.perform { try coordinator.store.delete(target) }
                }
                Button("cancel", role: .cancel) {}
            }
        }
        .presentationBackground(VitalsStyle.canvas)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
