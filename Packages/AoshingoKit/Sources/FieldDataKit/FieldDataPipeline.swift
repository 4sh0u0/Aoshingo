// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Ties the collector, the local queue and the uploader together.
///
/// Nothing is recorded, queued or sent unless `setEnabled(true)` was called after the user opted in,
/// and collection cannot be enabled at all without an uploader that can work on this device (so
/// nothing piles up that could never be sent).
///
/// Turning collection off discards the current window, stops any upload in progress, forgets the
/// App Attest key, token and back-off, and deletes the queue. When `setEnabled(false)` returns,
/// nothing more is sent. If deleting the queue fails, nothing queued before the opt-out is ever
/// uploaded (the cutoff is persisted, so this holds across relaunches) and the deletion is retried
/// at every chance; the app also retries it on every launch while collection is off.
public actor FieldDataPipeline {
    /// Reports older than this are deleted (the server accepts seven days).
    public static let maximumReportAge: TimeInterval = 6 * 24 * 60 * 60
    /// Reports queued up to this long after an opt-out whose deletion failed still count as queued
    /// before it: queue file names keep only milliseconds.
    static let purgeMargin: TimeInterval = 1
    static let purgeCutoffKey = "purgeCutoff"

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

    private struct Cutoff: Codable {
        var date: Date
    }

    private var collector = FieldCollector()
    private let store: any ReportStore
    private let uploader: ReportUploader?
    private let stateStore: any StateStore
    private let client: String
    private let now: @Sendable () -> Date
    /// Whether this pipeline can ever upload: a server is configured and App Attest works here.
    public nonisolated let canUpload: Bool
    public private(set) var isEnabled = false
    private var lastUpload: Date?
    private var lastError: String?
    /// Incremented by every opt-out and every opt-in. Work started under an older value stops at
    /// its next suspension point without touching the queue or the state.
    private var generation: UInt64 = 0
    /// Reports the queue could not take; they are offered again on the next flush instead of being lost.
    private var unsaved: [(body: Data, date: Date)] = []
    /// Set when deleting the queue on opt-out failed. Reports created before it are never uploaded
    /// and are deleted again at every chance until that succeeds. Persisted.
    private var purgeCutoff: Date?
    private var uploadTask: Task<UploadSummary, Never>?
    /// Flushes run one at a time, and so do uploads, each in call order; a flush does not wait for an
    /// upload (the app flushes when it goes to the background, with little time left). Opting in or
    /// out takes both lanes, so it waits for whatever is in progress.
    private enum Lane { case flush, upload }
    private var busyLanes: Set<Lane> = []
    private var laneWaiters: [Lane: [CheckedContinuation<Void, Never>]] = [:]

    /// - Parameters:
    ///   - uploader: `nil` when no server is configured; collection then stays off.
    ///   - stateStore: keeps the opt-out deletion cutoff across launches.
    public init(
        store: any ReportStore,
        uploader: ReportUploader?,
        client: String,
        stateStore: any StateStore = InMemoryStateStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.uploader = uploader
        self.stateStore = stateStore
        self.client = client
        self.now = now
        self.canUpload = uploader?.isAttestationSupported ?? false
        self.purgeCutoff = stateStore.value(Cutoff.self, forKey: Self.purgeCutoffKey)?.date
    }

    /// Applies the user's choice. Called at launch and whenever it changes; also deletes expired reports.
    /// Enabling has no effect (collection stays off and the queue is deleted) when `canUpload` is `false`.
    public func setEnabled(_ enabled: Bool) async {
        guard enabled, canUpload else {
            await disable()
            return
        }
        if !isEnabled { generation &+= 1 }
        isEnabled = true
        await acquireAll()
        defer { releaseAll() }
        await retryPurge()
        await removeExpired()
    }

    private func disable() async {
        isEnabled = false
        generation &+= 1
        collector.discardAll()
        unsaved.removeAll()
        lastUpload = nil
        // Cancel first: an upload that resumes before `forget()` reaches the uploader must not
        // start another request.
        uploadTask?.cancel()
        await uploader?.forget()
        // Waits for an upload or flush in progress to finish (it stops at its next step).
        await acquireAll()
        defer { releaseAll() }
        do {
            try await store.removeAll()
            setPurgeCutoff(nil)
            lastError = nil
        } catch {
            // The user asked for deletion: never upload these, and keep trying to delete them.
            setPurgeCutoff(max(purgeCutoff ?? .distantPast, now().addingTimeInterval(Self.purgeMargin)))
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
        await acquire(.flush)
        defer { release(.flush) }
        guard isEnabled else { return false }
        let epoch = generation
        var queued = 0
        if !unsaved.isEmpty {
            let result = await enqueueUnsaved(epoch: epoch)
            queued += result.queued
            guard result.complete else { return queued > 0 }
        }
        guard force || collector.shouldFlush(at: now()) else { return queued > 0 }
        // makeReport empties the window, so the encoded reports are kept until the queue takes them.
        guard let report = collector.makeReport(client: client), let body = try? report.encoded() else { return queued > 0 }
        unsaved = [(body: body, date: now())]
        queued += await enqueueUnsaved(epoch: epoch).queued
        return queued > 0
    }

    private func enqueueUnsaved(epoch: UInt64) async -> (queued: Int, complete: Bool) {
        var queued = 0
        while let next = unsaved.first {
            do {
                try await store.enqueue(next.body, at: next.date)
            } catch {
                if epoch == generation { lastError = String(describing: error) }
                return (queued, false)
            }
            // An opt-out meanwhile has emptied `unsaved`; it deletes the queue once this flush ends.
            guard epoch == generation else { return (queued, false) }
            unsaved.removeFirst()
            queued += 1
        }
        return (queued, true)
    }

    /// Uploads queued reports oldest first. Stops at the first retryable error, and while the
    /// uploader is backing off after one. Joins an upload that is already running.
    public func uploadPending() async -> UploadSummary {
        guard isEnabled, let uploader else {
            var summary = UploadSummary()
            summary.remaining = await store.count()
            return summary
        }
        if let running = uploadTask { return await running.value }
        let epoch = generation
        let task = Task { await self.performUpload(with: uploader, epoch: epoch) }
        uploadTask = task
        let summary = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if uploadTask == task { uploadTask = nil }
        return summary
    }

    private func isCurrent(_ epoch: UInt64) -> Bool {
        epoch == generation && isEnabled
    }

    private func performUpload(with uploader: ReportUploader, epoch: UInt64) async -> UploadSummary {
        await acquire(.upload)
        defer { release(.upload) }
        var summary = UploadSummary()
        if isCurrent(epoch) {
            await removeExpired()
            await retryPurge()
            let cutoff = purgeCutoff ?? .distantPast
            let reports = ((try? await store.pending()) ?? []).filter { $0.createdAt >= cutoff }
            uploading: for report in reports {
                guard isCurrent(epoch), !Task.isCancelled else {
                    summary.error = .cancelled
                    break uploading
                }
                do {
                    let outcome = try await uploader.upload(report.body)
                    // Sent before the opt-out took effect; the opt-out deletes the queue next.
                    guard isCurrent(epoch) else {
                        summary.error = .cancelled
                        break uploading
                    }
                    switch outcome {
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
                    switch error {
                    case .cancelled, .backingOff:
                        break // Keep the error that caused the back-off.
                    default:
                        if isCurrent(epoch) { lastError = String(describing: error) }
                    }
                    break uploading
                } catch {
                    summary.error = .invalidResponse
                    if isCurrent(epoch) { lastError = String(describing: error) }
                    break uploading
                }
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

    // MARK: - Queue maintenance (called holding the upload lane)

    private func removeExpired() async {
        try? await store.removeOlder(than: now().addingTimeInterval(-Self.maximumReportAge))
    }

    /// Deletes what an opt-out failed to delete. Clears the cutoff only once that worked.
    private func retryPurge() async {
        guard let cutoff = purgeCutoff else { return }
        do {
            try await store.removeOlder(than: cutoff)
            setPurgeCutoff(nil)
        } catch {
            lastError = String(describing: error)
        }
    }

    private func setPurgeCutoff(_ date: Date?) {
        purgeCutoff = date
        stateStore.setValue(date.map(Cutoff.init(date:)), forKey: Self.purgeCutoffKey)
    }

    // MARK: - Lanes

    private func acquire(_ lane: Lane) async {
        guard busyLanes.contains(lane) else {
            busyLanes.insert(lane)
            return
        }
        await withCheckedContinuation { laneWaiters[lane, default: []].append($0) }
    }

    /// Hands the lane to the next waiter, in call order.
    private func release(_ lane: Lane) {
        if var waiters = laneWaiters[lane], !waiters.isEmpty {
            let next = waiters.removeFirst()
            laneWaiters[lane] = waiters
            next.resume()
        } else {
            busyLanes.remove(lane)
        }
    }

    // Always upload first, then flush, so two callers of acquireAll cannot deadlock.
    private func acquireAll() async {
        await acquire(.upload)
        await acquire(.flush)
    }

    private func releaseAll() {
        release(.flush)
        release(.upload)
    }
}
