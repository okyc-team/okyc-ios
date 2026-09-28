# Changelog — OKYC iOS SDK

All notable changes to this SDK. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/). Guides: https://docs.okyc.stream

## [Unreleased]

## [0.1.1] - 2026-09-28

### Changed
- Neutral chrome that matches the redesigned verification flow: the view and web view background use the flow's
  surface colour (`#FFFFFF` light, `#12131B` dark) so nothing flashes before the page paints; the progress bar,
  navigation bar title and ✕ button use the flow's text colour, and the bar has a hairline in the border colour.
  The host app's tint colour and global navigation bar styling no longer leak into the SDK screen. No API change.

## [0.1.0] - 2026-09-27

### Added
- First release: `Okyc.start(from:config:onEvent:)` (async), `OkycViewController` + delegate, SwiftUI
  `OkycView` and `.okycVerification(isPresented:config:onEvent:onResult:)`.
- `OkycConfig` (`sessionURL`, `locale`, `theme`, `allowedHosts`, `blockScreenshots`, `autoCloseDelay`,
  `presentation`).
- `OkycResult` (`completed`, `cancelled`, `failed(code:message:sessionId:)`) and `OkycErrorCode`, covering every
  failure code in the contract (`OkycErrorCode.network` is a deprecated alias of `.networkError`).
- `webview_unavailable` when the web content process crashes a second time (the first crash reloads the flow);
  `presentation_failed` when the presenter is not in a window or is already presenting.
- Session URLs must use https; plain http is accepted only for `localhost`, `127.0.0.1` and `::1`.
- Protocol v1 events (`OkycEvent.Kind`) with bridge messages up to 10 240 bytes, navigation allowlist,
  camera/microphone gating, privacy cover, non-persistent website data store.

[Unreleased]: https://github.com/okyc-team/okyc-ios/compare/0.1.0...HEAD
[0.1.0]: https://github.com/okyc-team/okyc-ios/releases/tag/0.1.0
