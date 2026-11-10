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
        let stamp = formatter.string(from: Date())
        // createFile replaces an existing file, so a second recording started within the same second
        // gets "-2", "-3", … instead of wiping the first one.
        var url = Self.directory.appendingPathComponent("aoshingo-\(stamp).\(RecordingFormat.fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.directory.appendingPathComponent("aoshingo-\(stamp)-\(suffix).\(RecordingFormat.fileExtension)")
            suffix += 1
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
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
            // Without the extension, "…-120000" sorts before "…-120000-2", so the later one comes first.
            .sorted { $0.deletingPathExtension().lastPathComponent > $1.deletingPathExtension().lastPathComponent }
    }
}
