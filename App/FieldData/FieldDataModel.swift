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

    private(set) var status = FieldDataPipeline.Status(
        isEnabled: false, bufferedObservations: 0, bufferedTransitions: 0,
        pendingReports: 0, lastUpload: nil, lastError: nil
    )
    /// `false` on the simulator and on devices without App Attest; such devices never upload.
    let isAttestationSupported: Bool
    /// `nil` when this build has no report server configured.
    let serverURL: URL?
    private(set) var isEnabled = false

    @ObservationIgnored private let pipeline: FieldDataPipeline
    @ObservationIgnored private let location = LocationProvider()
    @ObservationIgnored private var uploadLoop: Task<Void, Never>?
    @ObservationIgnored private var emitterAliases = EmitterAliases()

    init() {
        let attestation = AppAttestProvider()
        isAttestationSupported = attestation.isSupported
        serverURL = ReportServer.baseURL

        let directory = URL.applicationSupportDirectory.appendingPathComponent("FieldReports", isDirectory: true)
        let uploader = serverURL.map {
            ReportUploader(
                transport: URLSessionTransport(baseURL: $0),
                attestation: attestation,
                keyStorage: KeychainKeyIDStorage(),
                sha256: Digest.sha256
            )
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        pipeline = FieldDataPipeline(
            store: FileReportStore(directory: directory),
            uploader: uploader,
            client: FieldReport.clientString(version: version)
        )
    }

    /// Applies the user's consent. Turning collection off deletes everything not yet uploaded.
    func apply(_ consent: CollectionConsent) async {
        let enabled = consent == .granted
        isEnabled = enabled
        await pipeline.setEnabled(enabled)
        if enabled {
            location.requestAuthorizationIfNeeded()
        } else {
            location.stop()
            emitterAliases.reset()
            uploadLoop?.cancel()
            uploadLoop = nil
        }
        await refreshStatus()
    }

    /// Called when live reception starts or stops.
    func setReceiving(_ receiving: Bool) {
        guard isEnabled, receiving else {
            location.stop()
            return
        }
        location.start()
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
        let context = location.context(at: advertisement.timestamp)
        Task {
            await pipeline.record(
                packet,
                manufacturerData: advertisement.manufacturerData,
                at: advertisement.timestamp,
                rssi: advertisement.rssi,
                serviceUUIDs: advertisement.serviceUUIDs,
                emitter: emitter,
                context: context
            )
        }
    }

    /// Queues the current window when due (or always when `force`) and uploads the queue.
    func flushAndUpload(force: Bool) async {
        guard isEnabled else { return }
        await pipeline.flush(force: force)
        if isAttestationSupported {
            _ = await pipeline.uploadPending()
        }
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
