import SwiftUI
import UIKit

struct SettingsTab: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(HeartRateMonitor.self) private var monitor
    @Environment(HelioSleepSync.self) private var helio
    @Environment(SleepHealthStore.self) private var sleepHealth
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sleep-health-requested") private var sleepHealthRequested = false
    @State private var choosingStrap = false
    @State private var showingSleepSetup = false
    @State private var connectingSleepHealth = false
    @State private var showingSleepHealthAccess = false
    @State private var returningFromHealth = false
    @State private var sleepHealthMessage: String?
    @State private var ageText = ""
    @FocusState private var ageFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    AccountSettings()
                    units
                    rest
                    age
                    strap
                    health
                    about
                }
                .padding(.horizontal, VitalsStyle.gutter)
                .padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .vitalsScreen()
            .vitalsTitle("settings")
            .sheet(isPresented: $choosingStrap) { StrapChooser() }
            .sheet(isPresented: $showingSleepSetup) { HelioSetupView() }
            .sheet(isPresented: $showingSleepHealthAccess) {
                SleepHealthAccessView {
                    returningFromHealth = true
                    showingSleepHealthAccess = false
                }
            }
            .onAppear { ageText = coordinator.age.map { "\($0)" } ?? "" }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, returningFromHealth {
                    returningFromHealth = false
                    Task { await refreshSleepHealth() }
                }
            }
        }
    }

    private var units: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "units")
            Picker("units", selection: Binding(get: { coordinator.unit }, set: { unit in coordinator.updateSettings { $0.unit = unit } })) {
                Text("lb").tag(WeightUnit.pounds)
                Text("kg").tag(WeightUnit.kilograms)
            }
            .pickerStyle(.segmented)
        }
    }

    private var rest: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "rest")
            Stepper(value: Binding(get: { coordinator.settings?.defaultRestSeconds ?? RestTimer.defaultTarget },
                                   set: { seconds in coordinator.updateSettings { $0.defaultRestSeconds = RestTimer.clampedTarget(seconds) } }),
                    in: RestTimer.targetRange, step: 15) {
                HStack {
                    Text("default rest")
                    Spacer()
                    Text(ClockText.duration(coordinator.restTarget)).monospacedDigit()
                }
            }
        }
    }

    private var age: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("age").font(VitalsStyle.heading)
                InfoButton(title: "heart-rate zones", paragraphs: [
                    "with an age, the live number is tinted by an approximate zone based on 220 minus your age.",
                    "that estimate can be far from your real maximum. zones here are a rough guide, not a medical measurement or advice.",
                    "leave age empty to turn zones off."
                ])
                Spacer()
            }
            HStack {
                TextField("optional", text: $ageText, prompt: Text("optional").foregroundStyle(VitalsStyle.secondary))
                    .keyboardType(.numberPad)
                    .focused($ageFocused)
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { Rectangle().fill(VitalsStyle.divider).frame(height: 1) }
                    .accessibilityLabel("age, optional")
                    .onChange(of: ageFocused) { _, focused in if !focused { saveAge() } }
                    .onSubmit(saveAge)
                if coordinator.age != nil {
                    TextAction("clear", secondary: true) { ageText = ""; saveAge() }
                }
            }
        }
    }

    private func saveAge() {
        let trimmed = ageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            coordinator.updateSettings { $0.age = nil }
        } else if let value = Int(trimmed), HeartRateZone.ages.contains(value) {
            coordinator.updateSettings { $0.age = value }
        } else {
            coordinator.message = "enter an age from \(HeartRateZone.ages.lowerBound) to \(HeartRateZone.ages.upperBound), or leave it empty."
            ageText = coordinator.age.map { "\($0)" } ?? ""
        }
    }

    private var strap: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("strap").font(VitalsStyle.heading)
                InfoButton(title: "strap", paragraphs: [
                    "in Zepp: Device → Helio Strap → Health Monitoring → turn on Heart Rate Push. then fully quit Zepp while training, because it can hold the strap’s connection.",
                    "motion reads the standard Bluetooth heart rate and battery services, and only connects to the strap you choose. Zepp doesn’t need to be open.",
                    "with the screen locked, ios usually keeps delivering heart rate. if ios ends motion, or you force-quit it, nothing is recorded until you open motion again; that time shows as a gap.",
                    "Helio sleep sync uses your existing band key to read sleep, overnight heart rate and breathing directly. Helio is preferred; Apple Health fills missing nights and metrics."
                ])
                Spacer()
            }
            if let name = monitor.strapName {
                HStack {
                    Text(name)
                    Spacer()
                    Text(monitor.status.label).foregroundStyle(VitalsStyle.secondary)
                }
                if let battery = monitor.batteryPercent, monitor.status == .connected {
                    Text("battery \(battery)%").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                }
                if monitor.status == .noHeartRateService {
                    Text("connected, but the strap isn’t sending heart rate. turn on Heart Rate Push in Zepp.")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                }
                HStack(spacing: 24) {
                    TextAction("reconnect") { monitor.reconnect() }
                    TextAction("choose another") { choosingStrap = true }
                    TextAction("forget", role: .destructive, secondary: true) { monitor.forget() }
                }
                if helio.supported {
                    HStack(spacing: 24) {
                        TextAction("strap settings") { showingSleepSetup = true }
                            .accessibilityIdentifier("helio-setup")
                        TextAction(helio.busy ? "syncing…" : "sync now") { helio.sync(force: true) }
                            .disabled(!helio.hasKey || helio.busy)
                            .accessibilityIdentifier("helio-sync")
                    }
                    if helio.busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(helio.status).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        }
                    } else if let synced = helio.archive.lastSync {
                        Text("last synced \(synced.formatted(date: .abbreviated, time: .shortened))")
                            .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    }
                    if let message = helio.message {
                        Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
                            .contextMenu {
                                if let details = helio.diagnosticDetails {
                                    Button("copy sync details") { UIPasteboard.general.string = details }
                                }
                            }
                    }
                }
            } else {
                TextAction("connect strap") { showingSleepSetup = true }
                    .accessibilityIdentifier("helio-setup")
            }
            if monitor.status == .bluetoothDenied { OpenSettingsLink() }
        }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("Apple Health").font(VitalsStyle.heading)
                InfoButton(title: "Apple Health", paragraphs: [
                    "each finished workout is saved to Apple Health once, with its type, start and end, and the heart-rate samples motion received. sets and reps stay in motion.",
                    "motion doesn’t write calories and doesn’t promise activity-ring credit.",
                    "motion reads workouts to prevent duplicate saves. sleep access reads sleep, heart rate and breathing measurements to fill gaps when Helio data is missing.",
                    "without Apple Health access, everything still works in motion. cloud sync is a separate choice."
                ])
                Spacer()
                Text(accessLabel).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            switch coordinator.healthAccess {
            case .notDetermined:
                TextAction("allow Apple Health") { Task { await coordinator.requestHealthAccess() } }
            case .denied:
                Text("motion can’t write workouts. change this in the Health app: tap your profile, then Apps → motion.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            case .allowed, .unavailable:
                EmptyView()
            }
            TextAction(connectingSleepHealth ? "connecting…" : sleepHealthRequested ? "manage sleep access" : "connect sleep data", action: connectSleepHealth)
            .disabled(connectingSleepHealth)
            .accessibilityIdentifier("sleep-health-connect")
            if let sleepHealthMessage {
                Text(sleepHealthMessage).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution)
            }
        }
    }

    private func connectSleepHealth() {
        guard !connectingSleepHealth else { return }
        connectingSleepHealth = true
        sleepHealthMessage = nil
        Task {
            defer { connectingSleepHealth = false }
            switch await sleepHealth.connect() {
            case .requested:
                sleepHealthRequested = true
                await refreshSleepHealth()
            case .manageAccess:
                sleepHealthRequested = true
                showingSleepHealthAccess = true
            case .unavailable:
                sleepHealthMessage = "Apple Health isn’t available on this device."
            case .failed:
                sleepHealthMessage = "couldn’t open Apple Health permissions. try again."
            }
        }
    }

    private func refreshSleepHealth() async {
        await sleepHealth.load(endingOn: .now)
        let hasData = sleepHealth.records.contains { !$0.nights.isEmpty || !$0.heartRate.isEmpty || !$0.respiratoryRate.isEmpty }
        sleepHealthMessage = sleepHealth.message ?? (hasData ? "sleep data refreshed" : "no sleep data is readable yet. check access in Health or try another date.")
    }

    private var accessLabel: String {
        switch coordinator.healthAccess {
        case .notDetermined: "not set up"
        case .denied: "not allowed"
        case .allowed(let heartRate): heartRate ? "allowed" : "workouts only"
        case .unavailable: "unavailable"
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "motion", detail: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            if let message = coordinator.message {
                Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        }
    }
}

private struct SleepHealthAccessView: View {
    let openedHealth: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("in Health, tap your profile → Apps → motion.")
                    .accessibilityIdentifier("sleep-health-instructions")
                Text("choose access to Sleep, Heart Rate and Respiratory Rate.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                TextAction("open Health") {
                    openURL(URL(string: "x-apple-health://")!) { opened in
                        if opened { openedHealth() }
                        else { message = "open the Health app from your Home Screen." }
                    }
                }
                .accessibilityIdentifier("sleep-health-open")
                if let message { Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary) }
                Spacer(minLength: 0)
            }
            .padding(VitalsStyle.gutter)
            .vitalsScreen()
            .vitalsTitle("sleep access")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(VitalsStyle.canvas)
    }
}

private struct OpenSettingsLink: View {
    var body: some View {
        TextAction("open Settings to allow Bluetooth") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }
}

/// Lists nearby heart-rate straps. The user picks one; motion never picks a device on its own.
struct StrapChooser: View {
    var forSleep = false
    @Environment(HeartRateMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(forSleep ? "keep your Helio Strap nearby and close Zepp while connecting." : "turn on Heart Rate Push in Zepp (Device → Helio Strap → Health Monitoring), wear the strap, and fully quit Zepp.")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    switch monitor.status {
                    case .bluetoothOff:
                        Text("Bluetooth is off. turn it on in Control Center.").font(VitalsStyle.caption)
                    case .bluetoothDenied:
                        Text("Bluetooth access is off for motion.").font(VitalsStyle.caption)
                        OpenSettingsLink()
                    case .bluetoothUnavailable:
                        Text("this device doesn’t support Bluetooth heart-rate straps.").font(VitalsStyle.caption)
                    default:
                        EmptyView()
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                Section {
                    ForEach(monitor.candidates) { candidate in
                        Button { monitor.choose(candidate); dismiss() } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.name)
                                    Text(detail(candidate)).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                                }
                                Spacer()
                                if candidate.id == monitor.strapID { Text("chosen").font(VitalsStyle.caption) }
                            }
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if monitor.candidates.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(forSleep ? "looking for Helio Strap…" : "looking for heart-rate straps…").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                } header: {
                    Text("nearby").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary).textCase(nil)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(VitalsStyle.divider)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .vitalsScreen()
            .vitalsTitle("choose strap")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("close") { dismiss() } }
            }
            .onAppear { monitor.startChoosing() }
            .onDisappear { monitor.stopChoosing() }
        }
        .presentationBackground(VitalsStyle.canvas)
    }

    private func detail(_ candidate: StrapCandidate) -> String {
        if candidate.connectedToPhone { return "connected to this iPhone" }
        guard let rssi = candidate.rssi else { return "nearby" }
        return rssi > -60 ? "strong signal" : rssi > -80 ? "signal ok" : "weak signal"
    }
}
