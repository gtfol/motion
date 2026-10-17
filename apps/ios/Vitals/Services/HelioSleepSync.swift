import Foundation
import Observation
@preconcurrency import ZeppKit

/// Uses the workout monitor's connection. Only authentication and read-history commands are sent.
@MainActor @Observable final class HelioSleepSync {
    private(set) var archive = HelioSleepArchive()
    private(set) var strapID: UUID?
    private(set) var supported = false
    private(set) var hasKey = false
    private(set) var busy = false
    private(set) var status = "choose your Helio Strap"
    private(set) var message: String?
    private(set) var diagnosticDetails: String?
    private(set) var revision = 0
    @ObservationIgnored var send: ((ZeppWrite) -> Void)?
    @ObservationIgnored var requestConnection: (() -> Void)?
    @ObservationIgnored var cancelWrites: (() -> Void)?
    @ObservationIgnored private let repository: HelioSleepRepository
    @ObservationIgnored private var link: ZeppLink?
    @ObservationIgnored private var fetch: ZeppHistoryFetch?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var maxWriteLength: Int?
    @ObservationIgnored private var keyRejected = false
    @ObservationIgnored private var unreadableStorage = false
    @ObservationIgnored private var failedTypes = Set<UInt8>()
    @ObservationIgnored private var transferMessage: String?
    @ObservationIgnored private var syncDate = Date.now
    // Injected only by isolated tests; production always reads the device-only Keychain.
    @ObservationIgnored private let keyReader: ((UUID) throws -> ZeppAuthKey?)?
    @ObservationIgnored private let random: ZeppRandom

    init(directory: URL, keyReader: ((UUID) throws -> ZeppAuthKey?)? = nil, random: ZeppRandom = .system) {
        repository = HelioSleepRepository(directory: directory)
        self.keyReader = keyReader; self.random = random
    }

    func select(id: UUID?, name: String?) {
        shutdown()
        strapID = id
        supported = name.map { ZeppDeviceModel.match(advertisedName: $0) == .helioStrap } ?? false
        archive = HelioSleepArchive(); lastAttempt = nil; message = nil; diagnosticDetails = nil; hasKey = false; keyRejected = false; unreadableStorage = false
        guard let id, supported else { status = "choose your Helio Strap"; revision += 1; return }
        do {
            archive = try repository.load(id)
            hasKey = try readKey(id) != nil
            status = hasKey ? "ready to sync" : "add your band key"
        } catch {
            unreadableStorage = true
            status = "couldn’t read saved sleep"
            message = "unlock your iPhone and reopen Motion. your saved data hasn’t been changed."
        }
        revision += 1
    }

    func saveKey(_ text: String) -> Bool {
        guard let strapID, supported else { return false }
        guard ZeppAuthKey(hex: text) != nil else { message = "enter the 32-character band key."; return false }
        do {
            try HelioBandKeys.save(text, scope: repository.keyScope, strap: strapID)
            hasKey = true; keyRejected = false; message = nil; diagnosticDetails = nil; status = "ready to sync"
            return true
        } catch { message = "couldn’t save the band key. unlock your iPhone and try again."; return false }
    }

    func forgetKey() {
        guard let strapID else { return }
        shutdown()
        do {
            try HelioBandKeys.remove(scope: repository.keyScope, strap: strapID)
            hasKey = false; keyRejected = false; status = "add your band key"; message = nil; diagnosticDetails = nil
        } catch { message = "couldn’t remove the key. unlock your iPhone and try again." }
    }

    func sync(force: Bool = false) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if !force, args.contains("-ui-testing"), args.contains("-ui-testing-strap") { return }
        #endif
        // Files/Keychain can be unavailable during a Bluetooth relaunch before first unlock.
        // Retry access when Motion is opened, without overwriting the unreadable archive.
        if unreadableStorage, let strapID, supported, !busy {
            do {
                let saved = try repository.load(strapID)
                let key = try readKey(strapID)
                archive = saved; hasKey = key != nil; unreadableStorage = false; revision += 1
                message = nil; status = hasKey ? "ready to sync" : "add your band key"
            } catch { return }
        }
        guard supported, hasKey, !busy, !unreadableStorage else { return }
        guard !keyRejected else { message = "the band rejected this key. replace it in strap settings."; return }
        if !force, let last = lastAttempt ?? archive.lastSync, Date.now.timeIntervalSince(last) < 15 * 60 { return }
        lastAttempt = .now
        message = nil; diagnosticDetails = nil; transferMessage = nil; failedTypes = []; pending = true; busy = true; status = "connecting to strap…"
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.connectionFailed()
        }
        armTimeout(seconds: 25)
        requestConnection?()
    }

    /// Called only after all history/auth notification subscriptions succeed.
    func connected(maxWriteLength: Int) {
        self.maxWriteLength = maxWriteLength
        guard pending, let strapID, link == nil else { return }
        do {
            guard let key = try readKey(strapID) else { fail("add your band key to sync sleep."); return }
            link = ZeppLink(authKey: key, random: random, maxWriteLength: maxWriteLength)
            status = "connecting securely…"
            armTimeout(seconds: 20)
            let output = link!.startAuthentication()
            handle(output)
        } catch { fail("couldn’t read the band key. unlock your iPhone and try again.") }
    }

    func receive(_ bytes: [UInt8], characteristic: ZeppCharacteristic) {
        guard busy else { return }
        switch characteristic {
        case .chunkedRead, .chunkedWrite:
            guard link != nil else { return }
            let output = link!.receive(bytes)
            handle(output)
        case .activityControl:
            guard fetch != nil else { return }
            armTimeout(seconds: 45)
            let actions = fetch!.receiveControl(bytes); handle(actions)
        case .activityData:
            guard fetch != nil else { return }
            armTimeout(seconds: 45)
            let actions = fetch!.receiveData(bytes); handle(actions)
        default: break
        }
    }

    private func handle(_ output: ZeppLink.Output) {
        for write in output.writes { send?(write) }
        for event in output.events {
            guard busy else { break }
            switch event {
            case .authenticated:
                status = "reading strap…"
                armTimeout(seconds: 15)
                do { for write in try link!.send(endpoint: ZeppEndpoint.servicesList, payload: ZeppServicesList.request) { send?(write) } }
                catch { fail("couldn’t read this strap. try syncing again.") }
            case .authenticationFailed(let reason):
                keyRejected = reason == .wrongAuthKey
                fail(keyRejected ? "the band rejected this key. replace it in strap settings." : "couldn’t connect securely. close Zepp and try again.")
            case .message(let message):
                if message.wasEncrypted && message.trailerCRCMatches != true {
                    fail("the strap sent an incomplete reply. try syncing again."); return
                }
                if message.endpoint == ZeppEndpoint.servicesList, fetch == nil {
                    guard let list = ZeppServicesList.parse(message.payload) else { fail("this strap’s response isn’t supported yet."); return }
                    link?.apply(servicesList: list)
                    startFetch()
                }
            case .undecryptable, .droppedChunk:
                fail("the strap connection was interrupted. try syncing again.")
            case .deviceChunkAck: break
            }
        }
    }

    private func startFetch() {
        syncDate = .now
        let oldest = syncDate.addingTimeInterval(-7 * 86_400)
        let types: [ZeppFetchType] = [.sleepSession, .activity, .sleepRespiratoryRate]
        let plan: [(type: ZeppFetchType, since: Date)] = types.map { type in
            // Re-read recent sleep so a night extended by going back to bed can replace its earlier summary.
            let rewind: TimeInterval = type == .sleepSession ? 48 * 3_600 : 5 * 60
            let since = archive.cursors[String(type.rawValue)].map { max(oldest, min($0.addingTimeInterval(-rewind), syncDate)) } ?? oldest
            return (type, since)
        }
        fetch = ZeppHistoryFetch(plan: plan, now: syncDate,
            configuration: .init(ackPolicy: .keepOnDevice, maxRoundsPerType: 30, maxRetriesPerType: 1,
                                 maxRoundBytes: 1 << 20, maxRecordsPerRound: 15 * 1440))
        status = "syncing sleep…"; armTimeout(seconds: 45)
        let actions = fetch!.start(); handle(actions)
    }

    private func handle(_ actions: [ZeppHistoryFetch.Action]) {
        for action in actions {
            guard busy else { return }
            switch action {
            case .sendControl(let bytes):
                // Defense in depth: this app never acknowledges deletion, regardless of library policy.
                guard bytes != [0x03, 0x01] else { fail("couldn’t complete sleep sync."); return }
                send?(ZeppWrite(.activityControl, bytes))
            case .roundReady(let round):
                guard let strapID else { fail("choose your strap again."); return }
                do {
                    var updated = archive
                    let sleepIssue = try updated.merge(round, now: syncDate)
                    try repository.save(updated, strap: strapID)
                    archive = updated; revision += 1
                    if let sleepIssue {
                        failedTypes.insert(round.type.rawValue)
                        if transferMessage == nil {
                            transferMessage = sleepIssue.message(for: round.type)
                            diagnosticDetails = sleepIssue.diagnosticDetails
                        }
                        // Valid sessions are durable, but leave the cursor unchanged for the rejected record.
                        let next = fetch!.skipType(roundID: round.id); handle(next)
                    } else {
                        let next = fetch!.commit(roundID: round.id, durable: true); handle(next)
                    }
                } catch let error as HelioTransferError {
                    failedTypes.insert(round.type.rawValue)
                    if transferMessage == nil {
                        transferMessage = error.message(for: round.type)
                        diagnosticDetails = error.diagnosticDetails
                    }
                    // An unusable sleep record must not block the independent HR/breathing fetches.
                    // The uncommitted copy and cursor are discarded; the strap keeps the transfer.
                    let next = fetch!.skipType(roundID: round.id); handle(next)
                } catch {
                    fail("couldn’t save measurements on this iPhone. unlock it and check available storage, then retry.")
                }
            case .roundFailed(let type, _): failedTypes.insert(type.rawValue)
            case .noData: break
            case .finished:
                timeout?.cancel(); timeout = nil
                deadline?.cancel(); deadline = nil
                if failedTypes.isEmpty, let strapID {
                    do {
                        var updated = archive; updated.lastSync = .now
                        try repository.save(updated, strap: strapID); archive = updated
                    } catch { fail("sleep was read, but the sync status couldn’t be saved."); return }
                }
                status = failedTypes.isEmpty ? "synced from Helio Strap" : "some measurements couldn’t sync"
                if !failedTypes.isEmpty {
                    message = transferMessage ?? "some records weren’t available from the band. pull down to retry."
                }
                busy = false; pending = false; link = nil; fetch = nil; revision += 1
            }
        }
    }

    func connectionFailed() { if busy { fail("couldn’t reach the band. keep it nearby and close Zepp, then try again.") } }
    func disconnected() {
        maxWriteLength = nil
        if busy { fail("strap disconnected. your saved sleep is kept; pull down to retry.") }
        link = nil; fetch = nil
    }
    func shutdown() {
        timeout?.cancel(); timeout = nil
        deadline?.cancel(); deadline = nil
        let actions = fetch?.abort()
        pending = false; busy = false; link = nil; fetch = nil; maxWriteLength = nil
        cancelWrites?()
        if let actions {
            for case .sendControl(let bytes) in actions where bytes == [0x03, 0x09] { send?(ZeppWrite(.activityControl, bytes)) }
        }
    }
    private func fail(_ text: String) {
        shutdown(); status = "sleep sync paused"; message = text; diagnosticDetails = nil
    }
    private func armTimeout(seconds: Double) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.connectionFailed()
        }
    }
    private func readKey(_ id: UUID) throws -> ZeppAuthKey? {
        if let keyReader { return try keyReader(id) }
        return try HelioBandKeys.read(scope: repository.keyScope, strap: id)
    }
}
