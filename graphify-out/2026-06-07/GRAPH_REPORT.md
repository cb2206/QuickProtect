# Graph Report - QuickProtect  (2026-06-07)

## Corpus Check
- 35 files · ~117,048 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 864 nodes · 1524 edges · 71 communities (46 shown, 25 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 44 edges (avg confidence: 0.82)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `674fbc8b`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_App Shell & Settings|App Shell & Settings]]
- [[_COMMUNITY_Hotkey Capture Field|Hotkey Capture Field]]
- [[_COMMUNITY_Settings & Appearance Store|Settings & Appearance Store]]
- [[_COMMUNITY_Protect Service API Layer|Protect Service API Layer]]
- [[_COMMUNITY_RTSP Client Networking|RTSP Client Networking]]
- [[_COMMUNITY_Global Hotkey & Launch|Global Hotkey & Launch]]
- [[_COMMUNITY_RTSP Stream Manager|RTSP Stream Manager]]
- [[_COMMUNITY_Menu Bar Panel & Window|Menu Bar Panel & Window]]
- [[_COMMUNITY_Custom Test Harness|Custom Test Harness]]
- [[_COMMUNITY_H.264H.265 NAL Types|H.264/H.265 NAL Types]]
- [[_COMMUNITY_Color & Appearance Tests|Color & Appearance Tests]]
- [[_COMMUNITY_RTPNAL Parser Logic|RTP/NAL Parser Logic]]
- [[_COMMUNITY_Video Display Layer|Video Display Layer]]
- [[_COMMUNITY_RTP Parser Tests|RTP Parser Tests]]
- [[_COMMUNITY_Aurora Focus Overlay HUD|Aurora Focus Overlay HUD]]
- [[_COMMUNITY_Aurora Design Tokens|Aurora Design Tokens]]
- [[_COMMUNITY_Grid Layout Tests|Grid Layout Tests]]
- [[_COMMUNITY_Aurora State Cards|Aurora State Cards]]
- [[_COMMUNITY_Aurora Settings Chrome|Aurora Settings Chrome]]
- [[_COMMUNITY_RTSPSDP Protocol Tests|RTSP/SDP Protocol Tests]]
- [[_COMMUNITY_Camera Channel Encoding|Camera Channel Encoding]]
- [[_COMMUNITY_Camera Model (Codable)|Camera Model (Codable)]]
- [[_COMMUNITY_Onboarding Flow|Onboarding Flow]]
- [[_COMMUNITY_Version Comparison Tests|Version Comparison Tests]]
- [[_COMMUNITY_RTSP Streaming Pipeline|RTSP Streaming Pipeline]]
- [[_COMMUNITY_Camera Coding Keys|Camera Coding Keys]]
- [[_COMMUNITY_Settings View|Settings View]]
- [[_COMMUNITY_Privacy & Build Config|Privacy & Build Config]]
- [[_COMMUNITY_Protect API Calls & PTZ|Protect API Calls & PTZ]]
- [[_COMMUNITY_Camera Model Tests|Camera Model Tests]]
- [[_COMMUNITY_Stream Blur Script|Stream Blur Script]]
- [[_COMMUNITY_Popover Content View|Popover Content View]]
- [[_COMMUNITY_App Store Screenshot 1|App Store Screenshot 1]]
- [[_COMMUNITY_App Store Screenshot 2|App Store Screenshot 2]]
- [[_COMMUNITY_H.264 NAL Tests|H.264 NAL Tests]]
- [[_COMMUNITY_Interleaved Frame Tests|Interleaved Frame Tests]]
- [[_COMMUNITY_Visual Effect Background|Visual Effect Background]]
- [[_COMMUNITY_PTZ Direction Enum|PTZ Direction Enum]]
- [[_COMMUNITY_Window Cleanup Script|Window Cleanup Script]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 53|Community 53]]
- [[_COMMUNITY_Community 54|Community 54]]
- [[_COMMUNITY_Community 55|Community 55]]
- [[_COMMUNITY_Community 56|Community 56]]
- [[_COMMUNITY_Community 57|Community 57]]
- [[_COMMUNITY_Community 58|Community 58]]
- [[_COMMUNITY_Community 59|Community 59]]
- [[_COMMUNITY_Community 60|Community 60]]
- [[_COMMUNITY_Community 61|Community 61]]
- [[_COMMUNITY_Community 62|Community 62]]
- [[_COMMUNITY_Community 63|Community 63]]
- [[_COMMUNITY_Community 64|Community 64]]
- [[_COMMUNITY_Community 65|Community 65]]
- [[_COMMUNITY_Community 66|Community 66]]
- [[_COMMUNITY_Community 67|Community 67]]
- [[_COMMUNITY_Community 68|Community 68]]
- [[_COMMUNITY_Community 69|Community 69]]
- [[_COMMUNITY_Community 70|Community 70]]

## God Nodes (most connected - your core abstractions)
1. `CameraCell` - 53 edges
2. `RTSPClient` - 41 edges
3. `AppSettings` - 34 edges
4. `AppDelegate` - 31 edges
5. `ProtectService` - 31 edges
6. `RTPParser` - 29 edges
7. `SettingsView` - 29 edges
8. `Camera` - 24 edges
9. `CameraGridView` - 24 edges
10. `String` - 22 edges

## Surprising Connections (you probably didn't know these)
- `AppearanceTests` --references--> `Appearance`  [INFERRED]
  QuickProtectTests/AppearanceTests.swift → QuickProtect/Models/AppSettings.swift
- `drawIcon()` --calls--> `CGRect`  [INFERRED]
  scripts/generate_appicon.swift → QuickProtect/Views/ProtectStreamView.swift
- `testAppearanceRawValues` --references--> `Appearance`  [EXTRACTED]
  QuickProtectTests/AppearanceTests.swift → QuickProtect/Models/AppSettings.swift
- `testPreferredColorScheme` --references--> `Appearance`  [EXTRACTED]
  QuickProtectTests/AppearanceTests.swift → QuickProtect/Models/AppSettings.swift
- `CameraModelTests` --references--> `Camera`  [EXTRACTED]
  QuickProtectTests/CameraModelTests.swift → QuickProtect/Models/Camera.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **RTSP connect to RTP decode to display flow** — services_rtspclient_connect, services_rtspclient_processrtspresponses, services_rtspclient_processrtp, services_rtspclient_handlertp, services_rtspclient_emitnal, services_rtspclient_enqueueaccessunit [EXTRACTED 1.00]
- **Classic-API PTZ control flow** — services_protectservice_ptzstartmove, services_protectservice_sendptzrelative, services_protectservice_classiclogin, services_protectservice_sendmove [EXTRACTED 1.00]
- **App launch and panel setup flow** — quickprotect_main_entrypoint, quickprotect_appdelegate_appdelegate, quickprotect_appdelegate_applicationdidfinishlaunching, quickprotect_appdelegate_setupglobalhotkey, services_protectservice_fetchcameras [INFERRED 0.85]
- **Aurora design-system primitives** — views_auroradesign_auroratokens, views_auroradesign_aurorabrandmark, views_auroradesign_visualeffectbackground, views_auroradesign_aurorahairline, views_aurorasettingschrome_aurorasegmented [INFERRED 0.85]
- **Focus-mode overlay chrome composed by CameraCell** — views_aurorafocusoverlay_aurorafocustopbar, views_aurorafocusoverlay_auroraptzdpad, views_aurorafocusoverlay_aurorafullscreenhud, views_aurorafocusoverlay_aurorafocushints, views_cameragridview_cameracell [INFERRED 0.85]
- **Settings chrome shared across SettingsView and OnboardingView** — views_aurorasettingschrome_auroraprimarybutton, views_aurorasettingschrome_aurorasecondarybutton, views_settingsview_settingsview, views_onboardingview_onboardingview [INFERRED 0.75]
- **RTP/RTSP streaming parser test suite** — quickprotecttests_rtpparsertests_interleavedframetests, quickprotecttests_rtpparsertests_rtpheadertests, quickprotecttests_rtpparsertests_h264naltests, quickprotecttests_rtpparsertests_h265naltests, quickprotecttests_rtpparsertests_nalclassificationtests, quickprotecttests_rtpparsertests_avcctests, quickprotecttests_rtspprotocoltests_rtspresponsetests, quickprotecttests_rtspprotocoltests_sdpparsingtests, services_rtpparser_rtpparser [INFERRED 0.85]
- **Standalone XCTest-less test harness suites** — quickprotecttests_testrunner_runalltests, quickprotecttests_testrunner_testmain, services_rtpparser_rtpparser, models_camera_camera [INFERRED 0.75]
- **App Store screenshot generation pipeline** — scripts_clean_window_main, scripts_autocrop_main, scripts_blur_streams_main, scripts_compose_screenshot_main [INFERRED 0.85]

## Communities (71 total, 25 thin omitted)

### Community 0 - "App Shell & Settings"
Cohesion: 0.09
Nodes (13): Animation, AppDelegate, AuroraPtzDpad, DispatchWorkItem, Mode, Never, Any, AppSettings (+5 more)

### Community 1 - "Hotkey Capture Field"
Cohesion: 0.20
Nodes (8): NSViewRepresentable, Context, Coordinator, NSTextField, Coordinator, AuroraSearchField, EditableTextField, PastableTextField

### Community 2 - "Settings & Appearance Store"
Cohesion: 0.08
Nodes (26): CaseIterable, Int, Appearance, auto, dark, light, AppSettings, CameraSize (+18 more)

### Community 3 - "Protect Service API Layer"
Cohesion: 0.10
Nodes (20): LocalizedError, Any, Bool, Camera, Double, Error, String, Timer (+12 more)

### Community 4 - "RTSP Client Networking"
Cohesion: 0.13
Nodes (11): CMVideoFormatDescription, NWConnection, CGSize, Int, Int64, String, UInt8, URL (+3 more)

### Community 5 - "Global Hotkey & Launch"
Cohesion: 0.06
Nodes (25): EventHandlerRef, EventHotKeyRef, globalHotkey, applicationDidFinishLaunching, promptAutoStartIfNeeded, setupGlobalHotkey, showOnboarding, NSEvent (+17 more)

### Community 6 - "RTSP Stream Manager"
Cohesion: 0.08
Nodes (23): Int32, ObservableObject, RTSPClient, String, Bool, Error, Int64, String (+15 more)

### Community 7 - "Menu Bar Panel & Window"
Cohesion: 0.11
Nodes (16): NSApplicationDelegate, NSImage, NSPanel, NSRect, NSStatusBarButton, NSStatusItem, NSWindow, NSWindowDelegate (+8 more)

### Community 8 - "Custom Test Harness"
Cohesion: 0.25
Nodes (27): CustomStringConvertible, Error, AVCCTests(), CameraModelRunnerTests(), expect(), expectEqual(), expectNil(), expectNotNil() (+19 more)

### Community 9 - "H.264/H.265 NAL Types"
Cohesion: 0.11
Nodes (18): Equatable, H264NALType, aud, data, idr, pps, sps, H265NALType (+10 more)

### Community 10 - "Color & Appearance Tests"
Cohesion: 0.13
Nodes (13): CGContext, Data, NSColor, AppearanceTests, CGFloat, String, Aurora app icon design, drawIcon() (+5 more)

### Community 11 - "RTP/NAL Parser Logic"
Cohesion: 0.17
Nodes (10): H264NALType, H265NALType, Bool, Int, String, UInt8, InterleavedFrame, RTPParser (+2 more)

### Community 12 - "Video Display Layer"
Cohesion: 0.14
Nodes (14): AVLayerVideoGravity, AVSampleBufferDisplayLayer, CGRect, DisplayLayerHostView, Bool, CGFloat, Context, Int (+6 more)

### Community 13 - "RTP Parser Tests"
Cohesion: 0.12
Nodes (5): AVCCTests, H265NALTests, NALClassificationTests, RTPHeaderTests, XCTestCase

### Community 14 - "Aurora Focus Overlay HUD"
Cohesion: 0.24
Nodes (18): DateFormatter, Direction, Bool, Date, String, Void, View, AuroraRecDot (+10 more)

### Community 15 - "Aurora Design Tokens"
Cohesion: 0.18
Nodes (12): Axis, ColorScheme, CGFloat, Color, String, AppSettings.Appearance, AuroraAccent, AuroraBrandMark (+4 more)

### Community 16 - "Grid Layout Tests"
Cohesion: 0.24
Nodes (3): GridLayoutTests, CGFloat, Int

### Community 17 - "Aurora State Cards"
Cohesion: 0.15
Nodes (13): ButtonStyle, Configuration, AuroraTokens, Bool, Color, String, Void, AuroraStateCard (+5 more)

### Community 18 - "Aurora Settings Chrome"
Cohesion: 0.33
Nodes (11): AuroraTokens, Bool, Content, String, Void, AuroraPrimaryButton, AuroraSecondaryButton, AuroraSettingsRow (+3 more)

### Community 20 - "Camera Channel Encoding"
Cohesion: 0.15
Nodes (12): Channel, Encoder, Camera, testDecodeChannels, testDecodeIntegrationAPI, testDecodeMissingState, testDecodeNonPtzCamera, testDecodeOpticalZoomSetsPtz (+4 more)

### Community 21 - "Camera Model (Codable)"
Cohesion: 0.18
Nodes (9): Codable, Decodable, Decoder, Camera.Channel, Channel, FeatureFlags, Bool, Int (+1 more)

### Community 22 - "Onboarding Flow"
Cohesion: 0.15
Nodes (12): ProtectService, AuroraTokens, Bool, Content, Int, ProtectService, String, TestResult (+4 more)

### Community 24 - "RTSP Streaming Pipeline"
Cohesion: 0.18
Nodes (12): RTPParser.parseResponse, RTPParser.parseVideoTrack (SDP), RTSPClient.connect, emitNAL, enqueueAccessUnit, handleH264RTP, handleH265RTP, handleRTP (+4 more)

### Community 25 - "Camera Coding Keys"
Cohesion: 0.18
Nodes (11): CodingKey, CodingKeys, canOpticalZoom, channels, featureFlags, id, isPtz, isRtspEnabled (+3 more)

### Community 26 - "Settings View"
Cohesion: 0.20
Nodes (12): HotkeyManager, AppSettings, AuroraTokens, Camera, ProtectService, TestResult, Void, UpdateChecker (+4 more)

### Community 27 - "Privacy & Build Config"
Cohesion: 0.18
Nodes (11): Credentials stored in macOS Keychain, No data collection / no servers, App Sandbox + network client entitlements, LSUIElement menu-bar agent config, QuickProtect app target, XcodeGen project generation, H.265/H.264 multi-slice codec support, UniFi Protect Integration API (+3 more)

### Community 28 - "Protect API Calls & PTZ"
Cohesion: 0.20
Nodes (11): savedPanelSize, showPanel, classicLogin, createRtspStreamURL, enrichPtzFlags, fetchCameras, ProtectService.makeURL, ptzStartMove (+3 more)

### Community 30 - "Stream Blur Script"
Cohesion: 0.35
Nodes (10): alpha(), Box, boxMean(), inBox(), lum(), markCount(), nearLabel(), Bool (+2 more)

### Community 31 - "Popover Content View"
Cohesion: 0.15
Nodes (14): AppSettings, NSObject, NSTextFieldDelegate, AuroraTokens, Binding, Int, Notification, ProtectService (+6 more)

### Community 32 - "App Store Screenshot 1"
Cohesion: 0.32
Nodes (8): QuickProtect App Store Screenshot 1, Multi-Camera Live Grid View, Camera Name and Timestamp Overlays, Dark Theme UI Design, Featured/Primary Camera View, QuickProtect Main Window, Window Toolbar with Search, Home Video Surveillance Purpose

### Community 33 - "App Store Screenshot 2"
Cohesion: 0.43
Nodes (8): QuickProtect App Store Screenshot 2 - Live Camera View, Garage Outside Camera Stream, Full-Window Live Camera Feed, Native macOS Window Chrome with Dark Theme, Bottom Playback Toolbar, PTZ Joystick Control, Timestamp and Camera Label Overlay, UniFi Protect Camera Client

### Community 36 - "Visual Effect Background"
Cohesion: 0.53
Nodes (4): NSVisualEffectView, Bool, Context, VisualEffectBackground

### Community 37 - "PTZ Direction Enum"
Cohesion: 0.40
Nodes (5): Direction, down, left, right, up

### Community 38 - "Window Cleanup Script"
Cohesion: 0.50
Nodes (3): isBorder(), Bool, Int

### Community 55 - "Community 55"
Cohesion: 0.17
Nodes (13): AuroraTokens, Binding, Camera, CGFloat, Date, Int, ProtectService, String (+5 more)

### Community 56 - "Community 56"
Cohesion: 0.11
Nodes (17): Building from Source, Features, How It Works, Install, Installing an Unsigned App, Keyboard Shortcuts, License, Option 1: Tailscale (Recommended) (+9 more)

### Community 57 - "Community 57"
Cohesion: 0.20
Nodes (7): Binding, Color, Notification, String, AccentSwatch, Coordinator, TestResult

### Community 58 - "Community 58"
Cohesion: 0.31
Nodes (6): HotkeyCapture, NSSecureTextField, Context, EditableSecureTextField, HotkeyRecorderView, PastableSecureField

### Community 59 - "Community 59"
Cohesion: 0.36
Nodes (7): NSControl, NSView, Bool, NSEvent, UInt16, handleEditingKeyEquivalent(), HotkeyCapture

### Community 60 - "Community 60"
Cohesion: 0.20
Nodes (9): Changes to this policy, Children's privacy, Contact, Data collection, Information stored on your device, Network connections, Privacy Policy for QuickProtect, Summary (+1 more)

### Community 61 - "Community 61"
Cohesion: 0.22
Nodes (9): Identifiable, SettingsTab, about, cameras, connection, general, ptz, shortcuts (+1 more)

### Community 62 - "Community 62"
Cohesion: 0.36
Nodes (4): DropDelegate, DropInfo, DropProposal, CameraDropDelegate

### Community 64 - "Community 64"
Cohesion: 0.33
Nodes (5): Mode, connecting, failed, playing, Notification.Name

## Knowledge Gaps
- **226 isolated node(s):** `Notification.Name`, `NSStatusItem`, `Any`, `CGFloat`, `NSImage` (+221 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **25 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Camera` connect `Camera Channel Encoding` to `Settings & Appearance Store`, `Custom Test Harness`, `Community 61`, `Camera Model (Codable)`, `Protect API Calls & PTZ`, `Camera Model Tests`?**
  _High betweenness centrality (0.245) - this node is a cross-community bridge._
- **Why does `AppSettings` connect `Settings & Appearance Store` to `Protect Service API Layer`, `Global Hotkey & Launch`, `RTSP Stream Manager`, `Camera Channel Encoding`, `Protect API Calls & PTZ`?**
  _High betweenness centrality (0.188) - this node is a cross-community bridge._
- **Why does `SettingsView` connect `Settings View` to `Hotkey Capture Field`, `RTSP Stream Manager`, `Menu Bar Panel & Window`, `Aurora Focus Overlay HUD`, `Aurora Design Tokens`, `Aurora Settings Chrome`, `Onboarding Flow`, `Community 57`, `Community 58`, `Community 61`, `Popover Content View`?**
  _High betweenness centrality (0.180) - this node is a cross-community bridge._
- **What connects `Notification.Name`, `NSStatusItem`, `Any` to the rest of the system?**
  _231 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `App Shell & Settings` be split into smaller, more focused modules?**
  _Cohesion score 0.08831908831908832 - nodes in this community are weakly interconnected._
- **Should `Settings & Appearance Store` be split into smaller, more focused modules?**
  _Cohesion score 0.07547169811320754 - nodes in this community are weakly interconnected._
- **Should `Protect Service API Layer` be split into smaller, more focused modules?**
  _Cohesion score 0.0975609756097561 - nodes in this community are weakly interconnected._