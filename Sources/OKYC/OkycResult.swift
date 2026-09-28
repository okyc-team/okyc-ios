import Foundation

/// Outcome of presenting the flow. The verification decision is authoritative only via your webhook or
/// `GET /v1/sessions/:id` on your backend — treat `completed` as "the applicant finished".
public enum OkycResult: Sendable, Equatable {
    /// The flow reached its result screen. `status`: approved, declined, review, processing, expired…
    case completed(sessionId: String, status: String)
    /// The user closed the flow (✕, swipe down) before finishing.
    case cancelled(sessionId: String?)
    /// The flow could not run or continue. `code` is one of `OkycErrorCode`; `sessionId` is set when the session
    /// URL could be read.
    case failed(code: String, message: String, sessionId: String? = nil)
}

/// Error codes used in `OkycResult.failed` (`failure_codes` in the SDK contract).
public enum OkycErrorCode {
    /// Missing or malformed session URL or configuration.
    public static let invalidConfig = "invalid_config"
    /// The flow page failed to load.
    public static let loadFailed = "load_failed"
    /// No connection or DNS/TLS failure while loading.
    public static let networkError = "network_error"
    /// Repeated navigation to non-allowlisted hosts.
    public static let navigationBlocked = "navigation_blocked"
    /// The camera permission was permanently denied and the flow cannot continue.
    public static let permissionDenied = "permission_denied"
    /// The flow reported an unrecoverable error.
    public static let flowError = "flow_error"
    /// The web content process crashed repeatedly or WebKit is unavailable.
    public static let webviewUnavailable = "webview_unavailable"
    /// No view controller was available to present the flow (iOS only).
    public static let presentationFailed = "presentation_failed"

    @available(*, deprecated, renamed: "networkError")
    public static let network = networkError
}

/// Events from the hosted flow (protocol v1). Payloads carry ids and statuses only.
public struct OkycEvent: Sendable, Equatable {
    /// `type` on the wire (`events` in the SDK contract).
    public enum Kind: String, Sendable, CaseIterable {
        case ready
        case stepStarted = "step_started"
        case stepCompleted = "step_completed"
        case complete
        case error
        case exit
        case resize

        /// Delivered to the host app. `resize` is for web embeds only (contract: `mobile: ignore`).
        var isForwarded: Bool { self != .resize }
    }

    /// `message.max_bytes` in the SDK contract (UTF-8).
    static let maxMessageBytes = 10_240
    static let source = "okyc"
    static let protocolVersion = 1

    public let kind: Kind
    public let sessionId: String
    /// String/number/bool values from the payload, stringified (e.g. `["step": "pan"]`, `["status": "approved"]`).
    public let payload: [String: String]

    public init(kind: Kind, sessionId: String, payload: [String: String] = [:]) {
        self.kind = kind
        self.sessionId = sessionId
        self.payload = payload
    }

    /// Parses a bridge message. Returns `nil` for anything that isn't a valid OKYC v1 event.
    public static func parse(_ body: Any) -> OkycEvent? {
        let object: Any?
        if let string = body as? String {
            guard string.utf8.count <= maxMessageBytes, let data = string.data(using: .utf8) else { return nil }
            object = try? JSONSerialization.jsonObject(with: data)
        } else {
            object = body
        }
        guard let dict = object as? [String: Any],
              dict["source"] as? String == source,
              (dict["v"] as? NSNumber)?.intValue == protocolVersion,
              let typeRaw = dict["type"] as? String,
              let kind = Kind(rawValue: typeRaw),
              let sessionId = dict["sessionId"] as? String, !sessionId.isEmpty, sessionId.count <= 64
        else { return nil }
        var payload: [String: String] = [:]
        if let p = dict["payload"] as? [String: Any] {
            for (k, v) in p.prefix(20) {
                switch v {
                case let s as String: payload[k] = String(s.prefix(200))
                case let n as NSNumber:
                    payload[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
                default: continue
                }
            }
        }
        return OkycEvent(kind: kind, sessionId: sessionId, payload: payload)
    }

    /// The result an event implies, if any (`complete` → completed).
    var impliedResult: OkycResult? {
        switch kind {
        case .complete: return .completed(sessionId: sessionId, status: payload["status"] ?? "processing")
        case .exit: return .cancelled(sessionId: sessionId)
        default: return nil
        }
    }
}
