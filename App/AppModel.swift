// SPDX-License-Identifier: Apache-2.0

import FieldDataKit
import Foundation
import Observation
import PICSKit
import UIKit

/// App state: where packets come from, what we know about each intersection, and what is shown.
@MainActor
@Observable
final class AppModel {
    enum Source: Equatable {
        case idle
        /// Real advertisements from the Bluetooth scanner.
        case live
        /// Synthetic packets decoded by the same parser. Always labelled デモ.
        case demo
        /// A recording being played back. Always labelled as playback.
        case replay(name: String)

        var isSynthetic: Bool {
            switch self {
            case .demo, .replay: true
            case .idle, .live: false
            }
        }
    }

    private(set) var source: Source = .idle
    private(set) var bluetooth: BluetoothAvailability = .unknown
    private(set) var store = IntersectionStore()
    /// Debounced signals per intersection (danger at once, safety after two packets at least 0.5 s apart).
    private(set) var confirmed: [String: [PedestrianSignal?]] = [:]
    private(set) var picsPacketCount = 0
    private(set) var otherAdvertisementCount = 0
    private(set) var rejectedPacketCount = 0
    private(set) var lastRejection: String?
    private(set) var isRecording = false
    private(set) var recordingError: String?
    /// Set when the app returned from the background while receiving: nothing was received meanwhile.
    private(set) var missedWhileInBackground = false
    /// `nil` follows the nearest intersection automatically.
    var selectedID: String?

    var keepScreenOn: Bool = UserDefaults.standard.object(forKey: SettingsKey.keepScreenOn) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepScreenOn, forKey: SettingsKey.keepScreenOn)
            updateIdleTimer()
        }
    }

    let field = FieldDataModel()

    @ObservationIgnored private let scanner = PICSScanner()
    @ObservationIgnored private let recorder = AdvertisementRecorder()
    @ObservationIgnored private var debouncers: [String: SlotDebouncers] = [:]
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var counterTask: Task<Void, Never>?

    init() {
        eventsTask = Task { [weak self, events = scanner.events] in
            for await event in events {
                self?.handle(event)
            }
        }
        let stored = UserDefaults.standard.string(forKey: SettingsKey.collectionConsent)
        let consent = stored.flatMap(CollectionConsent.init(rawValue:)) ?? .undecided
        Task { await field.apply(consent) }
    }

    var isActive: Bool { source != .idle }

    /// The intersection to show: the user's choice, else the nearest one heard recently, else the last one.
    func displayedIntersection(at now: Date) -> IntersectionState? {
        if let selectedID, let state = store[selectedID] { return state }
        return store.nearest(at: now) ?? store.all.last
    }

    func confirmedSignals(for id: String) -> [PedestrianSignal?] {
        confirmed[id] ?? []
    }

    // MARK: - Sources

    func startLive() {
        begin(.live)
        scanner.start()
        field.setReceiving(true)
        counterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.otherAdvertisementCount = self.scanner.otherAdvertisementCount
            }
        }
    }

    func startDemo() {
        begin(.demo)
        let peripheral = UUID()
        playbackTask = Task { [weak self] in
            var step = 0
            while !Task.isCancelled {
                for data in DemoAdvertiser.manufacturerData(step: step) {
                    self?.ingest(ReceivedAdvertisement(
                        timestamp: Date(), manufacturerData: data, rssi: -60, serviceUUIDs: [],
                        localName: nil, txPower: nil, isConnectable: false, peripheralID: peripheral
                    ))
                }
                step += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Plays a JSON Lines recording with its original timing (gaps longer than 10 s are shortened).
    func startReplay(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            lastRejection = String(localized: "記録ファイルを読み込めませんでした。")
            return
        }
        let records = RecordingFormat.decode(data).records.sorted { $0.t < $1.t }
        begin(.replay(name: url.lastPathComponent))
        playbackTask = Task { [weak self] in
            var peripherals: [String: UUID] = [:]
            var previous: Double?
            for record in records {
                if let previous {
                    try? await Task.sleep(for: .seconds(min(10, max(0, record.t - previous))))
                }
                previous = record.t
                guard !Task.isCancelled, let bytes = record.bytes else { continue }
                let alias = record.emitter ?? "E0"
                let peripheral = peripherals[alias] ?? UUID()
                peripherals[alias] = peripheral
                self?.ingest(ReceivedAdvertisement(
                    timestamp: Date(), manufacturerData: bytes, rssi: record.rssi ?? 127,
                    serviceUUIDs: record.serviceUUIDs ?? [], localName: record.localName,
                    txPower: record.txPower, isConnectable: record.connectable, peripheralID: peripheral
                ))
            }
        }
    }

    func stop() {
        let wasLive = source == .live
        scanner.stop()
        field.setReceiving(false)
        playbackTask?.cancel()
        playbackTask = nil
        counterTask?.cancel()
        counterTask = nil
        if isRecording { setRecording(false) }
        source = .idle
        updateIdleTimer()
        if wasLive { Task { await field.flushAndUpload(force: true) } }
    }

    /// Starting a new source clears what was received before, as the Web version does.
    private func begin(_ newSource: Source) {
        stop()
        store.removeAll()
        debouncers.removeAll()
        confirmed.removeAll()
        selectedID = nil
        picsPacketCount = 0
        rejectedPacketCount = 0
        lastRejection = nil
        missedWhileInBackground = false
        source = newSource
        updateIdleTimer()
    }

    // MARK: - Scene phase

    func sceneDidEnterBackground() {
        guard source == .live else { return }
        missedWhileInBackground = true
        field.sceneDidEnterBackground()
    }

    func sceneDidBecomeActive() {
        if source == .live { scanner.start() }
        updateIdleTimer()
    }

    func dismissBackgroundNotice() {
        missedWhileInBackground = false
    }

    // MARK: - Recording

    func setRecording(_ enabled: Bool) {
        Task {
            do {
                if enabled {
                    try await recorder.start()
                } else {
                    await recorder.stop()
                }
                isRecording = enabled
                recordingError = nil
            } catch {
                isRecording = false
                recordingError = error.localizedDescription
            }
        }
    }

    // MARK: - Consent

    func applyConsent(_ consent: CollectionConsent) {
        UserDefaults.standard.set(consent.rawValue, forKey: SettingsKey.collectionConsent)
        Task {
            await field.apply(consent)
            field.setReceiving(source == .live)
        }
    }

    // MARK: - Packets

    private func handle(_ event: ScannerEvent) {
        switch event {
        case .availability(let availability):
            bluetooth = availability
        case .advertisement(let advertisement):
            guard source == .live else { return }
            ingest(advertisement)
        }
    }

    private func ingest(_ advertisement: ReceivedAdvertisement) {
        let packet: PICSPacket
        do {
            packet = try PICSParser.parse(manufacturerData: advertisement.manufacturerData)
        } catch {
            rejectedPacketCount += 1
            lastRejection = Self.describe(error)
            return
        }
        picsPacketCount += 1

        let id = packet.intersectionID
        let wasStale = store[id]?.isSignalStale(at: advertisement.timestamp) ?? true
        store.ingest(
            packet,
            raw: advertisement.manufacturerData,
            at: advertisement.timestamp,
            metadata: AdvertisementMetadata(
                rssi: advertisement.rssi,
                serviceUUIDs: advertisement.serviceUUIDs,
                emitter: advertisement.peripheralID.uuidString,
                localName: advertisement.localName,
                txPower: advertisement.txPower,
                isConnectable: advertisement.isConnectable
            )
        )
        if let signals = packet.signals {
            var slots = debouncers[id] ?? SlotDebouncers()
            // After a gap, a "safe" state has to be confirmed again.
            if wasStale { slots.reset() }
            slots.feed(signals, at: advertisement.timestamp)
            debouncers[id] = slots
            confirmed[id] = slots.confirmed
        }

        guard source == .live else { return }
        if isRecording {
            Task { [recorder] in await recorder.append(advertisement) }
        }
        field.record(packet, advertisement: advertisement)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn && isActive
    }

    private static func describe(_ error: PICSParseError) -> String {
        switch error {
        case .headerTooShort(let length):
            String(localized: "ヘッダーが短すぎます（\(length) バイト）")
        case .messageTooShort(let type, let length, let minimum):
            String(localized: "Type \(Int(type)) が短すぎます（\(length) / \(minimum) バイト）")
        case .notPICS:
            String(localized: "PICS 以外のメーカーデータ")
        }
    }
}
