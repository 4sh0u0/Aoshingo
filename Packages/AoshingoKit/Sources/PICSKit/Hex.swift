// SPDX-License-Identifier: Apache-2.0

/// Hexadecimal helpers for raw advertisement dumps.
public enum Hex {
    private static let digits = Array("0123456789ABCDEF")

    /// Uppercase hex, two digits per byte, joined by `separator` (`"CE 01 00"` by default).
    public static func string<Bytes: Sequence>(_ bytes: Bytes, separator: String = " ") -> String
    where Bytes.Element == UInt8 {
        bytes.map { byte in
            String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
        }
        .joined(separator: separator)
    }

    /// Parses hex digits, ignoring spaces. Returns `nil` for odd lengths or non-hex characters.
    public static func bytes(_ text: String) -> [UInt8]? {
        var result: [UInt8] = []
        result.reserveCapacity(text.utf8.count / 2)
        var high: UInt8?
        for character in text.utf8 where character != UInt8(ascii: " ") {
            guard let nibble = nibble(character) else { return nil }
            if let pending = high {
                result.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? result : nil
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
