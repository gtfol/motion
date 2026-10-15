import CoreBluetooth
import Foundation
import Observation
@preconcurrency import ZeppKit

enum StrapStatus: Equatable, Sendable {
    case noStrap
    case bluetoothOff
    case bluetoothDenied
    case bluetoothUnavailable
    /// Waiting for the chosen strap. A pending connection doesn't time out; iOS completes it when the strap is in range.
    case searching
    case connected
    /// Connected, but the strap offers no heart-rate service (Heart Rate Push is probably off in Zepp).
    case noHeartRateService
    /// Lost after being connected; reconnecting automatically.
    case reconnecting

    var label: String {
        switch self {
        case .noStrap: "no strap chosen"
        case .bluetoothOff: "disconnected · Bluetooth is off"
        case .bluetoothDenied: "disconnected · Bluetooth access is off for motion"
        case .bluetoothUnavailable: "Bluetooth isn’t available"
        case .searching: "searching"
        case .connected: "connected"
        case .noHeartRateService: "connected, no heart rate"
        case .reconnecting: "reconnecting"
        }
    }
}

struct StrapCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var rssi: Int?
    /// Already connected to this iPhone, for example by Zepp. Such a strap may not advertise.
    var connectedToPhone: Bool
}

/// Reads the standard Bluetooth Heart Rate service (0x180D) from the one strap the user chose.
/// It never connects to an arbitrary nearby device. Callbacks arrive on the main queue.
@MainActor @Observable final class HeartRateMonitor: NSObject {
    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private(set) var status: StrapStatus
    private(set) var strapID: UUID?
    private(set) var strapName: String?
    /// Last battery level the strap reported. A strap without the Battery service is still a working strap.
    private(set) var batteryPercent: Int?
    private(set) var latest: HeartRateReading?
    private(set) var sensorContact: SensorContact?
    private(set) var candidates: [StrapCandidate] = []
    private(set) var isChoosing = false
    /// When the connection to the chosen strap was lost; nil while connected.
    private(set) var lostAt: Date?

    @ObservationIgnored var onReading: ((HeartRateReading) -> Void)?
    @ObservationIgnored var onSelectionChange: ((UUID?, String?) -> Void)?

    @ObservationIgnored private weak var helio: HelioSleepSync?
    @ObservationIgnored private var helioCharacteristics: [ZeppCharacteristic: CBCharacteristic] = [:]
    @ObservationIgnored private var helioWrites: [ZeppWrite] = []
    @ObservationIgnored private var helioWritePending = false

    func configureHelio(_ sync: HelioSleepSync) {
        helio = sync
        sync.select(id: strapID, name: strapName)
        sync.send = { [weak self] write in self?.queueHelio(write) }
        sync.cancelWrites = { [weak self] in self?.helioWrites.removeAll() }
        sync.requestConnection = { [weak self] in
            guard let self else { return }
            self.activate()
            if let peripheral = self.peripheral, peripheral.state == .connected {
                if self.helioCharacteristics.isEmpty {
                    peripheral.discoverServices([Self.heartRateService, Self.batteryService, CBUUID(string: ZeppGATT.mainServiceUUID)])
                } else { self.prepareHelio(peripheral) }
            } else { self.connectToChosenStrap() }
        }
    }

    private func prepareHelio(_ peripheral: CBPeripheral) {
        guard helio?.busy == true else { return }
        let required: [ZeppCharacteristic] = [.chunkedWrite, .chunkedRead, .activityControl, .activityData]
        guard required.allSatisfy({ helioCharacteristics[$0] != nil }) else { helio?.connectionFailed(); return }
        for key in [ZeppCharacteristic.chunkedRead, .activityControl, .activityData] {
            guard let characteristic = helioCharacteristics[key], characteristic.properties.contains(.notify) else {
                helio?.connectionFailed(); return
            }
            if !characteristic.isNotifying { peripheral.setNotifyValue(true, for: characteristic) }
        }
        if let ack = helioCharacteristics[.chunkedWrite], ack.properties.contains(.notify), !ack.isNotifying {
            peripheral.setNotifyValue(true, for: ack)
        }
        helioReady(peripheral)
    }

    private func helioReady(_ peripheral: CBPeripheral) {
        guard [.chunkedRead, .activityControl, .activityData].allSatisfy({ helioCharacteristics[$0]?.isNotifying == true }),
              let write = helioCharacteristics[.chunkedWrite] else { return }
        let type: CBCharacteristicWriteType = write.properties.contains(.write) ? .withResponse : .withoutResponse
        helio?.connected(maxWriteLength: min(512, peripheral.maximumWriteValueLength(for: type)))
    }

    private func queueHelio(_ write: ZeppWrite) {
        guard [.chunkedWrite, .chunkedRead, .activityControl].contains(write.characteristic),
              write.bytes != [0x03, 0x01], helioWrites.count < 4096 else { helio?.connectionFailed(); return }
        helioWrites.append(write)
        drainHelioWrites()
    }

    private func drainHelioWrites() {
        guard !helioWritePending, let peripheral, peripheral.state == .connected else { return }
        while let write = helioWrites.first {
            guard let characteristic = helioCharacteristics[write.characteristic] else { helio?.connectionFailed(); return }
            let type: CBCharacteristicWriteType
            if characteristic.properties.contains(.write) { type = .withResponse }
            else if characteristic.properties.contains(.writeWithoutResponse) {
                guard peripheral.canSendWriteWithoutResponse else { return }
                type = .withoutResponse
            } else { helio?.connectionFailed(); return }
            guard write.bytes.count <= peripheral.maximumWriteValueLength(for: type) else { helio?.connectionFailed(); return }
            helioWrites.removeFirst()
            helioWritePending = type == .withResponse
            peripheral.writeValue(Data(write.bytes), for: characteristic, type: type)
            if helioWritePending { return }
        }
    }

    private func resetHelioConnection() {
        helioCharacteristics = [:]; helioWrites = []; helioWritePending = false
        helio?.disconnected()
    }

    @ObservationIgnored private let restoreIdentifier: String
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var discovered: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var scanningForStrap = false
    @ObservationIgnored private var hasConnected = false
    @ObservationIgnored private var retry: Task<Void, Never>?

    init(restoreIdentifier: String, strapID: UUID?, strapName: String?) {
        self.restoreIdentifier = restoreIdentifier
        self.strapID = strapID
        self.strapName = strapName
        self.status = strapID == nil ? .noStrap : .searching
        super.init()
    }

    var isActivated: Bool { central != nil }

    /// Creates the central manager, which can show the Bluetooth permission prompt. Called at launch only if a
    /// strap was chosen before (this also lets iOS restore the connection), otherwise when choosing a strap.
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    /// Lists nearby straps advertising heart rate, plus heart-rate straps already connected to this iPhone.
    func startChoosing() {
        isChoosing = true
        candidates = []
        activate()
        if central?.state == .poweredOn { beginScan() }
    }

    func stopChoosing() {
        isChoosing = false
        if !scanningForStrap { central?.stopScan() }
    }

    func choose(_ candidate: StrapCandidate) {
        if let current = peripheral, current.identifier != candidate.id { central?.cancelPeripheralConnection(current) }
        strapID = candidate.id
        strapName = candidate.name
        peripheral = discovered[candidate.id]
        batteryPercent = nil; latest = nil; sensorContact = nil; hasConnected = false; lostAt = nil
        resetHelioConnection()
        helio?.select(id: strapID, name: strapName)
        onSelectionChange?(strapID, strapName)
        stopChoosing()
        connectToChosenStrap()
    }

    /// Release the old account's monitor without changing its saved strap selection.
    func shutdown() {
        helio?.shutdown()
        resetHelioConnection()
        retry?.cancel(); retry = nil
        onReading = nil; onSelectionChange = nil
        central?.delegate = nil; peripheral?.delegate = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; central = nil
    }

    func forget() {
        retry?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; strapID = nil; strapName = nil
        batteryPercent = nil; latest = nil; sensorContact = nil; hasConnected = false; lostAt = nil
        scanningForStrap = false
        if !isChoosing { central?.stopScan() }
        resetHelioConnection()
        helio?.select(id: nil, name: nil)
        status = .noStrap
        onSelectionChange?(nil, nil)
    }

    /// Drops and re-requests the connection to the chosen strap.
    func reconnect() {
        activate()
        if let peripheral, peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral) // didDisconnect requests a new connection
        } else {
            connectToChosenStrap()
        }
    }

    // MARK: Connection

    private func connectToChosenStrap() {
        retry?.cancel()
        guard let strapID else { status = .noStrap; return }
        guard let central, central.state == .poweredOn else { return }
        var target = peripheral?.identifier == strapID ? peripheral : nil
        if target == nil { target = central.retrievePeripherals(withIdentifiers: [strapID]).first }
        if target == nil {
            target = central.retrieveConnectedPeripherals(withServices: [Self.heartRateService, CBUUID(string: ZeppGATT.mainServiceUUID)]).first(where: { $0.identifier == strapID })
        }
        guard let target else {
            // iOS no longer knows this identifier (for example after a Bluetooth reset): scan, but only accept this strap.
            scanningForStrap = true
            status = hasConnected ? .reconnecting : .searching
            beginScan()
            return
        }
        peripheral = target
        target.delegate = self
        status = hasConnected ? .reconnecting : .searching
        // Even a strap the system already has connected (restored, or held by another app) needs motion' own
        // connect before its services can be used; for a connected strap, iOS reports it right away.
        if target.state != .connecting { central.connect(target, options: nil) }
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        if isChoosing {
            for connected in central.retrieveConnectedPeripherals(withServices: [Self.heartRateService, CBUUID(string: ZeppGATT.mainServiceUUID)]) {
                discovered[connected.identifier] = connected
                upsertCandidate(StrapCandidate(id: connected.identifier, name: connected.name ?? "heart rate strap",
                                               rssi: nil, connectedToPhone: true))
            }
        }
        central.scanForPeripherals(withServices: [Self.heartRateService, CBUUID(string: ZeppGATT.mainServiceUUID)], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func upsertCandidate(_ candidate: StrapCandidate) {
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index].rssi = candidate.rssi ?? candidates[index].rssi
            if candidates[index].name == "heart rate strap" { candidates[index].name = candidate.name }
        } else {
            candidates.append(candidate)
        }
    }

    private func handleState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if isChoosing || scanningForStrap { beginScan() }
            connectToChosenStrap()
        case .poweredOff:
            if status == .connected || status == .noHeartRateService { lostAt = .now }
            // iOS invalidates peripherals when Bluetooth turns off; retrieve the strap again when it's back on.
            resetHelioConnection()
            peripheral = nil; latest = nil; sensorContact = nil
            status = strapID == nil ? .noStrap : .bluetoothOff
        case .unauthorized:
            status = .bluetoothDenied
        case .unsupported:
            status = .bluetoothUnavailable
        default:
            break // .unknown and .resetting are transient; a later update follows.
        }
    }

    private func restore(_ peripherals: [CBPeripheral]) {
        guard let strapID, let restored = peripherals.first(where: { $0.identifier == strapID }) else { return }
        peripheral = restored
        restored.delegate = self
    }

    private func didDiscover(_ found: CBPeripheral, name: String?, rssi: Int) {
        discovered[found.identifier] = found
        if isChoosing {
            upsertCandidate(StrapCandidate(id: found.identifier, name: name ?? "heart rate strap", rssi: rssi, connectedToPhone: false))
        }
        if scanningForStrap, found.identifier == strapID {
            scanningForStrap = false
            if !isChoosing { central?.stopScan() }
            peripheral = found
            found.delegate = self
            central?.connect(found, options: nil)
        }
    }

    private func didConnect(_ connected: CBPeripheral) {
        guard connected.identifier == strapID else {
            central?.cancelPeripheralConnection(connected)
            return
        }
        hasConnected = true
        lostAt = nil
        status = .connected
        if scanningForStrap {
            scanningForStrap = false
            if !isChoosing { central?.stopScan() }
        }
        if strapName == nil, let name = connected.name { strapName = name; onSelectionChange?(strapID, name) }
        connected.delegate = self
        helioCharacteristics = [:]; helioWrites = []; helioWritePending = false
        connected.discoverServices([Self.heartRateService, Self.batteryService, CBUUID(string: ZeppGATT.mainServiceUUID)])
    }

    private func didLose(_ lost: CBPeripheral) {
        guard lost.identifier == strapID else { return }
        if lostAt == nil { lostAt = .now }
        resetHelioConnection()
        latest = nil; sensorContact = nil
        status = hasConnected ? .reconnecting : .searching
        connectToChosenStrap()
    }

    private func didFail(_ failed: CBPeripheral) {
        guard failed.identifier == strapID else { return }
        helio?.connectionFailed()
        status = hasConnected ? .reconnecting : .searching
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.connectToChosenStrap()
        }
    }

    private func discoveredServices(_ connected: CBPeripheral) {
        guard connected.identifier == strapID else { return }
        let services = connected.services ?? []
        if !services.contains(where: { $0.uuid == Self.heartRateService }) { status = .noHeartRateService }
        for service in services {
            if service.uuid == Self.heartRateService { connected.discoverCharacteristics([Self.heartRateMeasurement], for: service) }
            if service.uuid == CBUUID(string: ZeppGATT.mainServiceUUID) { connected.discoverCharacteristics(nil, for: service) }
            if service.uuid == Self.batteryService { connected.discoverCharacteristics([Self.batteryLevel], for: service) }
        }
    }

    private func discoveredCharacteristics(_ connected: CBPeripheral, service: CBService) {
        guard connected.identifier == strapID else { return }
        for characteristic in service.characteristics ?? [] {
            if let key = ZeppCharacteristic.allCases.first(where: { CBUUID(string: $0.uuidString) == characteristic.uuid }) {
                helioCharacteristics[key] = characteristic
            }
            if characteristic.uuid == Self.heartRateMeasurement {
                connected.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == Self.batteryLevel {
                if characteristic.properties.contains(.read) { connected.readValue(for: characteristic) }
                if characteristic.properties.contains(.notify) { connected.setNotifyValue(true, for: characteristic) }
            }
        }
        if service.uuid == CBUUID(string: ZeppGATT.mainServiceUUID) { prepareHelio(connected) }
    }

    private func received(_ data: Data, from characteristic: CBUUID, peripheral source: UUID, at date: Date) {
        guard source == strapID else { return }
        if let key = ZeppCharacteristic.allCases.first(where: { CBUUID(string: $0.uuidString) == characteristic }) {
            helio?.receive(Array(data), characteristic: key)
        }
        if characteristic == Self.batteryLevel {
            if let level = BatteryLevel.parse(data) { batteryPercent = level }
            return
        }
        guard characteristic == Self.heartRateMeasurement, let measurement = HeartRateMeasurement.parse(data) else { return }
        sensorContact = measurement.sensorContact
        guard measurement.isPlausible else { return } // 0 means the strap has no reading; nothing is stored.
        let reading = HeartRateReading(peripheralID: source, receivedAt: date, measurement: measurement)
        latest = reading
        onReading?(reading)
    }
}

/// CoreBluetooth calls back on the main queue (the manager is created with `queue: nil`), so its objects never
/// actually change threads here. This box states that to Swift's checker when handing them to main-actor code.
private struct MainQueueValue<Value>: @unchecked Sendable {
    let value: Value
}

extension HeartRateMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { handleState(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = MainQueueValue(value: dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [])
        MainActor.assumeIsolated { restore(peripherals.value) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let rssi = RSSI.intValue, found = MainQueueValue(value: peripheral)
        MainActor.assumeIsolated { didDiscover(found.value, name: name, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let connected = MainQueueValue(value: peripheral)
        MainActor.assumeIsolated { didConnect(connected.value) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let failed = MainQueueValue(value: peripheral)
        MainActor.assumeIsolated { didFail(failed.value) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        let lost = MainQueueValue(value: peripheral)
        MainActor.assumeIsolated { didLose(lost.value) }
    }
}

extension HeartRateMonitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let connected = MainQueueValue(value: peripheral), failed = error != nil, uuid = characteristic.uuid.uuidString
        MainActor.assumeIsolated {
            guard connected.value.identifier == strapID else { return }
            let required: [ZeppCharacteristic] = [.chunkedRead, .activityControl, .activityData]
            if failed {
                if required.contains(where: { CBUUID(string: $0.uuidString).uuidString == uuid }) { helio?.connectionFailed() }
            } else { helioReady(connected.value) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let id = peripheral.identifier, failed = error != nil
        MainActor.assumeIsolated {
            guard id == strapID else { return }
            helioWritePending = false
            if failed { helio?.connectionFailed() } else { drainHelioWrites() }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { if id == strapID { drainHelioWrites() } }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let connected = MainQueueValue(value: peripheral), failed = error != nil
        MainActor.assumeIsolated {
            guard connected.value.identifier == strapID else { return }
            if failed { helio?.connectionFailed() } else { discoveredServices(connected.value) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let connected = MainQueueValue(value: peripheral), discovered = MainQueueValue(value: service), failed = error != nil
        MainActor.assumeIsolated {
            guard connected.value.identifier == strapID else { return }
            if failed { helio?.connectionFailed() } else { discoveredCharacteristics(connected.value, service: discovered.value) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = MainQueueValue(value: characteristic.uuid), source = peripheral.identifier, date = Date.now
        MainActor.assumeIsolated { received(data, from: uuid.value, peripheral: source, at: date) }
    }
}
