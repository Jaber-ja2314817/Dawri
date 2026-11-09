import DawriCore
import Foundation
import Observation
import SwiftUI

/// `MeState` in frontend/src/state/session.tsx.
enum MeState: Sendable, Equatable {
    case idle, loading, ready, failed
}

/// S06 above the stack. A visit's emergency screen is never a path entry, so there is no entry
/// for Back or a swipe to return to.
struct EmergencyCover: Identifiable, Equatable {
    let visitId: String
    /// The chat has just said emergency, so 999 shows before the visit is read.
    var redFlag: Bool

    var id: String { visitId }
}

/// The app's state above the navigation stack: the clinic behind the protocol, the session, the
/// language, the health result and the path. Language, path and drafts live here so a language
/// switch cannot lose them. The session half is the port of frontend/src/state/session.tsx.
@MainActor
@Observable
final class AppModel {
    private static let healthRetry = Duration.seconds(10)

    @ObservationIgnored let service: any ClinicService
    /// The clinic behind `service`: this phone, or the clinic server it was connected to.
    @ObservationIgnored let clinic: ClinicKind
    let language: LanguageState
    @ObservationIgnored let direction: DirectionBridge
    @ObservationIgnored let features: PhoneFeatures
    /// Settings that outlive a language reset, such as the mode and server address.
    @ObservationIgnored let settings: any KeyValueStore
    /// The Live Activity and the local notifications, kept in step with every visit read.
    @ObservationIgnored let liveTicket: LiveTicketCoordinator

    private(set) var isSignedIn: Bool
    private(set) var me: Me?
    private(set) var meState: MeState
    private(set) var meError: (any Error)?
    private var loggedIn: Patient?
    private(set) var health: Health?
    /// The server's `/api/health` stopped saying simulated, so the service refuses every call.
    private(set) var healthRefused = false

    var path: [Route]
    private(set) var emergency: EmergencyCover? {
        didSet { direction.stackIsCovered = emergency != nil }
    }
    /// Bumped by `dismissEmergency`, because a cover dismissal does not refire `onAppear`.
    private(set) var homeRefresh = 0
    /// Set when a visit vanished, so S03 can say so, as the web's `demoReset` route state does.
    private(set) var showsDemoReset = false

    @ObservationIgnored private var meRequest = 0
    /// Who is signed in now. A chat turn answered with a red flag moves only the session that
    /// sent it, so a new sign-in on this phone is never taken to someone else's S06.
    @ObservationIgnored private(set) var sessionToken: String?
    /// One chat and one microphone per visit, above the screens, so leaving S05 ends nothing and
    /// a draft survives a language switch or a trip Home. Signing out clears them.
    @ObservationIgnored private var chats: [String: ChatModel] = [:]
    @ObservationIgnored private var voices: [String: VoiceModel] = [:]
    /// The last visit any gate read, so the next gate starts from it and shows no skeleton.
    @ObservationIgnored private var lastVisit: Visit?
    /// Entries a stage move put on the path, until their screen asks. S10 and S11 play their
    /// haptics only for a visit that moved on to them, never when opened from Home or History.
    @ObservationIgnored private var movedOn: Set<Route> = []

    #if DEBUG
    /// The staged visit, for the test controls.
    @ObservationIgnored var demoVisitId: String?
    /// The last result of a test control, or the last link opened.
    var demoStatus = "idle"
    @ObservationIgnored var demoLastAction: Task<Void, Never>?
    /// How many times a gate has shown its skeleton, for the no-skeleton test.
    var demoSkeletons = 0
    /// How many stage moves waited for a held swipe to end, for the mid-swipe test.
    var demoSwipeWaits = 0
    #endif

    init(
        service: any ClinicService, language: LanguageState, isSignedIn: Bool = false,
        path: [Route] = [], features: PhoneFeatures = .unavailable,
        settings: any KeyValueStore = UserDefaults.standard, clinic: ClinicKind = .local
    ) {
        self.service = service
        self.clinic = clinic
        self.language = language
        self.isSignedIn = isSignedIn
        self.meState = isSignedIn ? .loading : .idle
        self.features = features
        self.settings = settings
        self.direction = DirectionBridge(initial: language.lang)
        self.liveTicket = LiveTicketCoordinator(
            live: features.live, notifier: features.notifier, service: service,
            driver: service as? any DemoDriving, lang: { language.lang })
        // S06 is never pushed, including when a launch asks for it.
        self.path = path.filter { $0.emergencyVisitId == nil }
        self.emergency = path.compactMap(\.emergencyVisitId).last.map {
            EmergencyCover(visitId: $0, redFlag: false)
        }
        direction.stackIsCovered = emergency != nil
        if isSignedIn { sessionToken = UUID().uuidString }
    }

    // `AppHost.launch()` makes the first model: the clinic on this phone by default, so the app
    // works from first launch with nothing else running, or the saved clinic server. A saved
    // session is read before the first frame, so it opens on Home with no Welcome frame.
    // Screens only know the protocol.

    /// `.welcome` is the stack's root before login and `.home` after.
    var root: Route { isSignedIn ? .home : .welcome }

    /// `me?.patient ?? the patient from sign-in`.
    var patient: Patient? { me?.patient ?? loggedIn }

    /// `footer.ai` shows whenever the AI mode is simulated, which is always in this app, so it
    /// stays up while the first health read is on its way, however long that takes.
    var showsSimulatedLine: Bool {
        (health?.aiMode ?? .simulated) == .simulated
    }

    /// The demo clinic's controls, which only On this phone mode has.
    var demoDriver: (any DemoDriving)? {
        service as? any DemoDriving
    }

    // Session

    /// Runs once, for the life of the app. Side by side, so a session read that hangs cannot stop
    /// the health read.
    func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.loadSession() }
            group.addTask { await self.loadHealth() }
        }
    }

    private func loadSession() async {
        let held = await service.isSignedIn
        if held != isSignedIn {
            if held {
                isSignedIn = true
                sessionToken = UUID().uuidString
                path.removeAll()
            } else {
                endSession()
            }
        }
        if isSignedIn { await reloadMe() }
    }

    /// Asks until answered, because the first read can come before the network does. On a
    /// clinic server this is the gate's own read, so a server that is not simulated is noted
    /// for Settings and asked again later.
    private func loadHealth() async {
        while !Task.isCancelled {
            do {
                health = try await service.health()
                healthRefused = false
                return
            } catch {
                if (error as? ClinicError)?.code == ClinicError.serverNotSimulatedCode { healthRefused = true }
            }
            try? await Task.sleep(for: Self.healthRetry)
        }
    }

    /// `authStart` then `authVerify`. Throws what the service threw, for S02 to place. The path
    /// is cleared in the same step, so the pushed `.login` entry cannot render a second Home.
    func signIn(qid: String, otp: String) async throws {
        _ = try await service.authStart(qid: qid)
        let verified = try await service.authVerify(qid: qid, otp: otp)
        loggedIn = verified
        applyPreferred(verified.preferredLang)
        isSignedIn = true
        sessionToken = UUID().uuidString
        meState = .loading
        showsDemoReset = false
        path.removeAll()
        Task { await reloadMe() }
    }

    func signOut() {
        Task { await service.signOut() }
        endSession()
    }

    /// Screens call this after any refresh. A failed one keeps what is on screen.
    func reloadMe() async {
        meRequest += 1
        let request = meRequest
        if meState != .ready { meState = .loading }
        meError = nil
        do {
            let next = try await service.getMe()
            guard request == meRequest else { return }
            me = next
            meState = .ready
            applyPreferred(next.patient.preferredLang)
        } catch {
            guard request == meRequest, !sessionEnded(by: error) else { return }
            meError = error
            if meState != .ready { meState = .failed }
        }
    }

    /// A 401 from anywhere ends the session, as the web's token change does. Every loader passes
    /// its failures through this, and stops if it says true.
    @discardableResult
    func sessionEnded(by error: any Error) -> Bool {
        guard (error as? ClinicError)?.status == 401, isSignedIn else { return false }
        signOut()
        return true
    }

    /// What `RequireSession` does on the web: the guards send a signed-out viewer to /login.
    private func endSession() {
        meRequest += 1
        isSignedIn = false
        sessionToken = nil
        endChats()
        loggedIn = nil
        me = nil
        meState = .idle
        meError = nil
        lastVisit = nil
        showsDemoReset = false
        // Nothing of the last patient stays on the Lock Screen or in the notification queue.
        liveTicket.endAll()
        withoutAnimation {
            emergency = nil
            path = [.login]
        }
        changeLanguage(language.reset)
    }

    // Navigation

    /// A push, through the session guards of the web's router.
    func open(_ route: Route) {
        let guarded = guardedRoute(route, isSignedIn: isSignedIn)
        if let visitId = guarded.emergencyVisitId {
            showEmergency(visitId: visitId, redFlag: false)
        } else if guarded == root {
            path.removeAll()
        } else if path.last != guarded {
            path.append(guarded)
        }
    }

    /// A single visit entry above Home, for Consent and Home rows. A nil screen is `/visit/:id`,
    /// which goes on to the visit's canonical screen.
    func enterVisit(_ id: String, screen: Screen? = nil) {
        showsDemoReset = false
        let route = screen.map { routeFor(visitId: id, screen: $0) } ?? .visitRoot(id: id)
        if let visitId = route.emergencyVisitId {
            showEmergency(visitId: visitId, redFlag: false)
        } else {
            path = route == root ? [] : [route]
        }
    }

    /// The web's `navigate(..., { replace: true })`. The old entry goes, so Back and swipe-back
    /// can never return to a screen the visit has moved past. A stage that moves on during a
    /// swipe waits for the swipe to end, and does nothing if the swipe took that screen away.
    func replace(_ route: Route, with next: Route) async {
        #if DEBUG
        if direction.isSwipingBack { demoSwipeWaits += 1 }
        #endif
        while direction.isSwipingBack {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        if route.emergencyVisitId != nil, route.emergencyVisitId == emergency?.visitId {
            // The visit is not an emergency after all, and the cover has no back.
            withoutAnimation {
                emergency = nil
                path = next == root ? [] : [next]
            }
            return
        }
        guard let index = path.lastIndex(of: route) else { return }
        // A stage move, not `/visit/:id` finding its screen, which is only a way in.
        if case .visit = route { movedOn.insert(next) }
        if let visitId = next.emergencyVisitId {
            showEmergency(visitId: visitId, redFlag: false)
        } else if next == root {
            path.removeSubrange(index...)
        } else {
            path.replaceSubrange(index..., with: [next])
        }
    }

    /// Opens S06 at once. The chat's entry leaves in the same transaction, so nothing can return
    /// to it, and there is no slide: it must interrupt.
    func showEmergency(visitId: String, redFlag: Bool) {
        // An emergency ends the ticket's activity and every notice at once.
        liveTicket.end(visitId: visitId)
        withoutAnimation {
            path.removeAll { $0.visitId == visitId }
            let held = emergency?.visitId == visitId && emergency?.redFlag == true
            emergency = EmergencyCover(visitId: visitId, redFlag: redFlag || held)
        }
    }

    /// `emergency.home`: back to S03, which reads its visits again.
    func dismissEmergency() {
        withoutAnimation {
            emergency = nil
            path.removeAll()
        }
        homeRefresh += 1
    }

    /// What a 404 from `getVisit` does: a demo reset took the visit, so go home and say so.
    func visitGone() {
        lastVisit = nil
        // A demo reset took it: end whatever no longer matches a live visit.
        Task { await liveTicket.reconcile() }
        withoutAnimation {
            emergency = nil
            path.removeAll()
        }
        showsDemoReset = true
        homeRefresh += 1
    }

    /// True once, for a screen that a stage move just put on the path.
    func arrivedByMovingOn(_ route: Route) -> Bool {
        movedOn.remove(route) != nil
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    // The chat

    /// The visit's chat, made on first use. Its routes are the web's: S06 from anywhere for the
    /// session that sent the turn, and S07 or S08 in place of the chat's own entry.
    func chat(for visit: Visit) -> ChatModel {
        if let chat = chats[visit.visitId] { return chat }
        let id = visit.visitId
        let chatRoute = Route.visit(id: id, screen: .chat)
        let chat = ChatModel(
            service: service, visit: visit,
            routes: ChatModel.Routes(
                emergency: { [weak self] in
                    self?.showEmergency(visitId: id, redFlag: true)
                },
                refill: { [weak self] in
                    Task { await self?.replace(chatRoute, with: .visit(id: id, screen: .refill)) }
                },
                movedOn: { [weak self] in
                    Task { await self?.replace(chatRoute, with: .visit(id: id, screen: .centre)) }
                },
                failed: { [weak self] error in
                    self?.sessionEnded(by: error)
                }),
            session: { [weak self] in self?.sessionToken })
        #if DEBUG
        if let draft = DemoChat.draft(lang: language.lang) { chat.setDraft(draft) }
        #endif
        chats[id] = chat
        return chat
    }

    /// The visit's microphone, on the phone's recogniser. Nothing it hears leaves the phone.
    func voice(for visitId: String) -> VoiceModel {
        if let voice = voices[visitId] { return voice }
        #if DEBUG
        let voice = DemoChat.engine.map {
            VoiceModel(engine: $0, language: language.lang, now: DemoChat.now)
        } ?? VoiceModel(engine: features.voice, language: language.lang)
        #else
        let voice = VoiceModel(engine: features.voice, language: language.lang)
        #endif
        voices[visitId] = voice
        return voice
    }

    /// Signing out: any open microphone closes, and the next patient starts with empty boxes.
    /// A turn still in flight runs on, and its session check keeps it from moving anyone.
    private func endChats() {
        for voice in voices.values {
            Task { await voice.leave() }
        }
        chats.removeAll()
        voices.removeAll()
    }

    // The last visit read

    /// Every visit read. The Live Activity and the notices follow it.
    func remember(_ visit: Visit) {
        lastVisit = visit
        liveTicket.observe(visit)
    }

    func seed(for id: String) -> Visit? {
        lastVisit?.visitId == id ? lastVisit : nil
    }

    // Language

    /// Any time, with no restart. The path stays exactly as it is.
    func switchLanguage(to next: Lang) {
        direction.crossfade {
            changeLanguage { language.setLang(next) }
        }
    }

    private func applyPreferred(_ preferred: String) {
        changeLanguage { language.applyPreferred(preferred) }
    }

    /// Every language change, so the bars and the swipe edge always follow it.
    private func changeLanguage(_ change: () -> Void) {
        let before = language.lang
        change()
        if language.lang != direction.lang { direction.apply(language.lang) }
        // A Live Activity's language is fixed, so a live one restarts in the new language.
        if language.lang != before { liveTicket.languageChanged() }
    }
}

extension Route {
    /// The visit this entry belongs to.
    fileprivate var visitId: String? {
        switch self {
        case .visitRoot(let id), .visit(let id, _): id
        default: nil
        }
    }

    /// Set on the one route that is never a path entry.
    fileprivate var emergencyVisitId: String? {
        if case .visit(let id, screen: .emergency) = self { id } else { nil }
    }
}
