# Feature parity roadmap

Tracks the macOS QuickProtect feature set against this .NET/Avalonia port.
Ordered roughly by user value and implementation dependency.

## ✅ Done (foundation)

- **Tray agent shell** — `TrayIcon` + menu (Open / Settings / Quit), no startup window.
  `App.axaml.cs` is the analog of `AppDelegate`.
- **Camera grid panel** — `MainWindow` + `MainViewModel`/`CameraTileViewModel`,
  live RTSP/RTSPS tiles via LibVLCSharp `VideoView`. Streams stop + release on hide.
- **UniFi Protect API** (`ProtectService`) — Integration API (list cameras,
  create/delete `rtsps-stream`, quality fallback ladder) and classic cookie API
  (login, PTZ continuous moves, PTZ/zoom capability enrichment).
- **TOFU certificate pinning** (`CertificateTrust`) via `HttpClientHandler`,
  with the "trust new certificate" Settings flow.
- **Settings window** — connection, default quality, PTZ credentials, launch-at-login.
- **Persistence** — `JsonFilePreferences` (≈ UserDefaults) + `ISecretStore`
  (DPAPI on Windows, 0600 file on Linux) with legacy-plaintext migration.
- **Layout data model** — profiles, hidden/order/size, pinned-camera state
  (ported and unit-tested; UI for some of it still pending).

## ⏳ Next (high value)

| Feature | macOS source | Notes for the port |
|---|---|---|
| Focus / single-camera view | `CameraGridView`, `AuroraFocusOverlay` | enlarge a tile, switch to high quality, fit/fill toggle |
| Fullscreen | `AppDelegate.enterPanelFullscreen` | borderless top-most window or `WindowState.FullScreen` |
| PTZ on-screen d-pad + keys | `AuroraFocusOverlay`, `ProtectService.ptzSetAxes` | pointer/keyboard → `PtzSetAxes`/`PtzStopAll` (service is done) |
| Snapshots | `AppSettings.snapshot*` | grab a frame from the `MediaPlayer`, clipboard or folder |
| Pinned floating windows | `PinnedCameraWindow`, `PinnedWindowManager` | always-on-top `Window` (`Topmost=true`); state model is ported |

## ⏳ Later

| Feature | macOS source | Notes |
|---|---|---|
| Onboarding wizard | `OnboardingView` | first-run flow; today first-run just opens Settings |
| Global hotkey | `HotkeyManager` (Carbon) | Win: `RegisterHotKey`; Linux: X11/`evdev` or DE shortcut |
| Auto-update checker | `UpdateChecker` | GitHub releases poll + notify (no auto-install, per project policy) |
| Secondary-lens PiP | `ProtectStreamView` | second `MediaPlayer` overlay for doorbell package cam |
| Localization (7 languages) | String Catalog | `.resx` + `IStringLocalizer`; strings are English-only now |
| libsecret secret store (Linux) | — | replace the 0600 file with GNOME Keyring via SecretService D-Bus |
| Layout-profile UI | `SettingsView` profile menu | model is ported; needs the menu + resize persistence |

## Distribution (future)

- **Windows**: MSIX or a signed installer; the macOS notify-only updater policy carries over.
- **Linux**: AppImage or Flatpak; declare the `vlc`/`libvlc` runtime dependency.
