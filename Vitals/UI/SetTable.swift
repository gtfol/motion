import SwiftUI

/// One exercise in a session: last time's sets, prior bests, and the editable set table.
/// Used for the active workout and for correcting finished ones in history.
struct ExerciseCard: View {
    @Environment(SessionCoordinator.self) private var coordinator
    let entry: SessionExercise
    @State private var previous: [SetEntry]?
    @State private var prior = ExerciseBests.none
    @State private var loaded = false
    @State private var showingHistory = false
    @State private var confirmRemove = false
    @ScaledMetric(relativeTo: .title3) private var scaledLoadWidth: CGFloat = 76
    @ScaledMetric(relativeTo: .title3) private var scaledRepsWidth: CGFloat = 56
    @Environment(\.dynamicTypeSize) private var typeSize

    // At accessibility sizes the "last" column is dropped (it stays in the line above the table) and fields stop
    // growing, so a row still fits a narrow iPhone.
    private var compact: Bool { typeSize.isAccessibilitySize }
    private var loadWidth: CGFloat { compact ? min(scaledLoadWidth, 132) : scaledLoadWidth }
    private var repsWidth: CGFloat { compact ? min(scaledRepsWidth, 96) : scaledRepsWidth }

    var body: some View {
        let unit = coordinator.unit
        let sets = entry.orderedSets
        let entries = sets.map(\.entry)
        let hits = PersonalRecords.hits(in: entries, isBodyweight: entry.isBodyweight, prior: prior)
        let matches = PreviousPerformance.matches(current: entries, previous: previous ?? [])
        let labels = Self.labels(for: sets)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(VitalsStyle.heading).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                menu
            }
            ForEach(context(unit: unit), id: \.self) { line in
                Text(line).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            if !sets.isEmpty {
                HStack(spacing: 8) {
                    Text("set").frame(width: 36)
                    if compact { Spacer(minLength: 0) } else { Text("last").frame(maxWidth: .infinity, alignment: .leading) }
                    Text(unit.symbol).frame(width: loadWidth)
                    Text("reps").frame(width: repsWidth)
                    Text("done").frame(width: 44)
                }
                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                .padding(.top, 6)
                .accessibilityHidden(true)
            }
            ForEach(sets) { set in
                SetRow(set: set, exercise: entry.name, label: labels[set.id] ?? "", previous: matches[set.id],
                       hits: hits.filter { $0.setID == set.id }, isBodyweight: entry.isBodyweight, unit: unit,
                       loadWidth: loadWidth, repsWidth: repsWidth, showsPrevious: !compact)
            }
            TextAction("add set") { coordinator.addSet(to: entry) }
                .accessibilityLabel("add set to \(entry.name)")
                .accessibilityIdentifier("add-set-\(entry.name)")
        }
        .task(id: entry.id) { load() }
        .sheet(isPresented: $showingHistory) {
            NavigationStack { ExerciseHistoryView(exerciseID: entry.exerciseID, name: entry.name, closable: true) }
                .presentationBackground(VitalsStyle.canvas)
        }
        .confirmationDialog("remove \(entry.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("remove exercise", role: .destructive) { coordinator.perform { try coordinator.store.remove(entry) } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("its sets in this workout are deleted.")
        }
    }

    private var menu: some View {
        Menu {
            Button("exercise history") { showingHistory = true }
            if let session = entry.session {
                let ordered = session.orderedExercises
                if let index = ordered.firstIndex(where: { $0.id == entry.id }) {
                    Button("move up") { move(session, from: index, to: index - 1) }.disabled(index == 0)
                    Button("move down") { move(session, from: index, to: index + 2) }.disabled(index == ordered.count - 1)
                }
            }
            Button("remove exercise", role: .destructive) {
                if entry.sets.isEmpty { coordinator.perform { try coordinator.store.remove(entry) } } else { confirmRemove = true }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("\(entry.name) options")
    }

    private func move(_ session: WorkoutSession, from index: Int, to destination: Int) {
        coordinator.perform { try coordinator.store.moveExercises(in: session, from: IndexSet(integer: index), to: destination) }
    }

    private func context(unit: WeightUnit) -> [String] {
        var lines: [String] = []
        if let targetSets = entry.targetSets {
            lines.append(entry.targetReps.map { "target \(targetSets) × \($0)" } ?? "target \(targetSets) sets")
        }
        if let previous, let summary = PreviousPerformance.summary(previous, unit: unit, isBodyweight: entry.isBodyweight) {
            lines.append("last time: \(summary)")
        } else if loaded, previous == nil {
            lines.append("no earlier sessions with this exercise")
        }
        if entry.isBodyweight {
            lines.append("bodyweight · load is added weight · not compared for records yet")
        } else if let heaviest = prior.heaviestLoad {
            var best = "best \(LoadText.load(heaviest, unit: unit, isBodyweight: false))"
            if let estimate = prior.estimatedOneRepMax { best += " · est. 1RM \(LoadText.load(estimate, unit: unit, isBodyweight: false))" }
            lines.append(best)
        }
        return lines
    }

    private func load() {
        guard let session = entry.session else { return }
        previous = try? coordinator.store.previousSets(for: entry.exerciseID, before: session)
        prior = (try? coordinator.store.priorBests(for: [entry.exerciseID], before: session))?[entry.exerciseID] ?? .none
        loaded = true
    }

    /// Working sets are numbered; warm-ups are marked "w".
    private static func labels(for sets: [LoggedSet]) -> [UUID: String] {
        var labels: [UUID: String] = [:], number = 0
        for set in sets {
            if set.kind == .warmup { labels[set.id] = "w" } else { number += 1; labels[set.id] = "\(number)" }
        }
        return labels
    }
}

private struct SetRow: View {
    @Environment(SessionCoordinator.self) private var coordinator
    let set: LoggedSet
    let exercise: String
    let label: String
    let previous: SetEntry?
    let hits: [RecordHit]
    let isBodyweight: Bool
    let unit: WeightUnit
    let loadWidth: CGFloat
    let repsWidth: CGFloat
    let showsPrevious: Bool

    var body: some View {
        let name = set.kind == .warmup ? "warm-up set" : "set \(label)"
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Menu {
                    Button(set.kind == .working ? "mark as warm-up" : "mark as working") { toggleKind() }
                    Button("delete set", role: .destructive) { delete() }
                } label: {
                    Text(label).font(VitalsStyle.entry).monospacedDigit()
                        .foregroundStyle(set.kind == .warmup ? VitalsStyle.secondary : VitalsStyle.text)
                        .frame(width: 36, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(name)
                .accessibilityHint("options: warm-up or working, delete")
                if showsPrevious {
                    Text(previous.map { LoadText.set(reps: $0.reps, kilograms: $0.loadKilograms, unit: unit, isBodyweight: isBodyweight) } ?? "–")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(previous.map { "last time \(LoadText.set(reps: $0.reps, kilograms: $0.loadKilograms, unit: unit, isBodyweight: isBodyweight))" } ?? "no set last time")
                } else {
                    Spacer(minLength: 0)
                }
                NumberField(value: set.loadKilograms > 0 ? LoadText.number(set.loadKilograms, unit: unit) : "", placeholder: "bw",
                            keyboard: .decimalPad, label: "\(name) \(isBodyweight ? "added load" : "load") in \(unit.symbol)",
                            width: loadWidth, identifier: "\(exercise)-\(label)-load") { text in
                    guard let kilograms = NumberText.parseLoad(text, unit: unit) else {
                        coordinator.message = "enter a load of 0 or more. 0 means bodyweight."
                        return
                    }
                    coordinator.perform { try coordinator.store.update(set, loadKilograms: kilograms) }
                }
                NumberField(value: "\(set.reps)", placeholder: "0", keyboard: .numberPad, label: "\(name) reps", width: repsWidth,
                            identifier: "\(exercise)-\(label)-reps") { text in
                    guard let reps = NumberText.parseReps(text) else {
                        coordinator.message = "enter reps from 0 to \(NumberText.maximumReps)."
                        return
                    }
                    coordinator.perform { try coordinator.store.update(set, reps: reps) }
                }
                Button { Keyboard.dismiss(); coordinator.toggleCompleted(set) } label: {
                    Image(systemName: set.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(set.completed ? VitalsStyle.text : VitalsStyle.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(set.completed ? "\(name) done" : "mark \(name) done")
                .accessibilityIdentifier("\(exercise)-\(label)-done")
                .accessibilityHint(set.completed ? "double tap to undo" : "")
            }
            ForEach(hits) { hit in
                Text("new best · \(hit.kind.label) \(LoadText.load(hit.value, unit: unit, isBodyweight: false)), was \(LoadText.load(hit.previous, unit: unit, isBodyweight: false))")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                    .padding(.leading, 44)
            }
        }
        .accessibilityAction(named: "delete set") { delete() }
    }

    private func toggleKind() {
        coordinator.perform { try coordinator.store.update(set, kind: set.kind == .working ? .warmup : .working) }
    }

    private func delete() {
        coordinator.perform { try coordinator.store.delete(set) }
    }
}

/// A numeric field that commits on return or when focus leaves. Focusing clears it, with the current value as
/// the prompt, so a new number can be typed without deleting; leaving it empty keeps the value.
struct NumberField: View {
    let value: String
    let placeholder: String
    let keyboard: UIKeyboardType
    let label: String
    var width: CGFloat = 72
    var identifier: String?
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(value.isEmpty ? placeholder : value).foregroundStyle(VitalsStyle.secondary))
            .keyboardType(keyboard)
            .multilineTextAlignment(.center)
            .font(VitalsStyle.entry)
            .monospacedDigit()
            .focused($focused)
            .frame(width: width, height: 44)
            .background(VitalsStyle.surface, in: RoundedRectangle(cornerRadius: 2))
            .overlay(alignment: .bottom) {
                Rectangle().fill(focused ? VitalsStyle.text : VitalsStyle.divider).frame(height: 1)
            }
            .accessibilityLabel(label)
            .accessibilityValue(value.isEmpty ? placeholder : value)
            .accessibilityIdentifier(identifier ?? label)
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in if !focused { text = newValue } }
            .onChange(of: focused) { _, isFocused in
                if isFocused { text = "" } else { finish() }
            }
            .onSubmit { focused = false }
    }

    private func finish() {
        let entered = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = value
        if !entered.isEmpty, entered != value { commit(entered) }
    }
}
