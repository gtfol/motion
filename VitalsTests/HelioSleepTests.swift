import XCTest
import ZeppKit
import ZeppKitTesting
@testable import Vitals

/// Synthetic wire records and fake credentials only. The real strap still needs a device check.
final class HelioSleepTests: XCTestCase {
    private let strap = UUID()
    private let key = [UInt8](repeating: 0x42, count: 16)

    @MainActor private final class Rig {
        let sync: HelioSleepSync
        let device: FakeZeppDevice
        var writes: [ZeppWrite] = []
        init(sync: HelioSleepSync, device: FakeZeppDevice) {
            self.sync = sync; self.device = device
            sync.send = { [weak self] in self?.writes.append($0) }
            sync.cancelWrites = { [weak self] in self?.writes.removeAll() }
            sync.requestConnection = { [weak sync] in sync?.connected(maxWriteLength: 20) }
        }
        func run(stopBeforeData: Bool = false) {
            sync.sync(force: true)
            var count = 0
            while !writes.isEmpty && count < 1000 {
                count += 1
                let write = writes.removeFirst()
                if stopBeforeData && write.characteristic == .activityControl && write.bytes == [2] { break }
                for notification in device.phoneWrote(write) {
                    sync.receive(notification.bytes, characteristic: notification.characteristic)
                }
            }
            XCTAssertLessThan(count, 1000)
            XCTAssertTrue(device.fetchAcks.allSatisfy { $0 == 9 }, "never erase band history")
            XCTAssertEqual(device.timeSetCount, 0)
            XCTAssertTrue(device.configWrites.isEmpty)
            XCTAssertTrue(device.alarmCommands.isEmpty)
            XCTAssertTrue(device.receivedEndpoints.allSatisfy { [0, 0x82].contains($0) })
            XCTAssertTrue(device.failures.isEmpty, device.failures.joined(separator: ", "))
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func rig(_ directory: URL, wrongKey: Bool = false) -> Rig {
        let bytes = key
        let sync = HelioSleepSync(directory: directory, keyReader: { _ in
            ZeppAuthKey(bytes: wrongKey ? [UInt8](repeating: 0x99, count: 16) : bytes)
        }, random: ZeppRandom { count in (0..<count).map { UInt8($0 + 1) } })
        sync.select(id: strap, name: "Amazfit Helio Strap")
        let device = FakeZeppDevice(authKey: key, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: [UInt8](repeating: 0xf0, count: 16))
        return Rig(sync: sync, device: device)
    }

    private var midnight: Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: Date.now).addingTimeInterval(-86_400)
    }
    private func le(_ value: UInt32, count: Int = 4) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    private func sleepBytes(invalid: Bool = false, endMinute: UInt32 = 1800) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 594)
        func put(_ value: UInt32, _ offset: Int, _ length: Int = 4) {
            bytes.replaceSubrange(offset..<(offset + length), with: le(value, count: length))
        }
        put(UInt32(midnight.timeIntervalSince1970 + 8 * 3600), 0)
        put(UInt32(midnight.timeIntervalSince1970), 4)
        put(1320, 0x0a, 2); put(endMinute, 0x0c, 2)
        bytes[0x54] = 3
        let stages: [(UInt32, UInt32, UInt8)] = [(1320, 1440, 5), (1440, 1500, 7), (1500, endMinute, 8)]
        for (i, stage) in stages.enumerated() {
            let offset = 0x56 + i * 5
            put(stage.0, offset, 2); put(stage.1, offset + 2, 2); bytes[offset + 4] = stage.2
        }
        if invalid { put(1319, 0x58, 2) } // end before start: valid CRC, invalid content
        return bytes
    }
    @MainActor private func installSleep(_ rig: Rig, invalid: Bool = false, endMinute: UInt32 = 1800) {
        rig.device.fetchData[.sleepSession] = (ZeppFetchTimestamp.encode(midnight, timeZone: TimeZone(secondsFromGMT: 0)!), sleepBytes(invalid: invalid, endMinute: endMinute))
    }

    @MainActor func testAuthenticationFetchPersistenceAndReplay() throws {
        let directory = try directory(), rig = rig(directory)
        installSleep(rig)
        let readingDate = midnight.addingTimeInterval(-3600)
        let start = ZeppFetchTimestamp.encode(readingDate, timeZone: TimeZone(secondsFromGMT: 0)!)
        // Minute activity: kind, intensity, steps, heart rate, reserved, reserved.
        rig.device.fetchData[.activity] = (start, [0, 0, 0, 55, 0, 0, 0, 0])
        rig.device.fetchData[.sleepRespiratoryRate] = (start, le(UInt32(readingDate.timeIntervalSince1970)) + [0, 13, 0, 0])
        rig.run()
        XCTAssertTrue(rig.device.authenticated)
        XCTAssertFalse(rig.sync.busy)
        XCTAssertNil(rig.sync.message)
        XCTAssertNotNil(rig.sync.archive.lastSync)
        XCTAssertEqual(rig.sync.archive.nights.count, 1)
        XCTAssertEqual(rig.sync.archive.nights.first?.asleepDuration, 7 * 3600)
        XCTAssertEqual(rig.sync.archive.nights.first?.duration(.awake), 3600)
        XCTAssertEqual(rig.sync.archive.heartRate.first?.value, 55)
        XCTAssertEqual(rig.sync.archive.respiratoryRate.first?.value, 13)
        let restored = self.rig(directory)
        XCTAssertEqual(restored.sync.archive.nights.flatMap(\.segments), rig.sync.archive.nights.flatMap(\.segments))
        installSleep(restored, endMinute: 1860)
        restored.run()
        XCTAssertEqual(restored.sync.archive.sessions.count, 1, "revised night replaces old session")
        XCTAssertEqual(restored.sync.archive.nights.first?.asleepDuration, 8 * 3600)
    }

    @MainActor func testBadKeyStopsBeforeHistoryAndRequiresReplacement() throws {
        let rig = rig(try directory(), wrongKey: true)
        rig.run()
        XCTAssertFalse(rig.sync.busy)
        XCTAssertTrue(rig.sync.message?.contains("rejected this key") == true)
        XCTAssertTrue(rig.device.fetchStarts.isEmpty)
        rig.sync.sync(force: true)
        XCTAssertFalse(rig.sync.busy)
        XCTAssertTrue(rig.writes.isEmpty)
    }

    @MainActor func testInvalidAndCorruptTransfersKeepSavedNightAndCursor() throws {
        let directory = try directory(), baseline = rig(directory)
        installSleep(baseline); baseline.run()
        let saved = baseline.sync.archive
        for mode in 0..<3 {
            let broken = rig(directory)
            installSleep(broken, invalid: mode == 0, endMinute: 1860)
            broken.device.corruptCRC = mode == 1
            broken.device.includeCRC = mode != 2
            broken.run()
            XCTAssertEqual(broken.sync.archive.nights.flatMap(\.segments), saved.nights.flatMap(\.segments))
            XCTAssertEqual(broken.sync.archive.cursors, saved.cursors)
            XCTAssertEqual(broken.sync.archive.lastSync, saved.lastSync)
            XCTAssertNotNil(broken.sync.message)
        }
    }

    @MainActor func testDisconnectKeepsSavedDataAndReleasesTransferWithoutDeleting() throws {
        let directory = try directory(), baseline = rig(directory)
        installSleep(baseline); baseline.run()
        let next = rig(directory); installSleep(next, endMinute: 1860)
        next.run(stopBeforeData: true)
        XCTAssertTrue(next.sync.busy)
        next.sync.disconnected()
        XCTAssertFalse(next.sync.busy)
        XCTAssertEqual(next.sync.archive.nights.flatMap(\.segments), baseline.sync.archive.nights.flatMap(\.segments))
        XCTAssertEqual(next.writes.last?.bytes, [3, 9])
    }

    @MainActor func testAccountAndStrapIsolationAndStableKeyScope() throws {
        let directory = try directory(), first = rig(directory)
        installSleep(first); first.run()
        let otherAccount = rig(try self.directory())
        XCTAssertTrue(otherAccount.sync.archive.nights.isEmpty)
        first.sync.select(id: UUID(), name: "Amazfit Helio Strap")
        XCTAssertTrue(first.sync.archive.nights.isEmpty)
        let account = UUID().uuidString
        let a = HelioSleepRepository(directory: URL(fileURLWithPath: "/old/Library/Application Support/accounts/\(account)"))
        let b = HelioSleepRepository(directory: URL(fileURLWithPath: "/new/Library/Application Support/accounts/\(account)"))
        XCTAssertEqual(a.keyScope, b.keyScope, "iOS updates can change the container URL")
        XCTAssertNotEqual(a.keyScope, HelioSleepRepository(directory: directory).keyScope)
    }

    @MainActor func testUnreadableStorageIsNeverOverwrittenAndCanRecover() throws {
        let directory = try directory(), repository = HelioSleepRepository(directory: directory)
        try repository.save(HelioSleepArchive(), strap: strap)
        let corrupt = Data("incomplete archive".utf8)
        try corrupt.write(to: repository.url(strap))
        let rig = rig(directory)
        rig.run()
        XCTAssertTrue(rig.device.receivedEndpoints.isEmpty)
        XCTAssertEqual(try Data(contentsOf: repository.url(strap)), corrupt)
        XCTAssertNotNil(rig.sync.message)
        // Simulate storage becoming readable after unlock/recovery.
        try repository.save(HelioSleepArchive(), strap: strap)
        installSleep(rig); rig.run()
        XCTAssertEqual(rig.sync.archive.nights.count, 1)
        XCTAssertNil(rig.sync.message)
        let day = try XCTUnwrap(rig.sync.archive.nights.first?.day)
        XCTAssertEqual(rig.sync.archive.nights(endingOn: day).first?.asleepDuration, 7 * 3600)
        XCTAssertTrue(rig.sync.archive.nights(endingOn: day.addingTimeInterval(20 * 86400)).isEmpty)
    }
}
