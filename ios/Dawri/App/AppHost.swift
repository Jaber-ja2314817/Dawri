import DawriCore
import Foundation
import Observation

/// Which clinic a model talks to: the one on this phone, or a clinic server that passed both
/// guards.
enum ClinicKind: Sendable, Equatable {
    case local
    case server(URL)

    var serverURL: URL? {
        if case .server(let url) = self { url } else { nil }
    }
}

/// How the host makes each clinic. A normal launch uses `.device`, and a DEBUG launch its own,
/// so a launch hook never touches the phone's saved settings or Keychain.
@MainActor
struct ClinicMaker {
    /// Shared by every model, so a switch keeps the language and the bars' direction.
    let language: LanguageState
    /// Where the mode and the server address are saved.
    let settings: any KeyValueStore
    let features: PhoneFeatures
    /// The clinic on this phone, made once for the life of the app, with whether it holds a
    /// saved session.
    let local: () -> (service: any ClinicService, signedIn: Bool)
    /// A clinic server's service for a base that passed `ServerAddress`, with whether its token
    /// store holds a session. `signedOut` forgets any token first. Throws when the base is
    /// refused, before any request.
    let server: (_ base: URL, _ signedOut: Bool) throws -> (service: any ClinicService, signedIn: Bool)

    /// The phone's own: the clinic in Application Support, the phone's settings, and for a
    /// server, `RemoteClinicService` on the app's one transport with its token in the Keychain.
    static var device: ClinicMaker {
        ClinicMaker(
            language: LanguageState(store: UserDefaults.standard), settings: UserDefaults.standard,
            features: .device,
            local: {
                let service = LocalClinicService(store: FileClinicStore())
                return (service, service.restoredSession)
            },
            server: { base, signedOut in
                let tokens = KeychainTokenStore()
                if signedOut { tokens.clear() }
                let service = try RemoteClinicService(
                    baseURL: base, transport: ClinicNetwork.transport, tokens: tokens)
                return (service, tokens.load() != nil)
            })
    }
}

/// Owns the app's current `AppModel`, and swaps it when Settings changes the clinic. `DawriApp`
/// holds the host and `RootView` is identified by the model, so the session load, the visit
/// screens and the Live Activity follower all start again on the new clinic. The language is
/// shared, so a switch never changes it.
///
/// The two modes never share a session or a visit: each model has its own service, and the
/// server's token lives only in that service's store.
@MainActor
@Observable
final class AppHost {
    static let modeKey = "dawri.mode"
    static let serverKey = "dawri.server"

    private(set) var model: AppModel

    @ObservationIgnored private let maker: ClinicMaker
    /// The clinic on this phone, kept once made, so going back finds its saved session.
    @ObservationIgnored private var localService: (any ClinicService)?

    /// - Parameter launch: the first model, when the caller made it. Otherwise the saved mode
    ///   decides: `server` with a saved address that passes `ServerAddress` launches on that
    ///   server, whose gate reads `/api/health` again before its first request. Anything else
    ///   launches on this phone.
    init(maker: ClinicMaker, launch: AppModel? = nil) {
        self.maker = maker
        if let launch {
            model = launch
            if launch.clinic == .local { localService = launch.service }
            return
        }
        if let base = Self.savedServer(in: maker.settings), let made = try? maker.server(base, false) {
            model = AppModel(
                service: made.service, language: maker.language, isSignedIn: made.signedIn,
                features: maker.features, settings: maker.settings, clinic: .server(base))
            return
        }
        let (service, signedIn) = maker.local()
        localService = service
        model = AppModel(
            service: service, language: maker.language, isSignedIn: signedIn,
            features: maker.features, settings: maker.settings, clinic: .local)
    }

    /// The normal launch, or in DEBUG the one the launch arguments ask for.
    static func launch() -> AppHost {
        #if DEBUG
        if let demo = DemoLaunch.current { return demo.makeHost() }
        #endif
        return AppHost(maker: .device)
    }

    /// The saved server, only while the saved mode is `server` and the address still passes.
    static func savedServer(in settings: any KeyValueStore) -> URL? {
        guard settings.read(modeKey) == "server", let text = settings.read(serverKey) else { return nil }
        return ServerAddress.parse(text).url
    }

    // Switching

    /// Settings' Connect passed both guards for `base`. The choice is saved, the old clinic's
    /// Live Activity and notices end, and the app moves to the server signed out, still on
    /// Settings. A server already in use stays as it is, session and all.
    ///
    /// - Throws: when `base` is refused, before any request. The app stays where it was.
    func useServer(_ base: URL) throws {
        guard model.clinic != .server(base) else { return }
        let (service, signedIn) = try maker.server(base, true)
        maker.settings.write("server", for: Self.modeKey)
        maker.settings.write(base.absoluteString, for: Self.serverKey)
        let old = model
        old.liveTicket.endAll()
        model = AppModel(
            service: service, language: maker.language, isSignedIn: signedIn, path: [.settings],
            features: maker.features, settings: maker.settings, clinic: .server(base))
        // A previous server's token was the one `maker.server` has just forgotten.
    }

    /// On this phone, at once, with its saved session, still on Settings. The server's token is
    /// forgotten, so the next Connect starts signed out.
    func useLocal() async {
        maker.settings.write("local", for: Self.modeKey)
        guard model.clinic != .local else { return }
        let old = model
        old.liveTicket.endAll()
        let service: any ClinicService
        let signedIn: Bool
        if let kept = localService {
            service = kept
            signedIn = await kept.isSignedIn
        } else {
            (service, signedIn) = maker.local()
            localService = service
        }
        // The old clinic's model may have been replaced while the session was read.
        guard model === old else { return }
        model = AppModel(
            service: service, language: maker.language, isSignedIn: signedIn, path: [.settings],
            features: maker.features, settings: maker.settings, clinic: .local)
        Task { await old.service.signOut() }
    }
}
