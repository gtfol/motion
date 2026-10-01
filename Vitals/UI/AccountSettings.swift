import SwiftUI

struct AccountSettings: View {
    @Environment(AppLaunch.self) private var launch
    @State private var deleting = false
    @State private var signingOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "account & sync")
            if launch.owner != nil {
                Text(launch.email ?? "signed in").font(VitalsStyle.caption)
                if let sync = launch.sync {
                    if sync.busy { Text("syncing…").foregroundStyle(VitalsStyle.secondary) }
                    else if let date = sync.lastSynced {
                        Text("last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                    }
                    if let message = sync.message { Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution) }
                    TextAction("sync now") { sync.schedule(immediate: true) }.disabled(sync.busy || launch.busy)
                    if !sync.conflicts.isEmpty {
                        Text("changed on two devices. choose which version to keep.").font(VitalsStyle.caption)
                        ForEach(sync.conflicts, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key.kind.rawValue).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                                Text("this iPhone: \(sync.conflictSummary(key, cloud: false))").font(VitalsStyle.caption)
                                Text("cloud: \(sync.conflictSummary(key, cloud: true))").font(VitalsStyle.caption)
                                DisclosureGroup("compare details") {
                                    ForEach([false, true], id: \.self) { cloud in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(cloud ? "cloud" : "this iPhone")
                                            ForEach(Array(sync.conflictDetails(key, cloud: cloud).enumerated()), id: \.offset) { _, line in
                                                Text(line).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                                            }
                                        }
                                    }
                                }
                                HStack(spacing: 24) {
                                    TextAction("keep this iPhone") { sync.resolve(key, keepLocal: true) }
                                    TextAction("keep cloud") { sync.resolve(key, keepLocal: false) }
                                }.disabled(sync.busy)
                            }
                        }
                    }
                }
                HStack(spacing: 24) {
                    TextAction("sign out", secondary: true) { signingOut = true }
                    TextAction("delete account", role: .destructive, secondary: true) { deleting = true }
                }.disabled(launch.busy || !launch.canSwitch)
                Text("sign out keeps this account’s log on this iPhone. sign back into the same account to open it.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                DisclosureGroup("sign in again") { signInButtons }
            } else if launch.configured {
                Text("keep logging offline. sign in to sync workouts, sets, routines, exercises, workout heart rate and preferences across your devices.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
                signInButtons
            } else {
                Text("cloud sync is being set up. your log is saved on this iPhone.")
                    .font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary)
            }
            if !launch.canSwitch { Text("finish your workout before changing accounts.").font(VitalsStyle.caption) }
            if let message = launch.message { Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution) }
        }
        .confirmationDialog("sign out?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("sign out") { Task { await launch.signOut() } }
        } message: { Text("unsynced changes stay on this iPhone. sign back into this account to sync them.") }
        .confirmationDialog("permanently delete your account?", isPresented: $deleting, titleVisibility: .visible) {
            Button("delete account and synced data", role: .destructive) { Task { await launch.deleteAccount() } }
        } message: { Text("this removes your cloud account, all synced data and this account’s log on this iPhone. it can’t be undone. Apple Health copies and your separate local log are kept.") }
    }

    private var signInButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextAction("continue with Google") { Task { await launch.signIn() } }
        }.disabled(launch.busy || !launch.canSwitch)
    }
}

struct LocalLogChoice: View {
    @Environment(AppLaunch.self) private var launch
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("bring your local log?").font(VitalsStyle.heading)
                Text("add this iPhone’s existing workouts, exercises, routines and preferences to your account. your separate local log will stay here too.")
                TextAction("add my local log") { launch.finishSignIn(includeLocal: true) }
                TextAction("use my cloud log", secondary: true) { launch.finishSignIn(includeLocal: false) }
                if let message = launch.message { Text(message).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.caution) }
                Spacer()
            }.padding(VitalsStyle.gutter).vitalsScreen()
        }.interactiveDismissDisabled()
    }
}
