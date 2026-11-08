import Foundation

/// The location permission, as `CLLocationManager.authorizationStatus` gives it.
public enum LocationAuthorization: Sendable, Equatable, CaseIterable {
    case notDetermined, denied, restricted, whenInUse, always
}

/// `CLLocationManager.accuracyAuthorization`.
public enum LocationAccuracy: Sendable, Equatable, CaseIterable {
    case full, reduced
}

/// Why no position came back. S09 shows `imprecise` as `reserved.locationImprecise`, and the
/// rest as `reserved.locationFailed`. S08 shows all of them as `centre.locationFailed`.
public enum LocationFailure: Error, Sendable, Equatable {
    /// Refused or restricted, or the prompt was dismissed with no choice.
    case denied
    /// Only approximate location is allowed, and the precise prompt was declined.
    case imprecise
    /// No good reading within `LocationRules.timeout`.
    case timedOut
    /// Core Location could not find the phone.
    case noFix
}

/// The rules for the one reading S08 and S09 take on the patient's tap: frontend/src/features/map/
/// location.ts, which reads once with a 10 s timeout. When in use only, never Always, never a
/// region, never in the background.
public enum LocationRules {
    /// location.ts `LOCATION_TIMEOUT_MS`. It covers the reading, not the time a patient spends
    /// reading a permission prompt, as the browser's timeout does not either.
    public static let timeout: Duration = .seconds(10)
    /// The `NSLocationTemporaryUsageDescriptionDictionary` key for the precise prompt.
    public static let fullAccuracyPurposeKey = "ArrivalCheck"
    /// A reading older than this is a cached one from somewhere else.
    public static let maxAgeSeconds: TimeInterval = 30
    /// A reading less sure than this cannot say whether the patient is within the 150 m of
    /// `TicketRules.geofenceMetres`.
    public static let maxUncertaintyMetres: Double = 100

    public enum Permission: Sendable, Equatable {
        /// Ask for when-in-use, on this tap, and decide again.
        case ask
        case read
        case fail(LocationFailure)
    }

    /// What the permission allows. `asked` is true once this tap has already asked, so a prompt
    /// dismissed with no choice fails rather than asking again.
    public static func permission(_ status: LocationAuthorization, asked: Bool) -> Permission {
        switch status {
        case .notDetermined: asked ? .fail(.denied) : .ask
        case .denied, .restricted: .fail(.denied)
        case .whenInUse, .always: .read
        }
    }

    public enum Precision: Sendable, Equatable {
        case read
        /// Ask once for temporary full accuracy with `fullAccuracyPurposeKey`, and decide again.
        case askFullAccuracy
        case fail(LocationFailure)
    }

    /// What the accuracy allows. Approximate location cannot check 150 m, so the patient is
    /// asked once on this tap, and if it stays approximate, S09 says so.
    public static func precision(_ accuracy: LocationAccuracy, asked: Bool) -> Precision {
        switch accuracy {
        case .full: .read
        case .reduced: asked ? .fail(.imprecise) : .askFullAccuracy
        }
    }

    /// Whether a reading is good enough: taken in the last `maxAgeSeconds`, a few seconds of
    /// clock skew allowed, with a valid uncertainty of at most `maxUncertaintyMetres`.
    public static func accepts(ageSeconds: TimeInterval, uncertaintyMetres: Double) -> Bool {
        ageSeconds >= -5 && ageSeconds <= maxAgeSeconds
            && uncertaintyMetres >= 0 && uncertaintyMetres <= maxUncertaintyMetres
    }
}
