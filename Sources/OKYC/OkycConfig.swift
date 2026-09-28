import Foundation

/// Appearance of the hosted flow. `.system` follows the device setting.
public enum OkycTheme: String, Sendable, CaseIterable {
    case light, dark, system
}

/// How the flow is presented by `Okyc.start(from:config:)` and `.okycVerification(...)`.
public enum OkycPresentation: Sendable {
    /// Full-height sheet; swipe down cancels (default).
    case sheet
    /// Full screen; only the ✕ button cancels.
    case fullScreen
}

/// Configuration for one verification. Create a session on your backend (`POST /v1/sessions`) and pass its `url`.
/// Never embed a secret API key in an app.
public struct OkycConfig: Sendable, Equatable {
    /// The `url` returned by `POST /v1/sessions`, e.g. `https://verify.okyc.stream/s/ses_in_…#t=st_…`.
    public var sessionURL: URL
    /// UI language hint (`en`, `hi`). The session's locale is used when the flow doesn't support the hint.
    public var locale: String?
    public var theme: OkycTheme
    /// Extra hosts allowed inside the web view (self-hosting). Exact host or `*.example.com`; https only.
    public var allowedHosts: [String]
    /// Hide the flow in the app switcher and while the screen is recorded or mirrored. Default `true`.
    public var blockScreenshots: Bool
    /// Seconds to keep the result screen visible after `complete` before closing. `nil` keeps it open.
    public var autoCloseDelay: TimeInterval?
    public var presentation: OkycPresentation

    public init(
        sessionURL: URL,
        locale: String? = nil,
        theme: OkycTheme = .system,
        allowedHosts: [String] = [],
        blockScreenshots: Bool = true,
        autoCloseDelay: TimeInterval? = 2,
        presentation: OkycPresentation = .sheet
    ) {
        self.sessionURL = sessionURL
        self.locale = locale
        self.theme = theme
        self.allowedHosts = allowedHosts
        self.blockScreenshots = blockScreenshots
        self.autoCloseDelay = autoCloseDelay
        self.presentation = presentation
    }

    /// Convenience for a URL string; returns `nil` unless it is an absolute https URL (or http on a local
    /// development host).
    public init?(sessionURLString: String, locale: String? = nil, theme: OkycTheme = .system) {
        guard let url = URL(string: sessionURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              OkycConfig.isAllowedSessionURL(url)
        else { return nil }
        self.init(sessionURL: url, locale: locale, theme: theme)
    }

    static let localDevelopmentHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// The session URL carries the client token: https, or plain http only on a local development host.
    static func isAllowedSessionURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return scheme == "https" || (scheme == "http" && localDevelopmentHosts.contains(host))
    }

    /// Session id parsed from the URL path (`/s/<id>`), if present. Useful for `cancelled` results.
    public var sessionId: String? {
        let parts = sessionURL.path.split(separator: "/")
        guard let i = parts.firstIndex(of: "s"), i + 1 < parts.count else { return nil }
        return String(parts[i + 1])
    }

    /// URL actually loaded: `?locale=…&theme=…` inserted before the `#t=` fragment, which is preserved as is.
    var loadURL: URL {
        guard var comps = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false) else { return sessionURL }
        var items = (comps.queryItems ?? []).filter { $0.name != "locale" && $0.name != "theme" }
        if let locale { items.append(URLQueryItem(name: "locale", value: locale)) }
        items.append(URLQueryItem(name: "theme", value: theme.rawValue))
        comps.queryItems = items
        return comps.url ?? sessionURL
    }
}
