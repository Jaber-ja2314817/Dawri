import Foundation

public struct GeoPoint: Sendable, Equatable {
    public var lat: Double
    public var lng: Double

    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }
}

/// Port of backend/geo.py. The steps keep Python's order, including `pow` for `** 2`, because a
/// different order lands on a different last bit.
public enum ClinicGeo {
    /// Great-circle distance in metres, by the haversine formula.
    public static func distanceM(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double)
        -> Double
    {
        let degrees = Double.pi / 180
        let phi1 = lat1 * degrees
        let phi2 = lat2 * degrees
        let halfDphi = (phi2 - phi1) / 2
        let halfDlambda = (lng2 - lng1) * degrees / 2
        let a = pow(sin(halfDphi), 2) + cos(phi1) * cos(phi2) * pow(sin(halfDlambda), 2)
        let radius = ClinicData.bundled.constants.earthRadiusM
        return 2 * radius * asin(min(1.0, a.squareRoot()))
    }

    /// `round(distance)` for the too-far refusal: half to even.
    public static func roundedMetres(_ distance: Double) -> Int {
        Int(distance.rounded(.toNearestOrEven))
    }
}
