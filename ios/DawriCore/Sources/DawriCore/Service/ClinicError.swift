import Foundation

/// The port of `ApiError` in frontend/src/api/client.ts.
public struct ClinicError: Error, Sendable, Equatable {
    public let status: Int
    public let code: String
    public let message: String
    public let messageAr: String?
    public let extra: [String: JSONValue]

    public init(
        status: Int, code: String, message: String, messageAr: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.messageAr = messageAr
        self.extra = extra
    }

    /// `toApiError` in client.ts, over the raw response body. A body that is not the backend's
    /// `{error, message, ...}`, such as a proxy's HTML page, is an `internal_error`.
    public init(status: Int, body: Data) {
        guard case .object(var payload)? = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .string(let code)? = payload.removeValue(forKey: "error")
        else {
            self.init(
                status: status, code: "internal_error",
                message: "Unexpected response from the server.")
            return
        }
        var message = code
        if case .string(let text)? = payload.removeValue(forKey: "message") { message = text }
        var messageAr: String?
        if case .string(let text)? = payload.removeValue(forKey: "message_ar") { messageAr = text }
        self.init(
            status: status, code: code, message: message, messageAr: messageAr, extra: payload)
    }

    /// What a failed request becomes in client.ts: the server was never reached.
    public static let network = ClinicError(
        status: 0, code: "network", message: "The network request failed.")

    /// Clinic server mode only: the server's `/api/health` did not say `ai_mode: simulated`, so
    /// `RemoteClinicService` sent nothing else. Status 403 because the app refused it itself and
    /// nothing was sent, so a chat turn is known not to have arrived. It carries the Settings
    /// wording in both languages, so `errorText` needs no key of its own.
    public static let serverNotSimulated = ClinicError(
        status: 403, code: serverNotSimulatedCode,
        message: Strings.bundled.translate(.en, "settings.server.refusedAi"),
        messageAr: Strings.bundled.translate(.ar, "settings.server.refusedAi"))

    public static let serverNotSimulatedCode = "server_not_simulated"
}

/// A sentence for the screen. Raw backend English never lands on an Arabic screen.
public func errorText(_ error: any Error, strings: Strings, lang: Lang) -> String {
    if let error = error as? ClinicError {
        if let messageAr = error.messageAr { return lang == .ar ? messageAr : error.message }
        let key = "error.\(error.code)"
        let text = strings.translate(lang, key)
        if text != key { return text }
    }
    return strings.translate(lang, "error.generic")
}
