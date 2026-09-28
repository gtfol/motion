import SwiftData
import SwiftUI

/// Search recent and catalog exercises, or create one inline by typing its name.
struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionCoordinator.self) private var coordinator
    @Query(sort: \Exercise.name) private var catalog: [Exercise]
    @State private var search = ""
    @State private var recent: [Exercise] = []
    let onPick: (Exercise) -> Void

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [Exercise] {
        guard !query.isEmpty else { return catalog }
        return catalog.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.category?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    private var exactMatch: Bool { catalog.contains { $0.name.caseInsensitiveCompare(query) == .orderedSame } }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty, !exactMatch {
                    Button { create() } label: {
                        Label("create “\(query)”", systemImage: "plus").frame(minHeight: 44, alignment: .leading)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(VitalsStyle.divider)
                }
                if query.isEmpty, !recent.isEmpty {
                    Section {
                        ForEach(recent) { row($0) }
                    } header: { header("recent") }
                }
                Section {
                    ForEach(matches) { row($0) }
                } header: { header(query.isEmpty ? "all exercises" : "matches") }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "search or create")
            .textInputAutocapitalization(.never)
            .vitalsScreen()
            .vitalsTitle("add exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("close") { dismiss() } }
            }
            .task { recent = (try? coordinator.store.recentExercises()) ?? [] }
        }
        .presentationBackground(VitalsStyle.canvas)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary).textCase(nil)
    }

    private func row(_ exercise: Exercise) -> some View {
        Button { onPick(exercise); dismiss() } label: {
            HStack {
                Text(exercise.name)
                Spacer()
                Text([exercise.category, exercise.isBodyweight ? "bodyweight" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pick-\(exercise.name)")
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(VitalsStyle.divider)
    }

    private func create() {
        do {
            let exercise = try coordinator.store.createExercise(name: query)
            onPick(exercise)
            dismiss()
        } catch {
            coordinator.message = error.localizedDescription
        }
    }
}
