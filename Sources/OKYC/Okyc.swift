import SwiftUI
import UIKit

/// Entry point for UIKit apps.
///
/// ```swift
/// let result = await Okyc.start(from: self, config: OkycConfig(sessionURL: url))
/// ```
@MainActor
public enum Okyc {
    public static let version = "0.1.1"

    /// Presents the flow modally and returns when it finishes (completed, cancelled or failed).
    /// Returns `failed(presentation_failed)` if `presenter` is not on screen or is already presenting something.
    public static func start(
        from presenter: UIViewController,
        config: OkycConfig,
        onEvent: ((OkycEvent) -> Void)? = nil
    ) async -> OkycResult {
        guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            return .failed(
                code: OkycErrorCode.presentationFailed,
                message: "The presenting view controller is not in a window or is already presenting",
                sessionId: config.sessionId)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<OkycResult, Never>) in
            let controller = OkycViewController(config: config)
            controller.onEvent = onEvent
            controller.onResult = { continuation.resume(returning: $0) }
            presenter.present(makeContainer(controller), animated: true)
        }
    }

    static func makeContainer(_ controller: OkycViewController) -> UINavigationController {
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = controller.config.presentation == .fullScreen ? .fullScreen : .pageSheet
        if let sheet = nav.sheetPresentationController { sheet.detents = [.large()] }
        return nav
    }
}

/// SwiftUI view that hosts the flow (with its own navigation bar and ✕ button).
public struct OkycView: UIViewControllerRepresentable {
    let config: OkycConfig
    let onEvent: ((OkycEvent) -> Void)?
    let onResult: (OkycResult) -> Void

    public init(config: OkycConfig, onEvent: ((OkycEvent) -> Void)? = nil, onResult: @escaping (OkycResult) -> Void) {
        self.config = config
        self.onEvent = onEvent
        self.onResult = onResult
    }

    public func makeUIViewController(context: Context) -> UINavigationController {
        let controller = OkycViewController(config: config)
        controller.dismissesOnFinish = false // SwiftUI owns presentation
        controller.onEvent = onEvent
        controller.onResult = onResult
        return UINavigationController(rootViewController: controller)
    }

    public func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

private final class ResultBox {
    var delivered = false
}

private struct OkycVerificationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let config: OkycConfig?
    let onEvent: ((OkycEvent) -> Void)?
    let onResult: (OkycResult) -> Void
    @State private var box = ResultBox()

    private func deliver(_ result: OkycResult) {
        guard !box.delivered else { return }
        box.delivered = true
        isPresented = false
        onResult(result)
    }

    @ViewBuilder
    private var sheet: some View {
        if let config {
            OkycView(config: config, onEvent: onEvent) { deliver($0) }
                .ignoresSafeArea(edges: .bottom)
                .onAppear { box.delivered = false }
        } else {
            Color.clear.onAppear {
                deliver(.failed(code: OkycErrorCode.invalidConfig, message: "No session URL"))
            }
        }
    }

    func body(content: Content) -> some View {
        if config?.presentation == .fullScreen {
            content.fullScreenCover(isPresented: $isPresented, onDismiss: dismissed) { sheet }
        } else {
            content.sheet(isPresented: $isPresented, onDismiss: dismissed) { sheet }
        }
    }

    /// Swipe-down (or any dismissal) without a result → cancelled.
    private func dismissed() {
        deliver(.cancelled(sessionId: config?.sessionId))
    }
}

public extension View {
    /// Presents the OKYC flow while `isPresented` is true; `onResult` is called exactly once per presentation.
    func okycVerification(
        isPresented: Binding<Bool>,
        config: OkycConfig?,
        onEvent: ((OkycEvent) -> Void)? = nil,
        onResult: @escaping (OkycResult) -> Void
    ) -> some View {
        modifier(OkycVerificationModifier(isPresented: isPresented, config: config, onEvent: onEvent, onResult: onResult))
    }
}
