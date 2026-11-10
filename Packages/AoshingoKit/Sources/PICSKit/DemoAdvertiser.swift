// SPDX-License-Identifier: Apache-2.0
//
// Port of demoPackets() in web/pics.mjs of yumu19/ble-pics-viewer
// (MIT License, Copyright (c) 2025 Tsubasa Yumura).

/// Synthetic advertisements for the demo mode. They are decoded through exactly the same parser as
/// received data, and the UI must always label them as a demo.
public enum DemoAdvertiser {
    /// Intersection ID used by every demo packet.
    public static let intersectionID = "00000001"
    public static let name = "DEMO CROSSING"
    public static let coordinate = Coordinate(latitude: 35.681236, longitude: 139.767125)

    /// Payloads (without the company identifier) for one tick, one tick per second.
    /// Step 0 also carries the name (Type 0) and position (Type 1).
    public static func payloads(step: Int) -> [[UInt8]] {
        func header(type: UInt8, length: Int) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: length)
            data[2] = type
            data[3] = UInt8(truncatingIfNeeded: step % 256)
            data.replaceSubrange(6..<10, with: [0x00, 0x00, 0x00, 0x01])
            return data
        }

        var name = header(type: 0, length: 24)
        let nameBytes = Array(Self.name.utf8)
        name.replaceSubrange(10..<(10 + nameBytes.count), with: nameBytes)

        var position = header(type: 1, length: 18)
        position.replaceSubrange(10..<14, with: bigEndian(35_681_236))
        position.replaceSubrange(14..<18, with: bigEndian(139_767_125))

        var signals = header(type: 2, length: 16)
        let phase = step % 24
        let eastWest: UInt8 = phase < 8 ? 3 : phase < 12 ? 2 : 1
        let northSouth: UInt8 = phase < 12 ? 1 : phase < 20 ? 3 : 2
        let remaining = UInt8(7 - (step % 8)) << 4
        signals.replaceSubrange(10..<16, with: [remaining | eastWest, remaining | northSouth, 0x84, 0x84, 0x84, 0x84])

        return step == 0 ? [name, position, signals] : [signals]
    }

    /// The same payloads as iOS delivers them in `CBAdvertisementDataManufacturerDataKey`,
    /// prefixed with the little-endian company identifier.
    public static func manufacturerData(step: Int) -> [[UInt8]] {
        payloads(step: step).map { PICS.companyIDBytes + $0 }
    }

    private static func bigEndian(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits >> 24), UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)]
    }
}
