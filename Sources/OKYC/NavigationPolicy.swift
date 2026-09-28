import Foundation

/// Which URLs may load inside the web view.
/// Pure value type so it is unit-testable without WebKit.
public struct NavigationPolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case allow
        /// Open in the system browser (links meant to leave the flow, e.g. privacy policy).
        case openExternally
        case block
    }

    /// DigiLocker must load inside the web view so its OAuth return resumes the flow.
    public static let digilockerHosts = ["digilocker.meripehchaan.gov.in", "*.digilocker.gov.in", "api.digitallocker.gov.in"]

    let scheme: String
    let host: String
    let port: Int?
    let extraHosts: [String]

    public init(flowURL: URL, allowedHosts: [String] = []) {
        scheme = flowURL.scheme?.lowercased() ?? "https"
        host = flowURL.host?.lowercased() ?? ""
        port = flowURL.port ?? NavigationPolicy.defaultPort(scheme)
        extraHosts = (allowedHosts + NavigationPolicy.digilockerHosts).map { $0.lowercased() }
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// True if `url` has exactly the flow's origin (scheme + host + port).
    public func isFlowOrigin(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        return isFlowOrigin(scheme: s, host: url.host?.lowercased() ?? "", port: url.port ?? NavigationPolicy.defaultPort(s))
    }

    public func isFlowOrigin(scheme s: String, host h: String, port p: Int?) -> Bool {
        let s = s.lowercased()
        return s == scheme && h.lowercased() == host && (p == 0 ? NavigationPolicy.defaultPort(s) : p) == port
    }

    func matchesExtraHost(_ h: String) -> Bool {
        extraHosts.contains { pattern in
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1)) // ".example.com"
                return h.hasSuffix(suffix) && h.count > suffix.count
            }
            return h == pattern
        }
    }

    /// - Parameters:
    ///   - isMainFrame: navigation targets the top-level frame.
    ///   - opensNewWindow: `target=_blank` / `window.open`.
    public func decide(_ url: URL, isMainFrame: Bool = true, opensNewWindow: Bool = false) -> Decision {
        let s = url.scheme?.lowercased() ?? ""
        if s == "about" { return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" ? .allow : .block }
        // In-page resources the flow creates itself (previews). Never top-level navigations to them.
        if s == "blob" || s == "data" { return isMainFrame ? .block : .allow }
        guard s == "https" || s == "http" else { return .block }
        let h = url.host?.lowercased() ?? ""
        if opensNewWindow { return isFlowOrigin(url) ? .allow : (s == "https" ? .openExternally : .block) }
        if isFlowOrigin(url) { return .allow }
        if s == "https", matchesExtraHost(h) { return .allow }
        // Leaving the flow in the main frame: external https links go to the browser; everything else is blocked.
        return isMainFrame && s == "https" ? .openExternally : .block
    }
}
