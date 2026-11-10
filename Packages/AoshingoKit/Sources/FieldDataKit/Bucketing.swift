// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Coarsening applied before anything leaves the device (see docs/field-data-api.md).
public enum Bucketing {
    /// RSSI rounded down to a multiple of 5 dB and clamped to −130…0.
    /// Returns `nil` for missing values and for 127, which iOS uses for "unavailable".
    public static func rssi(_ value: Int?) -> Int? {
        guard let value, value < 0, value > -128 else { return nil }
        let bucket = Int((Double(value) / 5).rounded(.down)) * 5
        return min(0, max(-130, bucket))
    }

    /// One of eight 45° sectors, 0 = north, clockwise. Negative or non-finite degrees mean
    /// "invalid" (CoreLocation uses −1) and return `nil`.
    public static func sector(degrees: Double?) -> Int? {
        guard let degrees, degrees.isFinite, degrees >= 0 else { return nil }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return Int((normalized + 22.5) / 45) % 8
    }

    /// Initial great-circle bearing in degrees (0…360) from `origin` to `destination`.
    /// Returns `nil` when the points are closer than about one metre.
    public static func bearing(from origin: Coordinate, to destination: Coordinate) -> Double? {
        let φ1 = origin.latitude * .pi / 180
        let φ2 = destination.latitude * .pi / 180
        let Δλ = (destination.longitude - origin.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        guard hypot(x, y) > 1.5e-7 else { return nil }
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Unix seconds, rounded down.
    public static func seconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down))
    }

    /// Service UUID strings the server accepts: 16-bit, 32-bit or full 128-bit, uppercase.
    public static func serviceUUID(_ value: String) -> String? {
        let upper = value.uppercased()
        let hex = Set("0123456789ABCDEF")
        switch upper.count {
        case 4, 8:
            return upper.allSatisfy(hex.contains) ? upper : nil
        case 36:
            for (index, character) in upper.enumerated() {
                if [8, 13, 18, 23].contains(index) {
                    guard character == "-" else { return nil }
                } else if !hex.contains(character) {
                    return nil
                }
            }
            return upper
        default:
            return nil
        }
    }
}
