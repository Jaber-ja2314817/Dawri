import DawriCore
import Foundation

/// A point on the map, so screens need no location framework to hold one.
struct LocationPoint: Sendable, Equatable {
    let lat: Double
    let lng: Double
}

/// The phone's position. The real source is a later phase, and the default says so by throwing,
/// which S08 and S09 show as their location-failed states.
protocol LocationSource: Sendable {
    func currentPoint() async throws -> LocationPoint
}

/// Reads a server's `/api/health`, once the address has passed `ServerAddress`.
protocol ServerProbe: Sendable {
    func probe(url: URL) async throws -> Health
}

enum PhoneFeatureError: Error, Equatable {
    case unavailable
}

/// What this build can reach. Nothing here touches the location or network frameworks, so a
/// Release build of this phase cannot read a position or connect to a server.
struct NoLocationSource: LocationSource {
    func currentPoint() async throws -> LocationPoint {
        throw PhoneFeatureError.unavailable
    }
}

struct NoServerProbe: ServerProbe {
    func probe(url: URL) async throws -> Health {
        throw PhoneFeatureError.unavailable
    }
}

/// The seams for what only a phone has. Held on `AppModel`.
///
/// `voice` is recognition on the phone. The default reports itself unavailable, so S05 says
/// `voice.unavailableOnDevice` and the patient types. There is never a server fallback: the app
/// does not send audio anywhere. The on-device `Speech` engine is a later phase.
struct PhoneFeatures: Sendable {
    var location: any LocationSource
    var probe: any ServerProbe
    var voice: any VoiceEngine

    static let unavailable = PhoneFeatures(
        location: NoLocationSource(), probe: NoServerProbe(), voice: UnavailableVoiceEngine())
}
