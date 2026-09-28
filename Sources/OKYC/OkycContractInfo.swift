import Foundation

/// What this SDK implements of the SDK contract, read from the real code paths (not a copy of the contract).
/// `OkycContractTests` loads the contract and fails when anything here disagrees with it.
enum OkycContractInfo {
    static let protocolVersion = OkycEvent.protocolVersion
    static let messageSource = OkycEvent.source
    static let maxMessageBytes = OkycEvent.maxMessageBytes

    /// `bridges.ios`: `window.webkit.messageHandlers.<name>.postMessage(…)`.
    static let bridgeName = OkycViewController.bridgeName

    /// Wire names of every event the parser accepts.
    static let events = OkycEvent.Kind.allCases.map(\.rawValue)
    /// Events parsed but not delivered to the host app (contract `mobile: ignore`).
    static let ignoredEvents = OkycEvent.Kind.allCases.filter { !$0.isForwarded }.map(\.rawValue)

    /// Contract config name → this SDK's default, in contract units (`duration_ms` in milliseconds).
    /// `session_url` is required, so it has none.
    static var configDefaults: [String: Any?] {
        let config = OkycConfig(sessionURL: URL(string: "https://verify.okyc.stream/s/ses")!)
        return [
            "locale": config.locale,
            "theme": config.theme.rawValue,
            "allowed_hosts": config.allowedHosts,
            "block_screenshots": config.blockScreenshots,
            "auto_close_delay": config.autoCloseDelay.map { Int(($0 * 1000).rounded()) },
        ]
    }

    static let themes = OkycTheme.allCases.map(\.rawValue)

    /// Public `OkycConfig` properties that are not contract options (`platform_extras.ios`).
    static let platformExtras = ["presentation"]

    static let digilockerHosts = NavigationPolicy.digilockerHosts
}
