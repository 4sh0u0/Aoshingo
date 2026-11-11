// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreBluetooth
import Foundation
import PICSKit

/// Bluetooth availability as shown to the user.
enum BluetoothAvailability: Sendable, Equatable {
    case unknown
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
    case resetting

    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

/// A PICS advertisement copied out of CoreBluetooth's non-Sendable dictionary.
struct ReceivedAdvertisement: Sendable {
    var timestamp: Date
    /// `CBAdvertisementDataManufacturerDataKey`, including the leading `CE 01` company identifier.
    var manufacturerData: [UInt8]
    var rssi: Int
    var serviceUUIDs: [String]
    var localName: String?
    var txPower: Int?
    var isConnectable: Bool?
    /// Per-phone identifier of the transmitter. Never uploaded; recordings replace it with an alias.
    var peripheralID: UUID
    /// Distinct non-PICS Bluetooth devices seen in the last `NearbyDeviceCounter.window`, a rough
    /// measure of how crowded the place is. Only a coarse bucket of it is uploaded with field data.
    var nearbyDevices: Int? = nil
}

enum ScannerEvent: Sendable {
    case availability(BluetoothAvailability)
    case advertisement(ReceivedAdvertisement)
}

/// Foreground-only, receive-only scanner for 高度化PICS advertisements.
///
/// It never connects to a peripheral and never transmits. iOS only delivers manufacturer-data-only
/// advertisements while the app is in the foreground, so the UI must say so.
final class PICSScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    // All mutable state below is only touched on `queue`.
    private let queue = DispatchQueue(label: "es.4sh.aoshingo.scanner", qos: .userInitiated)
    private var central: CBCentralManager?
    private var wantsScanning = false
    private var continuation: AsyncStream<ScannerEvent>.Continuation?
    private let counters = Counters()
    private var nearby = NearbyDeviceCounter()

    /// Events for the main actor. Only one consumer is supported.
    let events: AsyncStream<ScannerEvent>

    override init() {
        var continuation: AsyncStream<ScannerEvent>.Continuation?
        // Keep the newest events if the main actor falls behind; old advertisements are worthless.
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        super.init()
        self.continuation = continuation
    }

    /// Advertisements seen from other manufacturers, for the "Bluetooth works" check.
    var otherAdvertisementCount: Int { counters.other }

    /// Starts scanning; creates the central manager on first use so the Bluetooth permission prompt
    /// appears only when the user asks to receive.
    func start() {
        queue.async { [self] in
            wantsScanning = true
            if central == nil {
                central = CBCentralManager(
                    delegate: self,
                    queue: queue,
                    options: [CBCentralManagerOptionShowPowerAlertKey: true]
                )
            } else {
                startScanIfPossible()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            wantsScanning = false
            if central?.isScanning == true { central?.stopScan() }
            nearby = NearbyDeviceCounter()
        }
    }

    private func startScanIfPossible() {
        guard wantsScanning, let central, central.state == .poweredOn, !central.isScanning else { return }
        // No service filter and duplicates allowed: PICS advertises only manufacturer data, and every
        // repeat carries a new signal state. This only works in the foreground. The same advertisement
        // can be delivered more than once; SignalDebouncer does not count such repeats as confirmation.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    // MARK: - CBCentralManagerDelegate (called on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        continuation?.yield(.availability(BluetoothAvailability(central.state)))
        startScanIfPossible()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let now = Date()
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 2,
              PICSParser.companyID(ofManufacturerData: data) == PICS.companyID
        else {
            counters.incrementOther()
            nearby.saw(peripheral.identifier, at: now)
            return
        }
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        continuation?.yield(.advertisement(ReceivedAdvertisement(
            timestamp: now,
            manufacturerData: Array(data),
            rssi: RSSI.intValue,
            serviceUUIDs: serviceUUIDs.map(\.uuidString),
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            txPower: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
            peripheralID: peripheral.identifier,
            nearbyDevices: nearby.count(at: now)
        )))
    }
}

/// Counts distinct devices seen recently. The identifiers are CoreBluetooth's per-app aliases; they
/// stay in memory for at most `window` (plus the pruning interval) and are never stored or sent.
/// Devices that rotate their address may be counted more than once, so this is only an estimate.
struct NearbyDeviceCounter {
    static let window: TimeInterval = 30
    /// Pruning walks the whole table, so it runs at most this often however many advertisements arrive.
    static let pruneInterval: TimeInterval = 1

    private var lastSeen: [UUID: Date] = [:]
    private var lastPrune = Date.distantPast

    mutating func saw(_ id: UUID, at time: Date) {
        lastSeen[id] = time
        pruneIfDue(at: time)
    }

    mutating func count(at time: Date) -> Int {
        pruneIfDue(at: time)
        return lastSeen.values.reduce(0) { $0 + (time.timeIntervalSince($1) <= Self.window ? 1 : 0) }
    }

    private mutating func pruneIfDue(at time: Date) {
        guard time.timeIntervalSince(lastPrune) >= Self.pruneInterval else { return }
        lastPrune = time
        lastSeen = lastSeen.filter { time.timeIntervalSince($0.value) <= Self.window }
    }
}

/// Thread-safe counter for advertisements from other manufacturers.
private final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var otherCount = 0

    var other: Int { lock.withLock { otherCount } }

    func incrementOther() { lock.withLock { otherCount += 1 } }
}
