import DawriCore
import Foundation

/// A point on the map, so screens need no location framework to hold one.
struct LocationPoint: Sendable, Equatable {
    let lat: Double
    let lng: Double
}

/// The phone's position, read once when the patient asks. The phone's source is
/// `CoreLocationSource`. A source that cannot read a position throws, which S08 and S09 show as
/// their location-failed states.
protocol LocationSource: Sendable {
    func currentPoint() async throws -> LocationPoint
}

/// Reads a server's `/api/health`, once the address has passed `ServerAddress`. It returns the
/// health only for `ai_mode: simulated`, or throws: `ServerCheck.Refusal.notSimulated` for any
/// other mode, anything else for a server that could not be read.
protocol ServerProbe: Sendable {
    func probe(url: URL) async throws -> Health
}

enum PhoneFeatureError: Error, Equatable {
    case unavailable
}

/// A build with no position. It always throws.
struct NoLocationSource: LocationSource {
    func currentPoint() async throws -> LocationPoint {
        throw PhoneFeatureError.unavailable
    }
}

/// A build that cannot reach a server. It always throws, so nothing can say Connected. Previews
/// and `PhoneFeatures.unavailable` use it. The phone's probe is `ServerHealthProbe`.
struct NoServerProbe: ServerProbe {
    func probe(url: URL) async throws -> Health {
        throw PhoneFeatureError.unavailable
    }
}

/// The seams for what only a phone has. Held on `AppModel`, which the screens read them from.
/// Each seam has a `No…` default that does nothing or says unavailable, and the phone's own
/// implementation in `Native/`.
///
/// - `location`: one Core Location reading, on the patient's tap.
/// - `probe`: the Clinic server health read, before connecting.
/// - `voice`: recognition on the phone only. When it is unavailable S05 says
///   `voice.unavailableOnDevice` and the patient types. There is never a server fallback: the
///   app does not send audio anywhere.
/// - `scanner`: the camera behind S09's door code sheet. The typed field always stays.
/// - `live`: the ticket's Live Activity, with local updates only.
/// - `notifier`: local notifications for the visit, scheduled ahead in On this phone mode.
struct PhoneFeatures: Sendable {
    var location: any LocationSource
    var probe: any ServerProbe
    var voice: any VoiceEngine
    var scanner: any DoorScanner
    var live: any TicketLiveActivities
    var notifier: any VisitNotifying

    /// Nothing at all: no position, no server, no voice, no camera, no Live Activity and no
    /// notifications. Previews and tests that want none of the phone use this.
    static let unavailable = PhoneFeatures(
        location: NoLocationSource(), probe: NoServerProbe(), voice: UnavailableVoiceEngine(),
        scanner: NoDoorScanner(), live: NoTicketLive(), notifier: NoVisitNotifier())

    /// The phone's own frameworks, which a normal launch uses. The server probe is
    /// `ServerHealthProbe`, the two guards of Clinic server mode on the app's one transport.
    static let device = PhoneFeatures(
        location: CoreLocationSource(), probe: ServerHealthProbe(), voice: SpeechVoiceEngine(),
        scanner: CameraDoorScanner(), live: ActivityTicketLive(), notifier: LocalVisitNotifier())
}
