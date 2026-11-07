/// What the Live Activity shows. Plain data, so it builds everywhere and the app can test it.
public struct TicketLiveState: Sendable, Codable, Hashable {
    /// Nil only for a reserved ticket, which has no number yet.
    public var number: String?
    public var stage: VisitStage
    public var peopleAhead: Int?
    public var estWaitMin: Int?
    /// Already in the activity's language.
    public var counter: String

    public init(
        number: String?, stage: VisitStage, peopleAhead: Int?, estWaitMin: Int?, counter: String
    ) {
        self.number = number
        self.stage = stage
        self.peopleAhead = peopleAhead
        self.estWaitMin = estWaitMin
        self.counter = counter
    }
}

// Not canImport(ActivityKit): that framework exists in the macOS SDK, where ActivityAttributes
// may be unavailable, and this package must keep building for macOS.
#if os(iOS)
import ActivityKit

public struct TicketActivityAttributes: ActivityAttributes {
    public typealias ContentState = TicketLiveState

    /// Fixed for the life of the activity, as ActivityAttributes' static data is.
    public var lang: Lang

    public init(lang: Lang) {
        self.lang = lang
    }
}
#endif
