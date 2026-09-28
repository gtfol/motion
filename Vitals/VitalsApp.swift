import SwiftData
import SwiftUI

@main struct VitalsApp: App {
    // Created in the app's initializer, not in a view task, so a background relaunch by Bluetooth state
    // restoration recreates the central manager with its restore identifier before any UI exists.
    @State private var launch = AppLaunch()

    var body: some Scene {
        WindowGroup {
            Group {
                if let services = launch.services {
                    RootView()
                        .environment(services.coordinator)
                        .environment(services.monitor)
                        .modelContainer(services.container)
                } else {
                    VStack(spacing: 16) {
                        Text("vitals").font(VitalsStyle.heading)
                        Text("couldn’t open your training log on this iPhone.").font(VitalsStyle.caption)
                            .foregroundStyle(VitalsStyle.secondary)
                        TextAction("try again") { launch.start() }
                    }
                    .padding(VitalsStyle.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(VitalsStyle.canvas)
                }
            }
            .font(VitalsStyle.body)
            .foregroundStyle(VitalsStyle.text)
            .tint(VitalsStyle.text)
            .preferredColorScheme(.dark)
        }
    }
}

@MainActor @Observable final class AppLaunch {
    private(set) var services: AppServices?

    init() { start() }

    func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            // Automated UI tests only: a throwaway store, no Bluetooth, and Apple Health reported as unavailable so
            // no system permission sheet appears. Not compiled into release builds.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-tests-\(UUID().uuidString)")
            services = try? AppServices(directory: directory, exporter: UnavailableHealthExporter(), activateBluetooth: false)
            return
        }
        #endif
        services = try? AppServices(directory: URL.applicationSupportDirectory)
    }
}

#if DEBUG
/// Behaves like a device without Apple Health. Used only by the UI tests' launch argument.
struct UnavailableHealthExporter: WorkoutExporting {
    func access() -> HealthAccess { .unavailable }
    func requestAccess() async -> HealthAccess { .unavailable }
    func export(_ payload: HealthWorkoutPayload) async -> HealthExportOutcome { .unavailable }
}
#endif

/// The one local store, the strap monitor, Apple Health, and the coordinator that ties them together.
@MainActor final class AppServices {
    let container: ModelContainer
    let store: WorkoutStore
    let monitor: HeartRateMonitor
    let coordinator: SessionCoordinator

    init(directory: URL, exporter: any WorkoutExporting = HealthKitExporter(), activateBluetooth: Bool = true) throws {
        let container = try VitalsContainer.make(directory: directory)
        let store = WorkoutStore(container: container)
        let preferences = try store.preferences()
        let monitor = HeartRateMonitor(restoreIdentifier: "\(Bundle.main.bundleIdentifier ?? "vitals").heart-rate",
                                       strapID: preferences.strapID, strapName: preferences.strapName)
        let coordinator = SessionCoordinator(store: store, exporter: exporter)
        monitor.onReading = { [weak coordinator, weak monitor] reading in
            coordinator?.receive(reading, strapName: monitor?.strapName)
        }
        monitor.onSelectionChange = { [weak coordinator] id, name in
            coordinator?.updateSettings { $0.strapID = id; $0.strapName = name }
        }
        coordinator.launch()
        // Only touch Bluetooth at launch if a strap was chosen before; otherwise wait until the user chooses one.
        if activateBluetooth, preferences.strapID != nil { monitor.activate() }
        self.container = container; self.store = store; self.monitor = monitor; self.coordinator = coordinator
    }
}
