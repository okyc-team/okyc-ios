# OKYC iOS SDK

Runs the OKYC hosted verification flow inside your iOS app (UIKit or SwiftUI). It implements the
cross-platform [mobile SDK contract](https://docs.okyc.stream/reference/sdk-contract): protocol v1 events, `completed` / `cancelled` /
`failed` results, the navigation allowlist and the security rules.

- iOS 15+, Swift 5.9, no third-party dependencies (UIKit, WebKit, AVFoundation, SwiftUI).
- Your **backend** creates the session (`POST /v1/sessions` with your secret key) and hands the app the
  session `url`. Never put a secret key in an app.

## Install

Full guide: [docs.okyc.stream/mobile/ios](https://docs.okyc.stream/mobile/ios).

**Swift Package Manager** — in Xcode, File → Add Package Dependencies…, enter `https://github.com/okyc-team/okyc-ios` and pick the `OKYC`
product. Or in `Package.swift`:

```swift
.package(url: "https://github.com/okyc-team/okyc-ios.git", from: "0.1.0")
```

**CocoaPods**

```ruby
pod 'OKYC', '~> 0.1'
```

**Info.plist** — the flow uses the camera (documents, selfie) and may use the microphone:

```xml
<key>NSCameraUsageDescription</key>
<string>We use the camera to capture your documents and a selfie to verify your identity.</string>
<key>NSMicrophoneUsageDescription</key>
<string>The verification flow may request microphone access for the liveness check.</string>
```

## Quick start

### async/await (UIKit)

```swift
import OKYC

guard let config = OkycConfig(sessionURLString: sessionURL, locale: "hi", theme: .system) else { return }
let result = await Okyc.start(from: self, config: config) { event in
    print(event.kind, event.payload)          // ready, step_started, step_completed, …
}
switch result {
case let .completed(sessionId, status): // status is usually "processing" — confirm via webhook / GET /v1/sessions/:id
case let .cancelled(sessionId):
case let .failed(code, message, sessionId): // see OkycErrorCode
}
```

### View controller + delegate

```swift
let vc = OkycViewController(config: config)
vc.delegate = self   // okyc(_:didReceive:) and okyc(_:didFinishWith:)
present(UINavigationController(rootViewController: vc), animated: true)
```

### SwiftUI

```swift
Button("Verify") { showKyc = true }
    .okycVerification(isPresented: $showKyc, config: config,
                      onEvent: { e in … },
                      onResult: { r in … })
```

`OkycView(config:onEvent:onResult:)` is also available to embed the flow in your own container.

## Configuration

| `OkycConfig`      | Default  | Notes |
|-------------------|----------|-------|
| `sessionURL`      | —        | The `url` returned by `POST /v1/sessions` (`…/s/<id>#t=<token>`). |
| `locale`          | `nil`    | Sent as `?locale=` (before the `#t=` fragment). |
| `theme`           | `.system`| `light` / `dark` / `system`; sent as `?theme=` and applied to the native chrome. |
| `blockScreenshots`| `true`   | Covers the flow in the app switcher and while the screen is recorded/mirrored. |
| `autoCloseDelay`  | `2` s    | Seconds between the `complete` event and dismissal (contract: 2000 ms); `nil` keeps it open. |
| `presentation`    | `.sheet` | `.sheet` (swipe down = cancel) or `.fullScreen`. |
| `allowedHosts`    | `[]`     | Extra https hosts (`*.example.com`) allowed inside the web view. |

## Results and events

- `completed(sessionId, status)` — the flow finished (auto-closes after `autoCloseDelay`). The decision is
  asynchronous: trust your webhook / server-side fetch, not the client.
- `cancelled(sessionId?)` — ✕ button, swipe-down, or the flow's own exit.
- `failed(code, message, sessionId?)` — `OkycErrorCode`: `invalid_config`, `load_failed`, `network_error`,
  `navigation_blocked`, `permission_denied`, `flow_error`, `webview_unavailable` (the web content process crashed
  twice), `presentation_failed` (iOS only: `Okyc.start(from:)` was given a view controller that is off screen or
  already presenting). `OkycErrorCode.network` is deprecated; use `networkError`.

Events (`OkycEvent.kind`): `ready`, `step_started`, `step_completed`, `complete`, `error`, `exit`
(`resize` is internal). Payload values are strings. Messages larger than 10 240 bytes are ignored.

## Security

- Messages are accepted only from the main frame of the session's origin, validated against protocol v1.
- Navigation: the flow origin and DigiLocker (`digilocker.meripehchaan.gov.in`, `*.digilocker.gov.in`,
  `api.digitallocker.gov.in`) stay inside; other https links open in Safari; everything else is blocked.
- Camera/microphone are granted only to the flow origin, and only after iOS permission.
- Non-persistent website data store, wiped when the flow finishes. The session URL (token) is never logged.
- Web inspector is enabled only in DEBUG builds.
- iOS cannot prevent a screenshot itself; `blockScreenshots` hides content in the app switcher and during
  screen recording / mirroring.
