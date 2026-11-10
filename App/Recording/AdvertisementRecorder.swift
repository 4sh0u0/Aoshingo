// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Writes received PICS advertisements to JSON Lines files for field tests and test fixtures.
///
/// Files stay in the app's Documents/Recordings folder until the user shares or deletes them.
/// They contain no location; transmitters are named E1, E2, … per file.
actor AdvertisementRecorder {
    private var handle: FileHandle?
    private var aliases = EmitterAliases()
    private(set) var currentFile: URL?

    static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    func start() throws {
        guard handle == nil else { return }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.directory.appendingPathComponent("aoshingo-\(formatter.string(from: Date())).\(RecordingFormat.fileExtension)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        currentFile = url
        aliases.reset()
    }

    func stop() {
        try? handle?.close()
        handle = nil
        currentFile = nil
    }

    func append(_ advertisement: ReceivedAdvertisement) {
        guard let handle else { return }
        let metadata = AdvertisementMetadata(
            rssi: advertisement.rssi,
            serviceUUIDs: advertisement.serviceUUIDs,
            emitter: aliases.alias(for: advertisement.peripheralID.uuidString),
            localName: advertisement.localName,
            txPower: advertisement.txPower,
            isConnectable: advertisement.isConnectable
        )
        let record = RecordedAdvertisement(
            timestamp: advertisement.timestamp,
            manufacturerData: advertisement.manufacturerData,
            metadata: metadata
        )
        if let line = try? RecordingFormat.encodeLine(record) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Recordings, newest first.
    static func recordings() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == RecordingFormat.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
