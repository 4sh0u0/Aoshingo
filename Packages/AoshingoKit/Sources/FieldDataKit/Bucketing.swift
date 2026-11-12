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

    /// One of eight 45° sectors, 0 = north, clockwise (bearing, heading and course). Negative or
    /// non-finite degrees mean "invalid" (CoreLocation uses −1) and return `nil`.
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

    /// Great-circle (haversine) distance in metres between two coordinates.
    public static func distance(from origin: Coordinate, to destination: Coordinate) -> Double {
        let φ1 = origin.latitude * .pi / 180
        let φ2 = destination.latitude * .pi / 180
        let Δφ = φ2 - φ1
        let Δλ = (destination.longitude - origin.longitude) * .pi / 180
        let h = pow(sin(Δφ / 2), 2) + cos(φ1) * cos(φ2) * pow(sin(Δλ / 2), 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// Mean Earth radius in metres.
    static let earthRadius = 6_371_008.8

    /// Lower bounds of the distance rings, in metres.
    public static let distanceRings = [0, 10, 20, 40, 80, 160]
    /// Upper bounds of the horizontal accuracy classes, in metres.
    public static let accuracyClasses = [5, 10, 20, 30]
    /// Lower bounds of the nearby-device classes.
    public static let nearbyClasses = [0, 1, 5, 10, 20, 50, 100]
    /// Speed classes: 0 below 0.5 m/s, 1 below 2.5 m/s, 2 otherwise.
    public static let speedClasses = 0...2
    /// The longest `held`, `cycle` or step duration sent, in milliseconds (one hour).
    public static let maximumDuration = 3_600_000
    /// The longest packet interval sent, in milliseconds (ten minutes).
    public static let maximumInterval = 600_000
    /// Advertised transmit power the server accepts, in dBm.
    public static let txPowerRange = -127...20

    /// The largest ring of 0, 10, 20, 40, 80 and 160 m not above `meters` (27 m → 20).
    /// `nil` for missing, negative or non-finite distances.
    public static func distanceRing(_ meters: Double?) -> Int? {
        guard let meters, meters.isFinite, meters >= 0 else { return nil }
        return distanceRings.last { Double($0) <= meters }
    }

    /// The smallest class of 5, 10, 20 and 30 m not below `meters` (7 m → 10).
    /// `nil` for missing, negative (iOS: invalid), non-finite and worse than 30 m.
    public static func accuracy(_ meters: Double?) -> Int? {
        guard let meters, meters.isFinite, meters >= 0 else { return nil }
        return accuracyClasses.first { meters <= Double($0) }
    }

    /// 0 below 0.5 m/s, 1 below 2.5 m/s, otherwise 2. `nil` for missing, negative (iOS: invalid) or non-finite.
    public static func speed(_ metersPerSecond: Double?) -> Int? {
        guard let metersPerSecond, metersPerSecond.isFinite, metersPerSecond >= 0 else { return nil }
        return metersPerSecond < 0.5 ? 0 : metersPerSecond < 2.5 ? 1 : 2
    }

    /// The largest class of 0, 1, 5, 10, 20, 50 and 100 not above `count`. `nil` for missing or negative.
    public static func nearby(_ count: Int?) -> Int? {
        guard let count, count >= 0 else { return nil }
        return nearbyClasses.last { $0 <= count }
    }

    /// The activity sent for one classification of iOS's motion activity classifier (`CMMotionActivity`),
    /// or `nil` when iOS is unsure (`confident` is false for low confidence) or knows nothing (no flag set).
    /// iOS may set several flags at once, for example `automotive` and `stationary` for a car waiting at a
    /// red light. The vehicle wins, so the order is automotive, cycling, running, walking, stationary.
    public static func activity(
        automotive: Bool,
        cycling: Bool,
        running: Bool,
        walking: Bool,
        stationary: Bool,
        confident: Bool
    ) -> FieldReport.Activity? {
        guard confident else { return nil }
        if automotive { return .automotive }
        if cycling { return .cycling }
        if running { return .running }
        if walking { return .walking }
        if stationary { return .stationary }
        return nil
    }

    /// A duration (`gap`, `held`, `cycle`, step `held`) in milliseconds, rounded to the nearest 100 ms.
    /// `nil` when negative, non-finite or above one hour once rounded.
    public static func durationMilliseconds(_ interval: TimeInterval) -> Int? {
        guard interval.isFinite, interval >= 0, interval <= Double(maximumDuration) / 1000 + 1 else { return nil }
        let value = Int((interval * 10).rounded()) * 100
        return value <= maximumDuration ? value : nil
    }

    /// A packet interval in milliseconds, rounded to the nearest 10 ms and capped at ten minutes.
    /// `nil` when negative or not a number.
    public static func intervalMilliseconds(_ interval: TimeInterval) -> Int? {
        guard !interval.isNaN, interval >= 0 else { return nil }
        guard interval < Double(maximumInterval) / 1000 else { return maximumInterval }
        return min(Int((interval * 100).rounded()) * 10, maximumInterval)
    }

    /// Advertised transmit power if it is within −127…20 dBm, else `nil`.
    public static func txPower(_ value: Int?) -> Int? {
        guard let value, txPowerRange.contains(value) else { return nil }
        return value
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
