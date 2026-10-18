import SwiftUI
import ZeppKit

struct HelioSetupView: View {
    @Environment(HelioSleepSync.self) private var helio
    @Environment(HeartRateMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var key = ""
    @State private var keyMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(monitor.strapName ?? "no strap selected")
                        Spacer()
                        Button("choose") { choosing = true }
                    }
                    if monitor.strapID != nil && !helio.supported {
                        Text("direct sleep sync supports Helio Strap.")
                            .foregroundStyle(MotionStyle.secondary)
                    }
                }
                Section {
                    if helio.hasKey {
                        Label("key saved on this iPhone", systemImage: "checkmark.lock")
                    }
                    SecureField(helio.hasKey ? "replacement key" : "32-character key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.asciiCapable).privacySensitive()
                        .accessibilityIdentifier("helio-key")
                        .disabled(!helio.supported)
                    Button("save key") {
                        if helio.saveKey(key) {
                            key = ""; dismiss()
                        } else { keyMessage = helio.message }
                    }
                    .disabled(!helio.supported || ZeppAuthKey(hex: key) == nil || helio.busy)
                    .accessibilityIdentifier("helio-save")
                    if let message = keyMessage {
                        Text(message).font(MotionStyle.caption).foregroundStyle(MotionStyle.caution)
                    }
                } header: {
                    Text("band key")
                } footer: {
                    Text("one-time setup to read sleep directly from your strap.")
                }
                Section {
                    DisclosureGroup("how to get the key") {
                        Text("use the key from your existing Zepp pairing. don’t unpair or reset the band. you may need a computer to retrieve it.")
                            .font(MotionStyle.caption)
                        Link("band-key instructions", destination: URL(string: "https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/")!)
                        Text("paste the key here, then close Zepp and keep the strap nearby. the key stays on this iPhone.")
                            .font(MotionStyle.caption)
                    }
                    if helio.hasKey {
                        Button("remove band key", role: .destructive) {
                            helio.forgetKey(); key = ""; keyMessage = helio.message
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .motionScreen()
            .motionTitle("Helio Strap")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("close") { dismiss() } } }
            .sheet(isPresented: $choosing) { StrapChooser(forSleep: true) }
            .onChange(of: helio.strapID) { _, _ in key = ""; keyMessage = nil }
            .onDisappear { key = "" }
        }
        .presentationBackground(MotionStyle.canvas)
    }
}
