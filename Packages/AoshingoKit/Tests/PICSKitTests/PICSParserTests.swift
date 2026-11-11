// SPDX-License-Identifier: Apache-2.0
//
// Cases ported from web/tests/pics.test.mjs of yumu19/ble-pics-viewer
// (MIT License, Copyright (c) 2025 Tsubasa Yumura), plus iOS-specific cases.

import Foundation
import Testing
@testable import PICSKit

private func packet(type: UInt8, length: Int = 24) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length)
    bytes[2] = type
    bytes[3] = 42
    bytes.replaceSubrange(6..<10, with: [0x12, 0x34, 0xAB, 0xCD])
    return bytes
}

private func bigEndian(_ value: Int32) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian, Array.init)
}

@Suite("PICS parser (ported from pics.test.mjs)")
struct PICSParserPortedTests {
    @Test("Type 0 decodes UTF-8 identifier and common header")
    func type0() throws {
        var bytes = packet(type: 0)
        let name = Array("交差点A".utf8)
        bytes.replaceSubrange(10..<(10 + name.count), with: name)
        let info = try PICSParser.parse(payload: bytes)
        #expect(info == PICSPacket(messageType: 0, messageID: 42, intersectionID: "1234ABCD", content: .identifier("交差点A")))
    }

    @Test("Type 1 reads signed big-endian coordinates from a slice with an offset")
    func type1WithOffset() throws {
        var bytes = packet(type: 1, length: 18)
        bytes.replaceSubrange(10..<14, with: bigEndian(-35_123_456))
        bytes.replaceSubrange(14..<18, with: bigEndian(139_654_321))
        let buffer = Data([UInt8](repeating: 0xFF, count: 5) + bytes + [UInt8](repeating: 0xFF, count: 7))
        let sliced = buffer[5..<23]
        #expect(sliced.startIndex == 5)
        let info = try PICSParser.parse(payload: sliced)
        #expect(info.coordinate?.latitude == -35.123456)
        #expect(info.coordinate?.longitude == 139.654321)
        #expect(Hex.string(sliced).split(separator: " ").count == 18)
        #expect(Hex.string(sliced) == Hex.string(bytes))
    }

    @Test("Type 2 decodes every signal state, remaining boundaries, and at most six signals")
    func type2AllStates() throws {
        var bytes = packet(type: 2)
        bytes.replaceSubrange(10..<17, with: [0x00, 0x71, 0x82, 0xF3, 0x24, 0x0F, 0x33])
        let signals = try #require(try PICSParser.parse(payload: bytes).signals)
        #expect(signals == [
            PedestrianSignal(remaining: 1, state: .noSignal),
            PedestrianSignal(remaining: 8, state: .red),
            PedestrianSignal(remaining: nil, state: .blinkGreen),
            PedestrianSignal(remaining: nil, state: .green),
            PedestrianSignal(remaining: 3, state: .none),
            PedestrianSignal(remaining: 1, state: .unknown),
        ])
    }

    @Test("Type 2 permits a partial set of signals without inventing missing values")
    func type2Partial() throws {
        var bytes = packet(type: 2, length: 11)
        bytes[10] = 0x13
        #expect(try PICSParser.parse(payload: bytes).signals?.count == 1)
    }

    @Test("rejects short common headers and truncated known messages")
    func rejectsShort() {
        for length in [0, 2, 6, 9] {
            #expect(throws: PICSParseError.headerTooShort(length: length)) {
                try PICSParser.parse(payload: [UInt8](repeating: 0, count: length))
            }
        }
        for (type, length, minimum) in [(UInt8(0), 23, 24), (1, 17, 18), (2, 10, 11)] {
            #expect(throws: PICSParseError.messageTooShort(type: type, length: length, minimum: minimum)) {
                try PICSParser.parse(payload: packet(type: type, length: length))
            }
        }
    }

    @Test("unknown message types retain the common header")
    func unknownType() throws {
        #expect(try PICSParser.parse(payload: packet(type: 99, length: 10))
            == PICSPacket(messageType: 99, messageID: 42, intersectionID: "1234ABCD", content: .unknown))
    }
}

@Suite("PICS parser (iOS manufacturer data)")
struct PICSParserIOSTests {
    @Test("iOS manufacturer data: the leading CE 01 company identifier is stripped before parsing")
    func stripsCompanyID() throws {
        let payload = packet(type: 2, length: 16)
        let fromPayload = try PICSParser.parse(payload: payload)
        let fromIOS = try PICSParser.parse(manufacturerData: [0xCE, 0x01] + payload)
        #expect(fromIOS == fromPayload)
        #expect(PICSParser.companyID(ofManufacturerData: [0xCE, 0x01, 0x00]) == 0x01CE)
    }

    @Test("other manufacturers and too-short manufacturer data are rejected")
    func rejectsOtherCompanies() {
        #expect(throws: PICSParseError.notPICS(companyID: 0x004C)) {
            try PICSParser.parse(manufacturerData: [0x4C, 0x00] + packet(type: 2, length: 16))
        }
        #expect(throws: PICSParseError.notPICS(companyID: nil)) {
            try PICSParser.parse(manufacturerData: [0xCE])
        }
        #expect(throws: PICSParseError.headerTooShort(length: 3)) {
            try PICSParser.parse(manufacturerData: [0xCE, 0x01, 0, 0, 2])
        }
    }

    @Test("Type 0 removes replacement characters and surrounding NULs like TextDecoder + pics.mjs")
    func identifierCleanup() throws {
        var bytes = packet(type: 0)
        // NUL, "AB", an invalid byte, "C", NUL padding.
        bytes.replaceSubrange(10..<15, with: [0x00, 0x41, 0x42, 0xFF, 0x43])
        #expect(try PICSParser.parse(payload: bytes).identifier == "ABC")

        var withBOM = packet(type: 0)
        withBOM.replaceSubrange(10..<14, with: [0xEF, 0xBB, 0xBF, 0x58])
        #expect(try PICSParser.parse(payload: withBOM).identifier == "X")
    }

    @Test("JSON uses the same keys and -1 for unknown remaining time as ble-pics-viewer")
    func jsonShape() throws {
        var bytes = packet(type: 2, length: 12)
        bytes[10] = 0x83
        bytes[11] = 0x21
        let json = try PICSParser.parse(payload: bytes).prettyJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["message_type"] as? Int == 2)
        #expect(object["message_id"] as? Int == 42)
        #expect(object["intersection_id"] as? String == "1234ABCD")
        let signals = try #require(object["pedestrian_signals"] as? [[String: Any]])
        #expect(signals.count == 2)
        #expect(signals[0]["remaining_time"] as? Int == -1)
        #expect(signals[0]["signal_state"] as? String == "Green")
        #expect(signals[1]["remaining_time"] as? Int == 3)
        #expect(signals[1]["signal_state"] as? String == "Red")
    }

    @Test("PedestrianSignal JSON round-trips")
    func signalRoundTrip() throws {
        let signals = [PedestrianSignal(remaining: nil, state: .blinkGreen), PedestrianSignal(remaining: 8, state: .red)]
        let data = try JSONEncoder().encode(signals)
        #expect(try JSONDecoder().decode([PedestrianSignal].self, from: data) == signals)
    }
}

@Suite("Hex")
struct HexTests {
    @Test func roundTrip() {
        let bytes: [UInt8] = [0xCE, 0x01, 0x00, 0x7F, 0xFF]
        #expect(Hex.string(bytes) == "CE 01 00 7F FF")
        #expect(Hex.string(bytes, separator: "") == "CE01007FFF")
        #expect(Hex.bytes("CE01007FFF") == bytes)
        #expect(Hex.bytes("ce 01 00 7f ff") == bytes)
        #expect(Hex.bytes("CE0") == nil)
        #expect(Hex.bytes("ZZ") == nil)
        #expect(Hex.bytes("") == [])
    }
}
