// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreLocation
import FieldDataKit
import Foundation
import PICSKit

/// Supplies the user's position, heading and movement for the coarse sectors and buckets of field data.
///
/// Used only while field-data collection is on and live reception is running. Coordinates never
/// leave the device; only the sectors and buckets derived from them do (docs/field-data-api.md).
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    /// Fixes worse than this are not used.
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 30
    static let maximumAge: TimeInterval = 10
    static let maximumHeadingError: CLLocationDirection = 30
    /// Direction of travel is used only when iOS rates it at least this accurate.
    static let maximumCourseError: CLLocationDirectionAccuracy = 45
    /// Speed is used only when iOS rates it at least this accurate (m/s).
    static let maximumSpeedError: CLLocationSpeedAccuracy = 1.5

    private let manager = CLLocationManager()
    private var location: CLLocation?
    private var heading: CLHeading?
    private var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 5
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        location = nil
        heading = nil
    }

    /// The current context, dropping stale or inaccurate fixes.
    func context(at now: Date) -> ObservationContext {
        var context = ObservationContext()
        if let location,
           location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= Self.maximumHorizontalAccuracy,
           now.timeIntervalSince(location.timestamp) <= Self.maximumAge {
            context.userLocation = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            context.horizontalAccuracy = location.horizontalAccuracy
            // Negative values mean "invalid" for all four.
            if location.speed >= 0, location.speedAccuracy >= 0, location.speedAccuracy <= Self.maximumSpeedError {
                context.speed = location.speed
            }
            if location.course >= 0, location.courseAccuracy >= 0, location.courseAccuracy <= Self.maximumCourseError {
                context.course = location.course
            }
        }
        if let heading,
           heading.trueHeading >= 0,
           heading.headingAccuracy >= 0,
           heading.headingAccuracy <= Self.maximumHeadingError,
           now.timeIntervalSince(heading.timestamp) <= Self.maximumAge {
            context.trueHeading = heading.trueHeading
        }
        return context
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated { location = latest }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated { heading = newHeading }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let status = self.manager.authorizationStatus
            if isRunning, status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
