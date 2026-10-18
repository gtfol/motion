import SwiftData
import SwiftUI

struct FinishRequest: Identifiable {
    let session: WorkoutSession
    let end: Date
    var id: UUID { session.id }
}

struct TrainTab: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @State private var finishing: FinishRequest?
    @State private var pendingDiscard: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let session = coordinator.activeSession {
                    ActiveSessionView(session: session) { end in finishing = FinishRequest(session: session, end: end) }
                } else {
                    StartView()
                }
            }
            .motionScreen()
        }
        .confirmationDialog("workout in progress", isPresented: recovering, titleVisibility: .visible,
                            presenting: coordinator.recoveredSession) { session in
            let end = coordinator.recoveredEnd(for: session)
            Button("continue workout") { coordinator.continueRecovered() }
            Button("finish at \(end.formatted(date: .omitted, time: .shortened))") {
                coordinator.continueRecovered()
                finishing = FinishRequest(session: session, end: end)
            }
        } message: { session in
            Text("started \(session.startedAt.formatted(date: .abbreviated, time: .shortened)). your sets are saved. motion doesn’t record heart rate while it’s closed, so that time shows as a gap.")
        }
        .sheet(item: $finishing, onDismiss: discardIfRequested) { request in
            FinishView(request: request) {
                pendingDiscard = request.session.id
                finishing = nil
            }
        }
    }

    private var recovering: Binding<Bool> {
        Binding(get: { coordinator.recoveredSession != nil && finishing == nil },
                set: { if !$0 { coordinator.continueRecovered() } })
    }

    /// Deleting happens after the sheet is gone, so no view is still showing the deleted session.
    private func discardIfRequested() {
        guard let id = pendingDiscard else { return }
        pendingDiscard = nil
        coordinator.discard(id: id)
    }
}

private struct StartView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Query(sort: \Routine.name) private var routines: [Routine]
    @State private var editing: RoutineRoute?
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                HeartRatePanel(session: nil)
                VStack(alignment: .leading, spacing: 12) {
                    Button { coordinator.start(.strength) } label: { Label("start strength", systemImage: "dumbbell.fill").frame(maxWidth: .infinity) }
                        .motionPrimaryAction()
                        .accessibilityIdentifier("start-strength")
                    Text("log exercises and sets. heart rate is added when your strap is connected, and the workout works without it.")
                        .font(MotionStyle.caption).foregroundStyle(MotionStyle.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "routines", detail: routines.isEmpty ? nil : "tap to start")
                        .padding(.bottom, 8)
                    if routines.isEmpty {
                        Text("save a finished workout as a routine, or create one here.")
                            .font(MotionStyle.caption).foregroundStyle(MotionStyle.secondary).padding(.bottom, 4)
                    }
                    ForEach(routines) { routine in
                        HStack(spacing: 12) {
                            Button { coordinator.start(.strength, routine: routine) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(routine.name)
                                    Text(Self.outline(routine)).font(MotionStyle.caption).foregroundStyle(MotionStyle.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("starts a strength workout from this routine")
                            TextAction("edit", secondary: true) { editing = RoutineRoute(id: routine.id) }
                                .accessibilityLabel("edit \(routine.name)")
                        }
                        .padding(.vertical, 8)
                        Hairline()
                    }
                    TextAction("new routine") { name = ""; naming = true }
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading(title: "heart rate only")
                    Text("time and heart rate, without sets.").font(MotionStyle.caption).foregroundStyle(MotionStyle.secondary)
                    HStack(spacing: 24) {
                        ForEach(ActivityKind.heartRateOnly) { kind in
                            TextAction(kind.label) { coordinator.start(kind) }.accessibilityLabel("start \(kind.label)")
                        }
                    }
                }
                if let message = coordinator.message {
                    Text(message).font(MotionStyle.caption).foregroundStyle(MotionStyle.secondary)
                }
            }
            .padding(.horizontal, MotionStyle.gutter)
            .padding(.vertical, 24)
        }
        .motionTitle("train")
        .sheet(item: $editing) { route in RoutineEditor(routineID: route.id) }
        .alert("new routine", isPresented: $naming) {
            TextField("name", text: $name)
            Button("create") {
                coordinator.perform {
                    let routine = try coordinator.store.createRoutine(name: name)
                    editing = RoutineRoute(id: routine.id)
                }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    private static func outline(_ routine: Routine) -> String {
        let names = routine.orderedEntries.compactMap { $0.exercise?.name }
        guard !names.isEmpty else { return "no exercises yet" }
        return names.joined(separator: ", ")
    }
}

struct RoutineRoute: Identifiable, Hashable {
    let id: UUID
}
