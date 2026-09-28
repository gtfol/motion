import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case train, history, settings
    var id: String { rawValue }
}

/// Three tabs under a quiet text bar, following capsule's freewrite-style bottom navigation.
/// All tabs stay alive so switching never loses a tab's place.
struct RootView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .train

    var body: some View {
        // The bar is stacked under the pages, not added as a safe-area inset: a NavigationStack doesn't pass an
        // outside inset on to its content, which left the rest clock and the end of each page under the bar.
        VStack(spacing: 0) {
            ZStack {
                page(.train) { TrainTab() }
                page(.history) { HistoryTab() }
                page(.settings) { SettingsTab() }
            }
            BottomNavigation(tab: $tab)
        }
        .background(VitalsStyle.canvas)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coordinator.heartbeat() }
            if phase == .active { coordinator.refreshHealthAccess() }
        }
        .task {
            // A heartbeat lets an interrupted session be finished at the time vitals last ran, not at relaunch.
            while !Task.isCancelled {
                coordinator.heartbeat()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onAppear { if coordinator.recoveredSession != nil { tab = .train } }
    }

    private func page<Content: View>(_ page: AppTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(tab == page ? 1 : 0)
            .allowsHitTesting(tab == page)
            .accessibilityHidden(tab != page)
    }
}

private struct BottomNavigation: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Binding var tab: AppTab

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 32) {
                ForEach(AppTab.allCases) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 6) {
                            Text(item.rawValue)
                            if item == .train, coordinator.activeSession != nil, tab != .train {
                                Circle().fill(VitalsStyle.text).frame(width: 5, height: 5)
                            }
                        }
                        .font(VitalsStyle.caption)
                        .foregroundStyle(tab == item ? VitalsStyle.text : VitalsStyle.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item == .train && coordinator.activeSession != nil ? "train, workout in progress" : item.rawValue)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityIdentifier("tab-\(item.rawValue)")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(VitalsStyle.canvas)
    }
}
