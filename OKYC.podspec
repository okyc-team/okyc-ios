Pod::Spec.new do |s|
  s.name             = 'OKYC'
  s.version          = '0.1.1'
  s.summary          = 'OKYC identity verification for iOS: the hosted KYC/KYB flow in a secure native wrapper.'
  s.description      = <<-DESC
    Presents the OKYC hosted verification flow in a hardened WKWebView: camera permission handling,
    a navigation allowlist, protocol-v1 events and a typed result. Guide: https://docs.okyc.stream/mobile/ios
  DESC
  s.homepage         = 'https://docs.okyc.stream/mobile/ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'OKYC' => 'sdk@okyc.stream' }
  s.source           = { :git => 'https://github.com/okyc-team/okyc-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9']
  s.source_files     = 'Sources/OKYC/**/*.swift'
  s.frameworks       = 'UIKit', 'WebKit', 'AVFoundation', 'SwiftUI'
end
