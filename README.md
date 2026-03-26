# QuickProtect

A lightweight macOS status bar app for viewing live camera feeds from a UniFi Protect controller.

Click the camera icon in your menu bar to instantly see all your cameras in a resizable popover — no browser or UniFi Protect app needed.

## Features

- **Live RTSP streaming** via a custom RTSP/RTP client built on Network.framework (no AVFoundation RTSP dependency)
- **H.265 (HEVC) and H.264** codec support, including multi-slice encoding (e.g. G4 Doorbell Pro)
- **Automatic aspect ratio detection** — wide cameras like the G6 180 display at their native ratio
- **Resizable camera feeds** — right-click any camera to set Small / Medium / Large sizing
- **Drag-and-drop reordering** — arrange cameras however you want
- **Hide cameras** — hide feeds you don't need via right-click or Settings
- **Resizable popover** — drag to resize; size is saved per display
- **Per-display layouts** — different camera arrangements and popover sizes on your laptop vs. external monitor
- **Global keyboard shortcut** — toggle the popover from anywhere, configurable in Settings
- **Self-signed TLS support** — connects to controllers using self-signed certificates without system-wide trust changes
- **Closes on outside click** — click anywhere outside the popover to dismiss it

## Requirements

- macOS 13.0 or later
- A UniFi Protect controller with the [Integration API](https://developers.ui.com/protect-api/) enabled
- An API key generated from the controller's settings

## Setup

1. Build and run the app (see [Building](#building))
2. Click the camera icon in the menu bar
3. Right-click the icon or click the gear icon to open **Settings**
4. Enter your controller's **IP address** and **API key**
5. Click **Test Connection** to verify
6. Close settings — your cameras will appear in the popover

## Building

The project uses [XcodeGen](https://github.com/yonaskolb/xcodegen) to generate the Xcode project.

```bash
# Install XcodeGen (if needed)
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open QuickProtect.xcodeproj
```

Alternatively, compile directly with `swiftc`:

```bash
swiftc \
  -sdk $(xcrun --show-sdk-path) \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework CoreMedia -framework Network -framework Security \
  -framework Combine -framework Carbon \
  -o QuickProtect \
  QuickProtect/*.swift \
  QuickProtect/**/*.swift
```

## How It Works

QuickProtect connects to your UniFi Protect controller using the Integration API (`/proxy/protect/integration/v1/`). It authenticates with an API key and creates on-demand RTSP sessions for each camera.

Since macOS 13+ dropped AVFoundation support for RTSP URLs, QuickProtect includes a custom RTSP/RTP client that:

1. Opens a TLS connection via `NWConnection` with per-connection certificate verification bypass
2. Runs the RTSP state machine (OPTIONS → DESCRIBE → SETUP → PLAY)
3. Parses RTP interleaved framing and reassembles H.264/H.265 NAL units
4. Groups NAL units into access units using the RTP marker bit (required for multi-slice cameras)
5. Feeds AVCC-formatted data into `AVSampleBufferDisplayLayer` for hardware-accelerated decoding

## License

MIT
