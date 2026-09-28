import AVFoundation
import UIKit
import WebKit

/// Receives events and the final result from an `OkycViewController`.
@MainActor
public protocol OkycViewControllerDelegate: AnyObject {
    func okyc(_ controller: OkycViewController, didReceive event: OkycEvent)
    func okyc(_ controller: OkycViewController, didFinishWith result: OkycResult)
}

public extension OkycViewControllerDelegate {
    func okyc(_ controller: OkycViewController, didReceive event: OkycEvent) {}
}

/// Hosts the OKYC verification flow in a hardened `WKWebView`.
///
/// Present it inside a `UINavigationController` (for the ✕ button), or use `Okyc.start(from:config:)`.
/// The result is delivered exactly once, via `delegate` and `onResult`.
@MainActor
public final class OkycViewController: UIViewController {
    /// Script message handler the flow posts to (`window.webkit.messageHandlers.okyc`).
    nonisolated static let bridgeName = "okyc"

    public let config: OkycConfig
    public weak var delegate: OkycViewControllerDelegate?
    public var onEvent: ((OkycEvent) -> Void)?
    public var onResult: ((OkycResult) -> Void)?
    /// Dismiss itself when the result is delivered (default). Turn off when embedding in your own container.
    public var dismissesOnFinish = true

    private let policy: NavigationPolicy
    private var webView: WKWebView!
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?
    private var privacyCover: UIView?
    private var finished = false
    private var loadedOnce = false
    private var blockedNavigations = 0
    private var lastSessionId: String?
    private var contentProcessTerminations = 0
    private var autoCloseWork: DispatchWorkItem?

    public init(config: OkycConfig) {
        self.config = config
        policy = NavigationPolicy(flowURL: config.sessionURL, allowedHosts: config.allowedHosts)
        super.init(nibName: nil, bundle: nil)
        lastSessionId = config.sessionId
        modalPresentationStyle = config.presentation == .fullScreen ? .fullScreen : .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()
        // Neutral chrome that matches the flow's surface (the flow carries the tenant's brand, not us).
        view.backgroundColor = Chrome.surface
        guard OkycConfig.isAllowedSessionURL(config.sessionURL) else {
            return finish(
                .failed(code: OkycErrorCode.invalidConfig,
                        message: "sessionURL must use https (http is allowed only for localhost development)",
                        sessionId: lastSessionId),
                dismiss: false)
        }
        switch config.theme {
        case .light: overrideUserInterfaceStyle = .light
        case .dark: overrideUserInterfaceStyle = .dark
        case .system: overrideUserInterfaceStyle = .unspecified
        }
        title = "Verification"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Close verification"
        // Per-item tint and appearance: the host app's tint and global bar styling don't leak in.
        // The bar takes its traits from the navigation controller (not our override), so pin an explicit theme.
        let barText = barColor(Chrome.text)
        navigationItem.leftBarButtonItem?.tintColor = barText
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = barColor(Chrome.surface)
        bar.shadowColor = barColor(Chrome.border)
        bar.titleTextAttributes = [.foregroundColor: barText]
        bar.largeTitleTextAttributes = [.foregroundColor: barText]
        navigationItem.standardAppearance = bar
        navigationItem.compactAppearance = bar
        navigationItem.scrollEdgeAppearance = bar
        navigationItem.largeTitleDisplayMode = .never

        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = dataStore
        wkConfig.allowsInlineMediaPlayback = true
        wkConfig.mediaTypesRequiringUserActionForPlayback = []
        wkConfig.preferences.javaScriptCanOpenWindowsAutomatically = false
        wkConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        wkConfig.userContentController.add(WeakScriptHandler(self), name: Self.bridgeName)

        webView = WKWebView(frame: .zero, configuration: wkConfig)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        // No white/black flash before the page paints: show the flow's surface colour instead.
        webView.isOpaque = false
        webView.backgroundColor = Chrome.surface
        webView.scrollView.backgroundColor = Chrome.surface
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = Chrome.text
        progress.trackTintColor = .clear
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            let value = Float(change.newValue ?? 0)
            Task { @MainActor in
                self?.progress.setProgress(value, animated: true)
                self?.progress.isHidden = value >= 1
            }
        }

        if config.blockScreenshots { observePrivacy() }
        webView.load(URLRequest(url: config.loadURL))
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Swipe-down on a sheet → cancelled (contract). Set here: the navigation controller is the presented one.
        (navigationController ?? self).presentationController?.delegate = self
        updatePrivacyCover()
    }

    /// `color` for the navigation bar: fixed to `config.theme` when it is explicit, dynamic for `.system`.
    private func barColor(_ color: UIColor) -> UIColor {
        switch config.theme {
        case .light: return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        case .dark: return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        case .system: return color
        }
    }

    // MARK: result

    @objc private func closeTapped() {
        finish(.cancelled(sessionId: lastSessionId), dismiss: true)
    }

    func finish(_ result: OkycResult, dismiss: Bool) {
        guard !finished else { return }
        finished = true
        autoCloseWork?.cancel()
        // Nothing from the flow may outlive it.
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        webView?.stopLoading()
        delegate?.okyc(self, didFinishWith: result)
        onResult?(result)
        if dismiss, dismissesOnFinish {
            (navigationController ?? self).presentingViewController?.dismiss(animated: true)
        }
    }

    fileprivate func handle(message body: Any) {
        guard let event = OkycEvent.parse(body) else { return }
        lastSessionId = event.sessionId
        if event.kind.isForwarded {
            delegate?.okyc(self, didReceive: event)
            onEvent?(event)
        }
        guard let result = event.impliedResult else { return }
        if case .completed = result, let delay = config.autoCloseDelay {
            let work = DispatchWorkItem { [weak self] in self?.finish(result, dismiss: true) }
            autoCloseWork?.cancel()
            autoCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else if case .cancelled = result {
            finish(result, dismiss: true)
        }
    }

    // MARK: privacy (app switcher, screen recording / mirroring)

    private func observePrivacy() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(updatePrivacyCover), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(updatePrivacyCover), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(updatePrivacyCover), name: UIScreen.capturedDidChangeNotification, object: nil)
    }

    private var isCaptured: Bool {
        (view.window?.windowScene?.screen ?? UIScreen.main).isCaptured
    }

    @objc private func updatePrivacyCover() {
        guard config.blockScreenshots else { return }
        let resigning = UIApplication.shared.applicationState != .active
        let hide = resigning || isCaptured
        if hide, privacyCover == nil {
            let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            cover.frame = view.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let label = UILabel()
            label.text = isCaptured ? "Hidden while the screen is being recorded" : "Verification"
            label.font = .preferredFont(forTextStyle: .headline)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            cover.contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: cover.contentView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: cover.contentView.centerYAnchor),
            ])
            view.addSubview(cover)
            privacyCover = cover
        } else if !hide, let cover = privacyCover {
            cover.removeFromSuperview()
            privacyCover = nil
        }
    }

    // MARK: failures

    private func fail(_ code: String, _ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        // WebKit "frame load interrupted" happens when we cancel a blocked/external navigation.
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        if loadedOnce { return } // the flow shows its own offline/errors after the first load
        let networkCode = ns.domain == NSURLErrorDomain ? OkycErrorCode.networkError : code
        finish(.failed(code: networkCode, message: ns.localizedDescription, sessionId: lastSessionId), dismiss: false)
    }
}

// MARK: - WKNavigationDelegate

extension OkycViewController: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        switch policy.decide(url, isMainFrame: isMain, opensNewWindow: navigationAction.targetFrame == nil) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        case .block:
            decisionHandler(.cancel)
            if isMain {
                blockedNavigations += 1
                if blockedNavigations > 5 {
                    finish(
                        .failed(code: OkycErrorCode.navigationBlocked, message: "The page tried to leave the verification flow", sessionId: lastSessionId),
                        dismiss: false)
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedOnce = true
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(OkycErrorCode.loadFailed, error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(OkycErrorCode.loadFailed, error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentProcessTerminations += 1
        guard contentProcessTerminations <= 1 else {
            // Crashing again (usually memory pressure during camera use): stop instead of looping.
            return finish(
                .failed(code: OkycErrorCode.webviewUnavailable, message: "The verification page stopped unexpectedly", sessionId: lastSessionId),
                dismiss: false)
        }
        // The flow resumes from the server state; the token is still in the URL fragment.
        webView.load(URLRequest(url: config.loadURL))
    }
}

// MARK: - WKUIDelegate (camera, new windows, JS dialogs)

extension OkycViewController: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `target=_blank` / window.open: never a second web view.
        if let url = navigationAction.request.url, policy.decide(url, isMainFrame: true, opensNewWindow: true) == .openExternally {
            UIApplication.shared.open(url)
        }
        return nil
    }

    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        // Only the flow itself may use the camera/microphone.
        guard policy.isFlowOrigin(scheme: origin.protocol, host: origin.host, port: origin.port) else {
            return decisionHandler(.deny)
        }
        let needsAudio = type == .microphone || type == .cameraAndMicrophone
        let needsVideo = type == .camera || type == .cameraAndMicrophone
        Task { @MainActor in
            let video = needsVideo ? await Self.requestAccess(.video) : true
            let audio = needsAudio ? await Self.requestAccess(.audio) : true
            decisionHandler(video && audio ? .grant : .deny)
        }
    }

    private static func requestAccess(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presentOrElse(alert) { completionHandler() }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presentOrElse(alert) { completionHandler(false) }
    }

    private func presentOrElse(_ alert: UIAlertController, fallback: () -> Void) {
        guard view.window != nil, presentedViewController == nil else { return fallback() }
        present(alert, animated: true)
    }
}

// MARK: - swipe-down dismissal

extension OkycViewController: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(.cancelled(sessionId: lastSessionId), dismiss: false)
    }
}

/// Neutral chrome colours, matching the hosted flow's surface/border/text tokens (light / dark).
/// Resolved from the trait collection, so `overrideUserInterfaceStyle` (config.theme) applies.
enum Chrome {
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x12131B)
    static let border = dynamic(light: 0xE4E6EC, dark: 0x262837)
    static let text = dynamic(light: 0x0F1222, dark: 0xECEDF3)

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: OkycViewController?
    init(_ target: OkycViewController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only messages from the flow's own origin, main frame.
        guard message.frameInfo.isMainFrame else { return }
        let origin = message.frameInfo.securityOrigin
        MainActor.assumeIsolated {
            guard let target, NavigationPolicy(flowURL: target.config.sessionURL)
                .isFlowOrigin(scheme: origin.protocol, host: origin.host, port: origin.port) else { return }
            target.handle(message: message.body)
        }
    }
}
