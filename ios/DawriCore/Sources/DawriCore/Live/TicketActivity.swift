/// What the Live Activity shows. Plain data, so it builds everywhere and the app can test it.
/// Every text in it is already in the activity's language, which is fixed for its life.
public struct TicketLiveState: Sendable, Codable, Hashable {
    /// Nil between stages, when the visit has moved on and its next ticket is not issued yet.
    /// No activity runs while reserved, so a reserved ticket never reaches here.
    public var number: String?
    /// Triage, doctor or pharmacy while it runs, and `.completed` in the final state.
    public var stage: VisitStage
    public var peopleAhead: Int?
    public var estWaitMin: Int?
    /// Already in the activity's language.
    public var counter: String
    /// Active, called or serving. Nil between stages, and in the final state.
    public var ticketState: TicketState?
    /// The centre's name in the activity's language, for Row 1 and the expanded centre.
    public var centreName: String

    public init(
        number: String?, stage: VisitStage, peopleAhead: Int?, estWaitMin: Int?, counter: String,
        ticketState: TicketState? = nil, centreName: String = ""
    ) {
        self.number = number
        self.stage = stage
        self.peopleAhead = peopleAhead
        self.estWaitMin = estWaitMin
        self.counter = counter
        self.ticketState = ticketState
        self.centreName = centreName
    }
}

// Not canImport(ActivityKit): that framework exists in the macOS SDK, where ActivityAttributes
// may be unavailable, and this package must keep building for macOS.
#if os(iOS)
import ActivityKit

public struct TicketActivityAttributes: ActivityAttributes {
    public typealias ContentState = TicketLiveState

    /// Fixed for the life of the activity, as ActivityAttributes' static data is. A language
    /// switch ends the activity and starts a new one.
    public var lang: Lang
    /// One activity per visit, found again through `Activity.activities` after a relaunch.
    public var visitId: String

    public init(lang: Lang, visitId: String) {
        self.lang = lang
        self.visitId = visitId
    }
}
#endif
