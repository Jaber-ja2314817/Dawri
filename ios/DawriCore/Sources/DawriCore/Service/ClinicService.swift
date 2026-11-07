/// One event on a visit's live updates, mirroring `onOpen`, `onEvent` and `onError` in
/// frontend/src/api/stream.ts. Events carry nothing a screen should trust: each one only
/// means "read the visit again", as frontend/src/state/useVisit.ts does.
public enum VisitUpdate: Sendable, Equatable {
    /// Connected. Read the visit, for whatever happened while no stream was open.
    case open
    /// Something changed. Read the visit.
    case changed
    /// The stream ended and yields nothing more. The caller decides when to retry.
    case dropped
}

/// What every screen talks to, so a screen never knows which back end it has. Mirrors
/// frontend/src/api/endpoints.ts, plus `sendChat` from frontend/src/features/chat/send.ts.
///
/// `transcribe` is deliberately left out: the app never calls /api/asr, because voice is
/// always transcribed on the phone.
///
/// The service holds its own token, so screens never see it.
public protocol ClinicService: Sendable {
    func authStart(qid: String) async throws -> AuthStartResponse
    /// Keeps the session token and returns only the patient.
    func authVerify(qid: String, otp: String) async throws -> Patient
    func demoPatients() async throws -> [DemoPatient]
    func health() async throws -> Health
    func getMe() async throws -> Me

    /// Consent has been given by the time this is called, so the body always says so.
    /// A nil patient is the account holder.
    func createVisit(patientId: String?) async throws -> CreateVisitResponse
    func listVisits() async throws -> [VisitRow]
    func getVisit(visitId: String) async throws -> Visit

    func sendChat(visitId: String, text: String) async throws -> ChatResponse

    /// The remote client sends the web's body: `{json: {service}}` with a service, else `{}`.
    func confirmIntake(visitId: String, service: Service?) async throws -> ConfirmResponse
    func continueRefill(visitId: String) async throws -> ConfirmResponse
    func emergencyOverride(visitId: String) async throws -> OverrideResponse

    func listCentres(
        service: String, visitId: String, lat: Double?, lng: Double?
    ) async throws -> CentreList
    func reserve(visitId: String, centreId: String) async throws -> ReserveResponse
    func arrive(visitId: String, body: ArriveBody) async throws -> ArriveResponse
    func rateVisit(visitId: String, stars: Int) async throws -> RatingResponse

    /// Whether a session is held, for `guardedRoute`.
    var isSignedIn: Bool { get async }
    /// Forgets the session token.
    func signOut() async

    /// Yields `.open` once connected, `.changed` on each event, and `.dropped` last.
    func visitUpdates(visitId: String) async -> AsyncStream<VisitUpdate>
}
