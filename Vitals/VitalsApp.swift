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
                        .environment(launch)
                        .id(launch.viewID)
                        .disabled(launch.busy)
                        .modelContainer(services.container)
                        .sheet(isPresented: $launch.needsImportChoice) { LocalLogChoice() }
                } else {
                    VStack(spacing: 16) {
                        Text("motion").font(VitalsStyle.heading)
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
            .tint(VitalsStyle.accent)
            .preferredColorScheme(.dark)
        }
    }
}

@MainActor @Observable final class AppLaunch {
    private(set) var services: AppServices?
    private(set) var sync: CloudSync?
    private(set) var owner: UUID?
    private(set) var busy = false
    private(set) var viewID = UUID()
    var message: String?
    var needsImportChoice = false
    @ObservationIgnored private var pendingOwner: UUID?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let cloud: MotionCloud?
    @ObservationIgnored private let testing: Bool
    private struct Selection: Codable { var owner: UUID? }

    init() {
        #if DEBUG
        testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        testing = false
        #endif
        directory = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("ui-tests-\(UUID().uuidString)") : .applicationSupportDirectory
        cloud = testing ? nil : MotionCloudConfiguration.bundled.map(MotionCloud.init)
        start()
    }

    var configured: Bool { cloud != nil }
    var email: String? { cloud?.login?.user.id == owner ? cloud?.login?.user.email : nil }
    var canSwitch: Bool { services?.coordinator.activeSession == nil && services?.coordinator.exporting.isEmpty != false }
    private var selectionURL: URL { directory.appendingPathComponent("motion-account.json") }
    private func accountDirectory(_ owner: UUID) -> URL { directory.appendingPathComponent("accounts/\(owner.uuidString)") }

    func start() {
        do {
            let selected: UUID?
            if FileManager.default.fileExists(atPath: selectionURL.path) {
                selected = try SyncCoding.decoder().decode(Selection.self, from: Data(contentsOf: selectionURL)).owner
            } else { selected = nil }
            try activate(selected, writeSelection: false)
        } catch { message = error.localizedDescription }
    }

    private func activate(_ account: UUID?, writeSelection: Bool = true) throws {
        let target = account.map(accountDirectory) ?? directory
        let next: AppServices
        #if DEBUG
        if testing { next = try AppServices(directory: target, exporter: UnavailableHealthExporter(), activateBluetooth: false, seedCatalog: account == nil) }
        else { next = try AppServices(directory: target, activateBluetooth: false, seedCatalog: account == nil) }
        #else
        next = try AppServices(directory: target, activateBluetooth: false, seedCatalog: account == nil)
        #endif
        let nextSync: CloudSync?
        var syncError: String?
        if let account, let cloud {
            do { nextSync = try CloudSync(owner: account, store: next.store, directory: target, transport: cloud.transport(owner: account)) }
            catch { nextSync = nil; syncError = error.localizedDescription }
        } else { nextSync = nil }
        if writeSelection {
            try SyncCoding.encoder().encode(Selection(owner: account)).write(to: selectionURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        sync?.stop(); services?.monitor.shutdown()
        services = next; owner = account; sync = nextSync; viewID = UUID()
        message = syncError
        next.store.onSaved = { [weak nextSync] in nextSync?.schedule() }
        if !testing, next.coordinator.settings?.strapID != nil { next.monitor.activate() }
        nextSync?.schedule(immediate: true)
    }

    func signIn() async {
        guard !busy, canSwitch, let cloud else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let account = try await cloud.signIn()
            guard canSwitch else { throw StoreError.activeSessionExists }
            if account == owner { sync?.schedule(immediate: true); return }
            if owner == nil, !FileManager.default.fileExists(atPath: accountDirectory(account).appendingPathComponent("vitals.store").path) {
                pendingOwner = account; needsImportChoice = true
            } else { try activate(account) }
        } catch { message = "couldn’t sign in. your log is still saved on this iPhone." }
    }

    func finishSignIn(includeLocal: Bool) {
        guard !busy, canSwitch, let account = pendingOwner else { return }
        do {
            if includeLocal, let store = services?.store {
                let snapshot = try store.syncSnapshot()
                let target = WorkoutStore(container: try VitalsContainer.make(directory: accountDirectory(account)))
                let kinds: [SyncKind] = [.exercise, .routine, .workout, .preferences]
                let records = snapshot.map { CloudRecord(kind: $0.key.kind, id: $0.key.id, revision: 1, body: $0.value) }
                    .sorted { kinds.firstIndex(of: $0.kind)! < kinds.firstIndex(of: $1.kind)! }
                try target.applyCloud(records)
            }
            try activate(account)
            pendingOwner = nil; needsImportChoice = false
        } catch { message = error.localizedDescription }
    }

    func signOut() async {
        guard !busy, canSwitch else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try activate(nil)
            try await cloud?.signOut()
        } catch { message = error.localizedDescription }
    }

    func deleteAccount() async {
        guard !busy, canSwitch, let owner, let cloud else { return }
        busy = true; message = nil
        defer { busy = false }
        sync?.stop()
        do {
            try await cloud.deleteAccount(owner: owner)
            try activate(nil)
            try await cloud.signOut()
            do { try FileManager.default.removeItem(at: accountDirectory(owner)) }
            catch { message = "your cloud account was deleted, but the local copy couldn’t be removed from this iPhone." }
        } catch {
            message = "couldn’t finish deleting the account. sign in again and retry."
            if self.owner == owner { try? activate(owner) }
        }
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

    init(directory: URL, exporter: any WorkoutExporting = HealthKitExporter(), activateBluetooth: Bool = true, seedCatalog: Bool = true) throws {
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
        coordinator.launch(seedCatalog: seedCatalog)
        // Only touch Bluetooth at launch if a strap was chosen before; otherwise wait until the user chooses one.
        if activateBluetooth, preferences.strapID != nil { monitor.activate() }
        self.container = container; self.store = store; self.monitor = monitor; self.coordinator = coordinator
    }
}
