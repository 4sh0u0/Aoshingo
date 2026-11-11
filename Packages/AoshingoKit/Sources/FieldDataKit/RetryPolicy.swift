// SPDX-License-Identifier: Apache-2.0

import Foundation

/// When to try again after a failed upload, so that a failing or full server is not hit (and App
/// Attest is not asked) every minute by every device.
///
/// - `503 over_capacity`: the server's daily write budget is used up until 00:00 UTC, so wait for
///   the next UTC day plus up to one hour of jitter, spreading devices over that hour.
/// - `401 attestation_invalid` from `/v1/attest`: this build's attestations are not accepted (for
///   example a development build against a production server), so wait 24 hours plus jitter.
/// - Anything else (429, other 5xx, network errors, App Attest errors): exponential back-off,
///   1 min doubling per consecutive failure up to 4 h, each wait randomised to 50–100 % of that.
public enum RetryPolicy {
    public static let initialDelay: TimeInterval = 60
    public static let maximumDelay: TimeInterval = 4 * 60 * 60
    public static let attestationRejectedDelay: TimeInterval = 24 * 60 * 60
    /// Added at random to the long waits so devices do not all return at the same moment.
    public static let longWaitJitter: TimeInterval = 60 * 60

    enum Kind: Equatable {
        case transient
        case overCapacity
        case attestationRejected
    }

    static func kind(of error: any Error) -> Kind {
        switch error as? UploadError {
        case .server(status: 503, code: "over_capacity"):
            .overCapacity
        case .server(status: 401, code: "attestation_invalid"):
            .attestationRejected
        default:
            .transient
        }
    }

    /// The earliest time for the next attempt.
    /// - Parameters:
    ///   - failures: consecutive failures, including this one (1 or more).
    ///   - random: returns a value in the given range (injected for tests).
    static func nextAttempt(
        after error: any Error,
        failures: Int,
        now: Date,
        random: (ClosedRange<Double>) -> Double
    ) -> Date {
        switch kind(of: error) {
        case .overCapacity:
            return startOfNextUTCDay(after: now).addingTimeInterval(random(0...longWaitJitter))
        case .attestationRejected:
            return now.addingTimeInterval(attestationRejectedDelay + random(0...longWaitJitter))
        case .transient:
            let delay = exponentialDelay(failures: failures)
            return now.addingTimeInterval(random((delay / 2)...delay))
        }
    }

    /// 1 min, 2 min, 4 min, … capped at `maximumDelay`.
    static func exponentialDelay(failures: Int) -> TimeInterval {
        let exponent = min(max(failures, 1) - 1, 30)
        return min(maximumDelay, initialDelay * pow(2, Double(exponent)))
    }

    static func startOfNextUTCDay(after date: Date) -> Date {
        let day: TimeInterval = 24 * 60 * 60
        let today = (date.timeIntervalSince1970 / day).rounded(.down)
        return Date(timeIntervalSince1970: (today + 1) * day)
    }
}

/// Back-off state, kept across launches until an upload succeeds or the user opts out.
struct RetryState: Codable, Equatable, Sendable {
    var failures: Int
    var notBefore: Date
}
