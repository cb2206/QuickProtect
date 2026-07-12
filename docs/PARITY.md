# Feature parity roadmap

Tracks the macOS QuickProtect feature set (`macos/`) against the .NET/Avalonia
port (`dotnet/`). Ordered roughly by user value and implementation dependency.

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

- **Secret storage** — DPAPI (Windows), **libsecret via `secret-tool`** (Linux,
  GNOME Keyring/KWallet) with a 0600-file fallback.
- **Pinned-window aspect lock** — resize is constrained to the camera aspect
  (`PinnedWindowGeometry.Constrain`).
- **Panel header parity** — search/filter cameras by name, in-panel layout-profile
  switcher, and a live online-stream count pill (mirrors the macOS popover header).
- **Focus-controls toggle** — Settings option to hide the on-screen PTZ pad and
  shortcut hints (keyboard still works).
- **Snapshot destination** — clipboard/folder picker + native folder chooser
  (StorageProvider), persisted.
- **Accent color** — 7 presets applied live to the Fluent theme.
- **Graceful video degradation** — if libVLC can't initialize, the app runs
  without video (camera list, settings, PTZ, pins all work) and tiles show a
  "Video unavailable" notice instead of crashing.

## ⏳ Remaining (lower priority)

| Feature | macOS source | Notes |
|---|---|---|
| Light / auto theme | `AppSettings.Appearance` | dark-only today; light mode needs the hardcoded view palette converted to theme-variant resources (accent color is done) |
| True-fullscreen HUD | `AuroraFullscreenHUD` | auto-hiding overlay; today fullscreen is a plain toggle |
| Snapshot to clipboard | `AppSettings.snapshotDestination` | image-clipboard is platform-specific in Avalonia; folder output works today |
| Stream-protocol toggle | `usePlainRtsp` | RTSPS works; plain-RTSP toggle UI not wired |
| Drag-to-reorder/resize grid | `CameraGridView` | done via Settings (up/down + size dropdown) instead of in-grid drag |
| Aurora visual polish | `Aurora*` views | gradient/blur styling not reproduced 1:1 |
| Full string coverage | String Catalog | infra + 7 languages shipped; remaining literals wrapped incrementally |

## Distribution (future)

- **Windows**: MSIX or a signed installer; the macOS notify-only updater policy carries over.
- **Linux**: AppImage or Flatpak; declare the `vlc`/`libvlc` runtime dependency.
