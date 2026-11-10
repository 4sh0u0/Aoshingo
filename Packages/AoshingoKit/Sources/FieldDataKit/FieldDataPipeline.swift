// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Ties the collector, the local queue and the uploader together.
///
/// Nothing is recorded, queued or sent unless `setEnabled(true)` was called after the user opted in.
/// Turning collection off discards the current window, deletes the queue and forgets the App Attest key.
/// If deleting the queue fails, nothing queued before the opt-out is ever uploaded and the deletion is
/// retried; the app also retries it on every launch while collection is off.
public actor FieldDataPipeline {
    /// Reports older than this are dropped before upload (the server accepts seven days).
    public static let maximumReportAge: TimeInterval = 6 * 24 * 60 * 60

    public struct Status: Sendable, Equatable {
        public var isEnabled: Bool
        public var bufferedObservations: Int
        public var bufferedTransitions: Int
        public var pendingReports: Int
        public var lastUpload: Date?
        public var lastError: String?

        // The synthesized memberwise initializer is internal; the app builds an initial value.
        public init(
            isEnabled: Bool,
            bufferedObservations: Int,
            bufferedTransitions: Int,
            pendingReports: Int,
            lastUpload: Date?,
            lastError: String?
        ) {
            self.isEnabled = isEnabled
            self.bufferedObservations = bufferedObservations
            self.bufferedTransitions = bufferedTransitions
            self.pendingReports = pendingReports
            self.lastUpload = lastUpload
            self.lastError = lastError
        }
    }

    public struct UploadSummary: Sendable, Equatable {
        public var accepted = 0
        public var rejected = 0
        public var remaining = 0
        public var error: UploadError?
    }

    private var collector = FieldCollector()
    private let store: any ReportStore
    private let uploader: ReportUploader?
    private let client: String
    private let now: @Sendable () -> Date
    public private(set) var isEnabled = false
    private var lastUpload: Date?
    private var lastError: String?
    private var isUploading = false
    /// A report the queue could not take; it is offered again on the next flush instead of being lost.
    private var unsaved: (body: Data, date: Date)?
    /// Set when deleting the queue on opt-out failed. Reports created before it are never uploaded and
    /// are deleted again at every chance until that succeeds.
    private var purgeCutoff: Date?

    /// - Parameter uploader: `nil` when no server is configured; reports then stay queued.
    public init(
        store: any ReportStore,
        uploader: ReportUploader?,
        client: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.uploader = uploader
        self.client = client
        self.now = now
    }

    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        guard !enabled else {
            await retryPurge()
            return
        }
        collector.discardAll()
        unsaved = nil
        await uploader?.forget()
        do {
            try await store.removeAll()
            purgeCutoff = nil
            lastError = nil
        } catch {
            // The user asked for deletion: never upload these, and keep trying to delete them.
            purgeCutoff = purgeCutoff ?? now()
            lastError = String(describing: error)
        }
    }

    public func record(
        _ packet: PICSPacket,
        manufacturerData: [UInt8],
        at timestamp: Date,
        rssi: Int?,
        serviceUUIDs: [String],
        emitter: String?,
        context: ObservationContext
    ) {
        guard isEnabled else { return }
        collector.record(
            packet,
            manufacturerData: manufacturerData,
            at: timestamp,
            rssi: rssi,
            serviceUUIDs: serviceUUIDs,
            emitter: emitter,
            context: context
        )
    }

    /// Moves the current window into the queue when it is full or ten minutes old (or always when `force`).
    /// Returns `true` when something was queued.
    @discardableResult
    public func flush(force: Bool = false) async -> Bool {
        guard isEnabled else { return false }
        var queued = false
        if let pending = unsaved {
            guard await enqueue(pending.body, at: pending.date) else { return false }
            unsaved = nil
            queued = true
        }
        guard force || collector.shouldFlush(at: now()) else { return queued }
        guard let report = collector.makeReport(client: client), let body = try? report.encoded() else { return queued }
        let date = now()
        guard await enqueue(body, at: date) else {
            // makeReport has already emptied the window, so keep the encoded report for the next try.
            unsaved = (body, date)
            return false
        }
        return true
    }

    private func enqueue(_ body: Data, at date: Date) async -> Bool {
        do {
            try await store.enqueue(body, at: date)
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Deletes what an opt-out failed to delete. Clears the cutoff only once that worked.
    private func retryPurge() async {
        guard let cutoff = purgeCutoff else { return }
        do {
            try await store.removeOlder(than: cutoff)
            purgeCutoff = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Uploads queued reports oldest first. Stops at the first retryable error.
    public func uploadPending() async -> UploadSummary {
        var summary = UploadSummary()
        guard isEnabled, let uploader, !isUploading else {
            summary.remaining = await store.count()
            return summary
        }
        isUploading = true
        defer { isUploading = false }

        try? await store.removeOlder(than: now().addingTimeInterval(-Self.maximumReportAge))
        await retryPurge()
        let cutoff = purgeCutoff ?? .distantPast
        let reports = ((try? await store.pending()) ?? []).filter { $0.createdAt > cutoff }
        uploading: for report in reports {
            guard isEnabled else { break uploading }
            do {
                switch try await uploader.upload(report.body) {
                case .accepted:
                    summary.accepted += 1
                    lastUpload = now()
                    lastError = nil
                case .rejected(let code):
                    summary.rejected += 1
                    lastError = code ?? "rejected"
                }
                try? await store.remove(id: report.id)
            } catch let error as UploadError {
                summary.error = error
                lastError = String(describing: error)
                break uploading
            } catch {
                summary.error = .invalidResponse
                lastError = String(describing: error)
                break uploading
            }
        }
        summary.remaining = await store.count()
        return summary
    }

    public func status() async -> Status {
        Status(
            isEnabled: isEnabled,
            bufferedObservations: collector.observationCount,
            bufferedTransitions: collector.transitionCount,
            pendingReports: await store.count(),
            lastUpload: lastUpload,
            lastError: lastError
        )
    }
}
