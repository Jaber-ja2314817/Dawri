import CoreLocation
import DawriCore
import Foundation

/// The phone's position from Core Location: one reading, taken only when the patient taps Use my
/// location on S08 or Check with my location on S09, while the app is in use. It asks for when
/// in use only, never Always, never monitors a region and never updates in the background. The
/// rules are `LocationRules`: approximate location asks once for temporary precise location,
/// and the reading has `LocationRules.timeout` to arrive.
///
/// It throws a `LocationFailure`. S09 shows `.imprecise` as its own notice, and S08 and S09 show
/// the rest as their location-failed states. Whether the patient is within 150 m is the
/// clinic's to decide, from the point this gives.
struct CoreLocationSource: LocationSource {
    init() {}

    func currentPoint() async throws -> LocationPoint {
        try await OneReading.take()
    }
}

/// One `CLLocationManager` for one reading, on the main actor, where Core Location delivers to
/// the thread that made the manager.
@MainActor
private final class OneReading: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationWaiter: CheckedContinuation<Void, Never>?
    private var fixWaiter: CheckedContinuation<CLLocation, any Error>?
    private var deadline: Task<Void, Never>?

    static func take() async throws -> LocationPoint {
        let reading = OneReading()
        return try await withTaskCancellationHandler {
            try await reading.run()
        } onCancel: {
            Task { @MainActor in reading.finish(throwing: CancellationError()) }
        }
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    private func run() async throws -> LocationPoint {
        var askedPermission = false
        while true {
            let status = Self.authorization(manager.authorizationStatus)
            let answer = LocationRules.permission(status, asked: askedPermission)
            if case .fail(let failure) = answer { throw failure }
            guard answer == .ask else { break }
            askedPermission = true
            await withCheckedContinuation { waiter in
                authorizationWaiter = waiter
                manager.requestWhenInUseAuthorization()
            }
            try Task.checkCancellation()
        }

        var askedPrecision = false
        while true {
            let accuracy: LocationAccuracy =
                manager.accuracyAuthorization == .fullAccuracy ? .full : .reduced
            let answer = LocationRules.precision(accuracy, asked: askedPrecision)
            if case .fail(let failure) = answer { throw failure }
            guard answer == .askFullAccuracy else { break }
            askedPrecision = true
            try? await manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: LocationRules.fullAccuracyPurposeKey)
            try Task.checkCancellation()
        }

        let fix = try await withCheckedThrowingContinuation { waiter in
            fixWaiter = waiter
            deadline = Task { [weak self] in
                try? await Task.sleep(for: LocationRules.timeout)
                guard !Task.isCancelled else { return }
                self?.finish(throwing: LocationFailure.timedOut)
            }
            manager.requestLocation()
        }
        return LocationPoint(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude)
    }

    private func finish(with fix: CLLocation) {
        deadline?.cancel()
        let waiter = fixWaiter
        fixWaiter = nil
        waiter?.resume(returning: fix)
    }

    fileprivate func finish(throwing error: any Error) {
        deadline?.cancel()
        manager.stopUpdatingLocation()
        let waiter = fixWaiter
        fixWaiter = nil
        waiter?.resume(throwing: error)
        let asking = authorizationWaiter
        authorizationWaiter = nil
        asking?.resume()
    }

    private static func authorization(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedWhenInUse: .whenInUse
        case .authorizedAlways: .always
        @unknown default: .denied
        }
    }

    // CLLocationManagerDelegate, called on the main thread that made the manager.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // The first call comes as the delegate is set, before anything is asked.
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let waiter = authorizationWaiter
            authorizationWaiter = nil
            waiter?.resume()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard fixWaiter != nil, let fix = locations.last else { return }
            if LocationRules.accepts(
                ageSeconds: -fix.timestamp.timeIntervalSinceNow,
                uncertaintyMetres: fix.horizontalAccuracy)
            {
                finish(with: fix)
            } else {
                // A cached or vague fix: ask again until the deadline.
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            guard fixWaiter != nil else { return }
            if (error as? CLError)?.code == .denied {
                finish(throwing: LocationFailure.denied)
            } else {
                finish(throwing: LocationFailure.noFix)
            }
        }
    }
}
