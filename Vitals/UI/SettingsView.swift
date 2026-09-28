import SwiftUI
import UIKit

struct SettingsTab: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(HeartRateMonitor.self) private var monitor
    @State private var choosingStrap = false
    @State private var ageText = ""
    @FocusState private var ageFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("done") { Keyboard.dismiss() }.accessibilityIdentifier("keyboard-done")
                }
            }
            .sheet(isPresented: $choosingStrap) { StrapChooser() }
            .onAppear { ageText = coordinator.age.map { "\($0)" } ?? "" }
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
            Text("loads are stored exactly and shown in the unit you pick. switching never changes a logged set.")
                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
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
            Text("starts when you mark a set done. the clock is in the app only; there are no notifications.")
                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
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
            Text("used only for an approximate heart-rate zone tint.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
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
                Text("heart rate strap").font(VitalsStyle.heading)
                InfoButton(title: "heart rate strap", paragraphs: [
                    "in Zepp: Device → Helio Strap → Health Monitoring → turn on Heart Rate Push. then fully quit Zepp while training, because it can hold the strap’s connection.",
                    "vitals reads the standard Bluetooth heart rate and battery services, and only connects to the strap you choose. Zepp doesn’t need to be open.",
                    "with the screen locked, ios usually keeps delivering heart rate. if ios ends vitals, or you force-quit it, nothing is recorded until you open vitals again; that time shows as a gap."
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
            } else {
                Text("none chosen. workouts work without a strap.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                TextAction("choose strap") { choosingStrap = true }
            }
            if monitor.status == .bluetoothDenied { OpenSettingsLink() }
        }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("Apple Health").font(VitalsStyle.heading)
                InfoButton(title: "Apple Health", paragraphs: [
                    "each finished workout is saved to Apple Health once, with its type, start and end, and the heart-rate samples vitals received. sets and reps stay in vitals.",
                    "vitals doesn’t write calories and doesn’t promise activity-ring credit.",
                    "vitals reads workouts only to find one it already saved, so a retry can’t create a duplicate.",
                    "without access, everything still works here and nothing leaves this iPhone."
                ])
                Spacer()
                Text(accessLabel).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            switch coordinator.healthAccess {
            case .notDetermined:
                Text("vitals asks when you first finish a workout, or now.").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                TextAction("allow Apple Health") { Task { await coordinator.requestHealthAccess() } }
            case .denied:
                Text("vitals can’t write workouts. change this in the Health app: tap your profile, then Apps → vitals.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            case .allowed(let heartRate):
                Text(heartRate ? "workouts and heart rate are saved when you finish."
                     : "workouts are saved without heart rate, because writing heart rate isn’t allowed.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            case .unavailable:
                Text("Apple Health isn’t available on this device. workouts stay in vitals.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        }
    }

    private var accessLabel: String {
        switch coordinator.healthAccess {
        case .notDetermined: "not set up"
        case .denied: "not allowed"
        case .allowed: "allowed"
        case .unavailable: "unavailable"
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "vitals", detail: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            Text("everything stays on this iPhone: no account, no network, no analytics. Apple Health gets a copy only if you allow it.")
                .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            if let message = coordinator.message {
                Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
        }
    }
}

private struct OpenSettingsLink: View {
    var body: some View {
        TextAction("open Settings to allow Bluetooth") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }
}

/// Lists nearby heart-rate straps. The user picks one; vitals never picks a device on its own.
struct StrapChooser: View {
    @Environment(HeartRateMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("turn on Heart Rate Push in Zepp (Device → Helio Strap → Health Monitoring), wear the strap, and fully quit Zepp.")
                        .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    switch monitor.status {
                    case .bluetoothOff:
                        Text("Bluetooth is off. turn it on in Control Center.").font(VitalsStyle.caption)
                    case .bluetoothDenied:
                        Text("Bluetooth access is off for vitals.").font(VitalsStyle.caption)
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
                            Text("looking for heart-rate straps…").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
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
