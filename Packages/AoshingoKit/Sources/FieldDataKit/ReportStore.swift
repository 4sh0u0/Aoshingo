// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A report waiting to be uploaded.
public struct PendingReport: Sendable, Hashable {
    public var id: String
    public var createdAt: Date
    public var body: Data

    public init(id: String, createdAt: Date, body: Data) {
        self.id = id
        self.createdAt = createdAt
        self.body = body
    }
}

/// Local queue of encoded reports. Deleting everything must be immediate when the user opts out.
public protocol ReportStore: Sendable {
    func enqueue(_ body: Data, at date: Date) async throws
    /// Oldest first.
    func pending() async throws -> [PendingReport]
    func remove(id: String) async throws
    func removeAll() async throws
    /// Drops reports created before `date` (the server rejects data older than seven days).
    func removeOlder(than date: Date) async throws
}

public extension ReportStore {
    func count() async -> Int {
        (try? await pending().count) ?? 0
    }
}

/// Queue kept in memory only.
public actor InMemoryReportStore: ReportStore {
    public let capacity: Int
    private var reports: [PendingReport] = []

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    public func enqueue(_ body: Data, at date: Date) {
        reports.append(PendingReport(id: UUID().uuidString, createdAt: date, body: body))
        if reports.count > capacity { reports.removeFirst(reports.count - capacity) }
    }

    public func pending() -> [PendingReport] { reports }

    public func remove(id: String) { reports.removeAll { $0.id == id } }

    public func removeAll() { reports.removeAll() }

    public func removeOlder(than date: Date) { reports.removeAll { $0.createdAt < date } }
}

/// Queue stored as one file per report in a directory (for example Application Support), so that
/// reports survive the app being terminated before upload.
public actor FileReportStore: ReportStore {
    public let directory: URL
    public let capacity: Int

    public init(directory: URL, capacity: Int = 50) {
        self.directory = directory
        self.capacity = capacity
    }

    public func enqueue(_ body: Data, at date: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let name = "\(String(format: "%015lld", milliseconds))-\(UUID().uuidString).json"
        try body.write(to: directory.appendingPathComponent(name), options: [.atomic])
        let all = try files()
        if all.count > capacity {
            for url in all.prefix(all.count - capacity) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public func pending() throws -> [PendingReport] {
        try files().compactMap { url in
            guard let body = try? Data(contentsOf: url) else { return nil }
            return PendingReport(id: url.lastPathComponent, createdAt: Self.date(of: url), body: body)
        }
    }

    public func remove(id: String) throws {
        // Only plain file names from `pending()` are accepted.
        guard !id.contains("/"), id.hasSuffix(".json") else { return }
        let url = directory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func removeAll() throws {
        for url in try files() {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func removeOlder(than date: Date) throws {
        for url in try files() where Self.date(of: url) < date {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func date(of url: URL) -> Date {
        let prefix = url.lastPathComponent.prefix { $0 != "-" }
        let milliseconds = Double(prefix) ?? 0
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
