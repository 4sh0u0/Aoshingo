// SPDX-License-Identifier: Apache-2.0

import FieldDataKit
import Foundation
import Observation
import PICSKit
import UIKit

/// Main-actor face of the opt-in field data collection.
@MainActor
@Observable
final class FieldDataModel {
    /// How often the window is checked and the queue uploaded while the app is open.
    static let uploadInterval: Duration = .seconds(60)

    /// Why field data cannot be contributed from this build or device.
    enum Unavailability: Sendable {
        /// The build has no report server (`AOSHINGO_REPORT_HOST` is empty).
        case noServer
        /// No App Attest (the simulator, some devices).
        case attestationUnsupported
    }

    private(set) var status = FieldDataPipeline.Status(
        isEnabled: false, bufferedObservations: 0, bufferedTransitions: 0,
        pendingReports: 0, lastUpload: nil, lastError: nil
    )
    /// `nil` when field data can be contributed. Otherwise collection cannot be turned on, because
    /// reports that can never be sent would only pile up on the device.
    let unavailability: Unavailability?
    private(set) var isEnabled = false

    var canContribute: Bool { unavailability == nil }

    @ObservationIgnored private let pipeline: FieldDataPipeline
    @ObservationIgnored private let hasUploader: Bool
    @ObservationIgnored private let location = LocationProvider()
    @ObservationIgnored private let activity = ActivityProvider()
    @ObservationIgnored private var uploadLoop: Task<Void, Never>?
    @ObservationIgnored private var emitterAliases = EmitterAliases()

    init() {
        let attestation = AppAttestProvider()
        let serverURL = ReportServer.baseURL
        if serverURL == nil {
            unavailability = .noServer
        } else if !attestation.isSupported {
            unavailability = .attestationUnsupported
        } else {
            unavailability = nil
        }

        let stateStore = UserDefaultsStateStore()
        let directory = URL.applicationSupportDirectory.appendingPathComponent("FieldReports", isDirectory: true)
        let uploader = serverURL.map {
            ReportUploader(
                transport: URLSessionTransport(baseURL: $0),
                attestation: attestation,
                keyStorage: KeychainKeyIDStorage(),
                stateStore: stateStore,
                sha256: Digest.sha256
            )
        }
        hasUploader = uploader != nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        pipeline = FieldDataPipeline(
            store: FileReportStore(directory: directory),
            uploader: uploader,
            client: FieldReport.clientString(version: version),
            stateStore: stateStore
        )
    }

    /// Applies the user's consent (at launch and on every change). Turning collection off deletes
    /// everything not yet uploaded; once this returns, nothing more is sent.
    func apply(_ consent: CollectionConsent) async {
        let enabled = consent == .granted && canContribute
        isEnabled = enabled
        if !enabled {
            // Stop the periodic upload first; the pipeline then waits for one in progress.
            uploadLoop?.cancel()
            uploadLoop = nil
            location.stop()
            activity.stop()
            emitterAliases.reset()
        }
        await pipeline.setEnabled(enabled)
        if enabled {
            // Not if the user opted out again meanwhile.
            if isEnabled { location.requestAuthorizationIfNeeded() }
        } else if !hasUploader {
            // Without an uploader there is nothing to forget a key left by an earlier build that had a server.
            KeychainKeyIDStorage().save(nil)
        }
        await refreshStatus()
    }

    /// Called when live reception starts or stops.
    func setReceiving(_ receiving: Bool) {
        guard isEnabled, receiving else {
            location.stop()
            activity.stop()
            Task { [pipeline] in await pipeline.receptionDidPause() }
            return
        }
        location.start()
        activity.start()
        guard uploadLoop == nil else { return }
        uploadLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.uploadInterval)
                guard let self, !Task.isCancelled else { return }
                await self.flushAndUpload(force: false)
            }
        }
    }

    /// Records one live advertisement. Demo and replayed data must never be passed here.
    func record(_ packet: PICSPacket, advertisement: ReceivedAdvertisement) {
        guard isEnabled else { return }
        let emitter = emitterAliases.alias(for: advertisement.peripheralID.uuidString)
        var context = location.context(at: advertisement.timestamp)
        context.nearbyDevices = advertisement.nearbyDevices
        context.activity = activity.current
        Task {
            await pipeline.record(
                packet,
                manufacturerData: advertisement.manufacturerData,
                at: advertisement.timestamp,
                rssi: advertisement.rssi,
                serviceUUIDs: advertisement.serviceUUIDs,
                emitter: emitter,
                txPower: advertisement.txPower,
                connectable: advertisement.isConnectable,
                context: context
            )
        }
    }

    /// What happened to a tester label.
    enum LabelResult: Sendable, Equatable {
        /// Recorded; `heading` is the 8-sector device heading stored with it, if known.
        case recorded(heading: Int?)
        /// A crosswalk label needs the device heading, and iOS has none (or only an inaccurate one) now.
        case noHeading
        /// Collection is off, or the label could not be added (limits).
        case notRecorded
    }

    /// Records a tester label ("slot n is the crosswalk I am facing", or "I pressed the push button")
    /// for an intersection being received live. It is uploaded with the field data.
    func label(_ kind: FieldReport.Label.Kind, slot: Int?, intersectionID: String) async -> LabelResult {
        guard isEnabled else { return .notRecorded }
        let now = Date()
        let context = location.context(at: now)
        if kind == .crosswalk, context.trueHeading == nil { return .noHeading }
        let recorded = await pipeline.recordLabel(kind, slot: slot, intersectionID: intersectionID, at: now, context: context)
        await refreshStatus()
        return recorded ? .recorded(heading: Bucketing.sector(degrees: context.trueHeading)) : .notRecorded
    }

    /// Queues the current window when due (or always when `force`) and uploads the queue.
    func flushAndUpload(force: Bool) async {
        guard isEnabled else { return }
        await pipeline.flush(force: force)
        _ = await pipeline.uploadPending()
        await refreshStatus()
    }

    /// Called when the app moves to the background: queue what we have and try to send it.
    func sceneDidEnterBackground() {
        guard isEnabled else { return }
        let task = BackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: "FieldDataUpload") {
            MainActor.assumeIsolated { task.end() }
        }
        Task {
            // Nothing is received in the background, so a change seen afterwards is not a transition.
            await pipeline.receptionDidPause()
            await flushAndUpload(force: true)
            task.end()
        }
    }

    func refreshStatus() async {
        status = await pipeline.status()
    }
}

/// Holds a background task identifier so both the expiration handler and the work can end it once.
@MainActor
private final class BackgroundTask {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
