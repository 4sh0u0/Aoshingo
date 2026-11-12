// SPDX-License-Identifier: Apache-2.0

import CoreMotion
import FieldDataKit
import Foundation

/// Supplies how the user is moving (walking, in a vehicle, standing still…) from iOS's motion
/// activity classifier, so field data can tell pedestrians from people in a vehicle.
///
/// Used only while field-data collection is on and live reception is running, like
/// `LocationProvider`. Only the class (`FieldReport.Activity`) leaves the device; the motion data
/// itself stays with iOS. Needs the Motion & Fitness permission; without it the activity is `nil`.
@MainActor
final class ActivityProvider {
    private let manager = CMMotionActivityManager()
    private var isRunning = false
    /// The latest classification; iOS sends a new one only when it changes.
    private(set) var current: FieldReport.Activity?

    /// Starts activity updates. iOS asks for the Motion & Fitness permission on first use.
    func start() {
        guard !isRunning, CMMotionActivityManager.isActivityAvailable() else { return }
        switch CMMotionActivityManager.authorizationStatus() {
        case .denied, .restricted:
            return
        default:
            break
        }
        isRunning = true
        // Delivered on the main queue, so the handler runs on the main actor.
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let value = Bucketing.activity(
                automotive: activity.automotive,
                cycling: activity.cycling,
                running: activity.running,
                walking: activity.walking,
                stationary: activity.stationary,
                confident: activity.confidence != .low
            )
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.current = value
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopActivityUpdates()
        current = nil
    }
}
