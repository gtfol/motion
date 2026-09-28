import SwiftData
import SwiftUI

/// Edits a routine: an ordered list of exercises with optional target sets and reps. No scheduling.
struct RoutineEditor: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var routines: [Routine]
    @State private var name = ""
    @State private var picking = false
    @State private var confirmDelete = false
    @State private var editMode: EditMode = .inactive

    init(routineID: UUID) {
        _routines = Query(filter: #Predicate<Routine> { $0.id == routineID })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let routine = routines.first {
                    editor(routine)
                } else {
                    Text("this routine was deleted.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .vitalsScreen()
            .vitalsTitle("routine")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { rename(); dismiss() }
                }
            }
        }
        .presentationBackground(VitalsStyle.canvas)
    }

    private func editor(_ routine: Routine) -> some View {
        List {
            Section {
                TextField("name", text: $name)
                    .onSubmit(rename)
                    .onAppear { if name.isEmpty { name = routine.name } }
            } header: { header("name") }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(VitalsStyle.divider)

            Section {
                ForEach(routine.orderedEntries) { entry in RoutineEntryRow(entry: entry) }
                    .onMove { source, destination in
                        coordinator.perform { try coordinator.store.moveEntries(in: routine, from: source, to: destination) }
                    }
                    .onDelete { offsets in
                        let entries = routine.orderedEntries
                        for index in offsets { coordinator.perform { try coordinator.store.remove(entries[index]) } }
                    }
                Button("add exercise") { picking = true }.frame(minHeight: 44)
            } header: {
                header("exercises")
            } footer: {
                Text("starting this routine copies it into a new workout. changing that workout doesn’t change the routine. swipe an exercise to remove it.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(VitalsStyle.divider)

            Section {
                Button("delete routine", role: .destructive) { confirmDelete = true }.frame(minHeight: 44)
            } footer: {
                Text("past workouts started from it are kept.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode.isEditing ? "stop reordering" : "reorder") {
                    editMode = editMode.isEditing ? .inactive : .active
                }
                .disabled(routine.entries.count < 2 && !editMode.isEditing)
            }
        }
        .sheet(isPresented: $picking) {
            ExercisePicker { exercise in coordinator.perform { try coordinator.store.addExercise(exercise, to: routine) } }
        }
        .confirmationDialog("delete \(routine.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("delete routine", role: .destructive) {
                let target = routine
                dismiss()
                coordinator.perform { try coordinator.store.delete(target) }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary).textCase(nil)
    }

    private func rename() {
        guard let routine = routines.first else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != routine.name else { return }
        coordinator.perform { try coordinator.store.rename(routine, to: trimmed) }
    }
}

private struct RoutineEntryRow: View {
    @Environment(SessionCoordinator.self) private var coordinator
    let entry: RoutineExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.exercise?.name ?? "removed exercise")
            Stepper(value: Binding(get: { entry.targetSets ?? 0 }, set: { update(sets: $0, reps: entry.targetReps) }), in: 0...20) {
                Text(entry.targetSets.map { "\($0) \($0 == 1 ? "set" : "sets")" } ?? "no set target")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            Stepper(value: Binding(get: { entry.targetReps ?? 0 }, set: { update(sets: entry.targetSets, reps: $0) }), in: 0...50) {
                Text(entry.targetReps.map { "\($0) reps" } ?? "no rep target")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func update(sets: Int?, reps: Int?) {
        coordinator.perform {
            try coordinator.store.setTargets(entry, sets: sets.flatMap { $0 > 0 ? $0 : nil }, reps: reps.flatMap { $0 > 0 ? $0 : nil })
        }
    }
}
