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
- **Focus (single-camera) view** — click a tile → dedicated high-quality stream,
  back-to-grid, basic fullscreen toggle (`WindowState.FullScreen`).
- **PTZ control** — on-screen d-pad + zoom pill (pointer hold) and keyboard
  (arrows pan/tilt, I/O zoom). Direction→axis mapping is in Core (`PtzMapping`,
  unit-tested) and matches the macOS sign conventions. Controls are docked
  outside the video region because the native `VideoView` can't be overlaid.
- **Pinned always-on-top windows** — pin from the focus bar; each pinned window
  is borderless, top-most, draggable, independently streamed (pinned allocation),
  with frame persistence and restore-on-launch. Sizing math is in Core
  (`PinnedWindowGeometry`, unit-tested). `PinnedWindowManager` mirrors the macOS
  manager. (Aspect-lock-on-resize is still a follow-up — resize is currently free.)
- **Snapshots (S key + button)** — capture a still from the focused stream via
  libVLC `TakeSnapshot` into the configured folder (or OS Pictures), with a
  toast. Filename logic is in Core (`SnapshotNaming`, unit-tested). Clipboard
  image output is still a follow-up.
- **Focus finishers** — fit/fill toggle (libVLC crop) and audio mute (M).
- **Cameras & Layout settings** — profile switcher (create/rename/delete) and
  per-camera show/hide, tile size, and reorder; grid honors tile size.
- **First-run onboarding** — 3-step wizard (Connect → PTZ → All set).
- **Global hotkey** — native `RegisterHotKey` on Windows (record/clear in
  Settings); Linux is a documented no-op.
- **Notify-only update checker** — GitHub releases poll + Settings banner
  (`VersionCompare` unit-tested).
- **Secondary-lens PiP** — package-camera side panel in focus.
- **Localization** — all 7 languages (en/de/fr/es/nl/it/pt-BR) imported from the
  macOS String Catalog into embedded `.resx`; `Loc` helper + `{loc:Loc}` markup
  extension; OS culture detection + Settings language picker. Applied to the
  high-visibility strings; remaining literals fall back to English safely and
  are wrapped incrementally.

## ⏳ Next (high value)

| Feature | macOS source | Notes for the port |
|---|---|---|
| True-fullscreen HUD | `AuroraFullscreenHUD` | auto-hiding overlay; today fullscreen is a plain toggle |
| Snapshot to clipboard | `AppSettings.snapshotDestination` | image-clipboard is platform-specific in Avalonia; file output works today |
| Fit / fill toggle | `cameraFillMode` | `MediaPlayer` aspect / crop in focus |
| Audio mute (M key) | `AudioRenderer` | `MediaPlayer.Mute`; needs audio-track detection |
| Pinned-window aspect lock | `PinnedWindowGeometry.constrain` | constrain resize to the camera aspect (helper ported; not wired to resize yet) |

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
