// SPDX-License-Identifier: Apache-2.0

import FieldDataKit
import Foundation
import Observation
import PICSKit
import SwiftUI
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
    /// Why the most recent PICS packet was discarded. Shown while searching, where it explains why
    /// nothing appears (for example a transmitter whose messages are shorter than expected).
    private(set) var lastRejection: String?
    /// Set when the chosen recording could not be read or held no packets.
    private(set) var replayLoadFailed = false
    private(set) var isRecording = false
    private(set) var recordingError: String?
    /// Set when the app returned from the background while receiving: nothing was received meanwhile.
    private(set) var missedWhileInBackground = false
    /// `nil` follows the nearest intersection automatically.
    var selectedID: String?
    /// The intersection that "follow the nearest" shows, chosen with hysteresis so that two
    /// intersections with similar signal strength do not take turns (see `NearestIntersectionSelector`).
    private(set) var followedID: String?

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
    @ObservationIgnored private var selector = NearestIntersectionSelector()
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var counterTask: Task<Void, Never>?
    /// Re-evaluates the followed intersection while no packets arrive (switch delay, expiry).
    @ObservationIgnored private var followTask: Task<Void, Never>?

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

    /// The intersection to show: the user's choice, else the one followed automatically.
    var displayedIntersection: IntersectionState? {
        if let selectedID, let state = store[selectedID] { return state }
        return followedID.flatMap { store[$0] } ?? store.mostRecentlyHeard
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
            reportReplayLoadFailure()
            return
        }
        let records = RecordingFormat.decode(data).records.sorted { $0.t < $1.t }
        guard records.contains(where: { $0.bytes != nil }) else {
            reportReplayLoadFailure()
            return
        }
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

    func dismissReplayError() {
        replayLoadFailed = false
    }

    /// The file importer has just closed, so VoiceOver users also hear why nothing starts.
    private func reportReplayLoadFailure() {
        replayLoadFailed = true
        AccessibilityAnnouncer.announce(String(localized: "記録ファイルを読み込めませんでした。"))
    }

    func stop() {
        let wasLive = source == .live
        scanner.stop()
        field.setReceiving(false)
        playbackTask?.cancel()
        playbackTask = nil
        counterTask?.cancel()
        counterTask = nil
        followTask?.cancel()
        followTask = nil
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
        selector.reset()
        followedID = nil
        selectedID = nil
        picsPacketCount = 0
        rejectedPacketCount = 0
        lastRejection = nil
        replayLoadFailed = false
        missedWhileInBackground = false
        source = newSource
        updateIdleTimer()
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshFollowed(at: Date())
            }
        }
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
        refreshFollowed(at: advertisement.timestamp)

        guard source == .live else { return }
        if isRecording {
            Task { [recorder] in await recorder.append(advertisement) }
        }
        field.record(packet, advertisement: advertisement)
    }

    /// Updates the followed intersection and, while following automatically, tells VoiceOver users
    /// which intersection the signals now belong to.
    private func refreshFollowed(at now: Date) {
        let previous = followedID
        let next = selector.update(with: store, at: now)
        guard next != previous else { return }
        followedID = next
        // A manual choice stays on screen, so there is nothing to announce then.
        guard selectedID == nil, let next, let state = store[next] else { return }
        let name = state.spokenName
        AccessibilityAnnouncer.announce(previous == nil
            ? String(localized: "最も近い交差点：\(name)")
            : String(localized: "最も近い交差点が変わりました：\(name)"))
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

extension IntersectionState {
    /// Name for VoiceOver: the Type 0 name, or the ID while no name has been received, so that two
    /// unnamed intersections can still be told apart.
    var spokenName: String {
        if let identifier, !identifier.isEmpty { return identifier }
        return String(localized: "名称未受信（ID \(id)）")
    }
}

/// VoiceOver announcements for changes the user must not miss.
@MainActor
enum AccessibilityAnnouncer {
    /// Posts a high-priority announcement, which other speech (such as VoiceOver reading the element
    /// that receives focus after the screen changed) does not interrupt.
    static func announce(_ message: String) {
        var text = AttributedString(message)
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }
}
