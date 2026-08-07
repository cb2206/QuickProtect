# Feature parity roadmap

Tracks the macOS QuickProtect feature set (`macos/`) against the .NET/Avalonia
port (`dotnet/`).

## ✅ Done

- **Tray agent shell** — `TrayIcon` + menu (Open / Settings / Quit), no startup window.
  `App.axaml.cs` is the analog of `AppDelegate`.
- **Camera panel as tray popover** — chromeless window anchored to the tray corner,
  click-outside dismiss (our own popups/windows don't count as outside; a tray click
  right after an auto-hide toggles closed), Esc dismisses, header doubles as the
  drag handle, per-profile size persistence.
- **Live video via the custom FFmpeg engine** — the macOS-style pipeline:
  libavformat/libavcodec demux + decode per stream (`Video/VideoStreamClient`),
  frames composited by `Video/VideoSurface` as ordinary Avalonia content (video
  is clickable, gesture-capable, overlayable — no native child windows).
  `Video/VideoStreamCoordinator` shares one client per camera lens across
  grid/focus/pinned views: focus adopts the running grid stream instantly and
  upgrades quality in place (last frame kept, no grey flash); panel open
  connects in a 90 ms cascade. Native binaries per RID incl. **win-arm64**
  (`scripts/get-ffmpeg.ps1`); RTSPS rides `RtspTlsTunnel` (Core) — a 127.0.0.1
  listener piping bytes over TLS with the same TOFU pinning as the API (FFmpeg
  gets plain rtsp; keep the tunnel, it carries the certificate policy).
- **UniFi Protect API** (`ProtectService`) — Integration API (list cameras,
  create/delete `rtsps-stream`, quality fallback ladder) and classic cookie API
  (login, PTZ continuous moves, PTZ/zoom capability enrichment).
- **TOFU certificate pinning** (`CertificateTrust`) end-to-end: HTTPS via
  `HttpClientHandler`, video via the tunnel's `SslStream` callback, with the
  "trust new certificate" Settings flow.
- **Settings window** — sidebar-sectioned like the macOS `SettingsView`
  (General / Connection / PTZ / Cameras / Shortcuts / Updates) with the Aurora
  card look (caption + label/control rows + hairlines) and a live
  Connected/Disconnected header badge (classic-API-aware on the PTZ section).
  General: launch-at-login, language picker, appearance (auto/light/dark),
  accent color (7 presets, applied live), default quality, focus-controls
  toggle, snapshot destination (clipboard/folder + picker). Connection: IP +
  API key (reveal toggle), test with inline result, trust-new-certificate flow.
  PTZ: classic credentials (reveal toggle) + its own login test. Shortcuts:
  hotkey recorder + read-only in-app shortcut reference. Updates: version,
  check button, release banner, About card (license/GitHub). Everything
  auto-applies — no Save button (credentials commit on focus loss).
- **Persistence** — `JsonFilePreferences` (≈ UserDefaults) + `ISecretStore`
  (DPAPI on Windows; libsecret via `secret-tool` on Linux, 0600-file fallback).
- **Layout profiles** — create/rename/delete, per-camera show/hide, size,
  reorder (Settings list **and** in-grid drag-to-reorder with persistence).
- **Focus view** — instant entry (adopts the grid stream, quality upgrades in
  place), fit/fill, snapshot (S), fullscreen (F), click video to return,
  double-click opens in Protect, overlay chrome/PTZ pad/hints/PiP like
  AuroraFocusOverlay.
- **Digital zoom + pan** — 1–8× (`DigitalZoom` in Core, unit-tested):
  Ctrl+scroll or `+`/`−` zoom, `0` resets, scroll or drag pans (arrows on
  non-PTZ cameras, Shift+arrows on PTZ), zoom badge in the top bar.
- **Grid tile context menu** — View fullscreen, Open in Protect, Pin/Unpin,
  Size (S/M/L + reset), Stream quality (default + tiers), Add Camera (hidden
  cameras), Hide this camera.
- **Header toolbar** — status pill, profile switcher + Save Current View as
  New Profile (name prompt), search, refresh, settings gear, quit.
- **Fullscreen HUD** — chrome auto-hides after 3s idle in fullscreen, wakes on
  input (pointer wake-up via a global cursor poll on Windows; keys wake it
  everywhere).
- **PTZ control** — d-pad + zoom pill (pointer hold), keyboard (arrows, I/O),
  continuous-velocity moves with the macOS quick-tap **minimum burst** (0.25s,
  `PtzBurstTimer` in Core, unit-tested).
- **Pinned always-on-top windows** — borderless, top-most, draggable, aspect-locked
  resize, frame persistence, restore-on-launch, independent pinned allocation.
- **Snapshots** — clipboard (Win32 CF_DIB+PNG / wl-copy / xclip / osascript) or
  folder, honoring the destination setting; captures the latest decoded frame
  straight from the video engine.
- **Secondary-lens PiP** — package-camera side panel in focus with a **swap**
  button that exchanges playback between the lenses in place (no re-allocation).
- **Audio playback** — the engine decodes the stream's audio track (Opus/AAC)
  and renders it through a platform sink: WASAPI shared mode via NAudio on
  Windows, ALSA via libasound P/Invoke on Linux (best-effort, untested until
  the Linux phase). macOS parity: only the focused stream and pinned windows
  are audio-active (the grid never plays), output is muted by default behind
  the global speaker preference, pinned windows start muted with a
  window-local toggle, and the Mute (M) control appears only when the stream
  actually has audio. Mute flushes queued PCM so it takes effect immediately.
- **Onboarding** — 3-step wizard (Connect → PTZ → All set).
- **Global hotkey** — native `RegisterHotKey` on Windows; Linux is a documented no-op.
- **Update checker** — notify-only GitHub releases poll + Settings banner.
  Both platforms only announce a release that carries an asset for the running
  OS (`.dmg` / `-win` / `-linux` in the asset name — the naming convention is a
  de facto API; see `UpdateAssets.swift` and `UpdateChecker.HasAsset`). The
  .NET side detects externally-updated installs (`AppDistribution`: MSIX
  package identity, `FLATPAK_ID`, `SNAP`) and keeps the updater idle there,
  mirroring the macOS `_MASReceipt` guard.
- **Theming** — light/auto/dark via Avalonia theme variants with the full Aurora
  token palette (23 semantic Qp* tokens per variant); video surfaces (grid tiles,
  focus, pinned windows) stay pinned dark exactly like macOS; accent-derived
  brushes update live.
- **Localization** — 7 languages (en/de/fr/es/nl/it/pt-BR) from the macOS String
  Catalog; `Loc` helper + `{loc:Loc}` markup extension; OS culture detection +
  Settings language picker.
- **Graceful degradation** — if the FFmpeg natives can't load (and no matching
  system FFmpeg exists), the app runs without video and tiles show a notice
  instead of crashing.
- **Diagnostics** — `crash.log` (fatal), `video.log` (FFmpeg warnings/errors,
  truncated per session); `--open-panel` / `--no-dismiss` flags for testing.
- **Windows installer** — Inno Setup (`installer/QuickProtect.iss`) via
  `scripts/package-windows.ps1`, 7 wizard languages, closes the running tray app
  on upgrade.
- **Stream keep-alive on panel close** — hiding the panel defers stream
  teardown by a configurable grace (Settings → Connection: Off/5/10/30/60 s,
  default 10 s) so a quick reopen re-attaches to the still-connected streams
  instantly; covers the secondary (package-lens) PiP stream too.
  `App.PanelClosed` / `PanelOpened` / `TeardownStreamsNow` mirror the macOS
  `scheduleStreamTeardown` / `teardownStreamsNow`; the grace is flushed
  immediately on quit and on IP/API-key changes.
- **Decode pause during the grace** — kept-alive streams stop feeding packets
  to the FFmpeg decoder while hidden and buffer the compressed GOP since the
  latest keyframe (`PausedGopBuffer` in Core, unit-tested, 8 MB/camera cap);
  reopen burst-decodes it to land on the live picture, or holds the last frame
  until the stream's next keyframe when nothing replayable was buffered.
  Configurable via the "Pause decoding while closed" switch, shown only when
  the grace is > 0 (default on).
- **Controller rate-limit hardening** — the pure rules live in
  `ControllerRequestPolicy` (Core, unit-tested like macOS): camera-list fetch
  coalescing + 3 s throttle (user-initiated refreshes bypass it),
  PTZ-enrichment throttle (5 min, credential changes re-enrich), quality-ladder
  abort on 429/5xx, one silent camera-list retry after a 429, and a stream
  POST that completes after the panel closed releases its allocation instead
  of leaking it server-side.

## Pending (macOS ahead)

Nothing at the moment — the port is in sync with the macOS feature set.

## Intentional differences from macOS

| Topic | macOS | This port | Why |
|---|---|---|---|
| Profile rename/delete in header menu | header profile menu | Settings → Cameras | header has switcher + save-as-new; full management lives in Settings |
| About tab | separate sidebar tab | About card on the Updates section | six sections fit the window; split it out if it grows |
| Stream-protocol toggle | `usePlainRtsp` setting exists in the UI | omitted | The macOS setting is vestigial — nothing consumes it (the stream token is only valid on the rtsps endpoint, `ProtectService.swift:455`) |
| Grid-tile PiP | optional per-camera PiP on grid tiles | focus-only PiP | each PiP is an extra server stream; cost outweighs the value at grid size |
| Panel anchor | popover under the menu-bar item (top) | popover at the tray corner (bottom-right) | Windows/Linux tray convention |
| Per-display panel size | per-profile **and** per-display | per-profile | multi-monitor display identity is less stable off macOS; revisit if needed |

## Platform notes (for the Linux phase)

- Video needs the FFmpeg 7.1 natives (`scripts/get-ffmpeg.sh`, fetched into
  gitignored `native/`) or a matching system FFmpeg (7.x / `libavcodec.so.61`).
- The rtsps TLS tunnel works unchanged on Linux (pure .NET sockets).
- Tray icons need StatusNotifierItem/appindicator support (GNOME may need an
  extension) — without a tray, add a `--open-panel` desktop entry as fallback.
- Wayland ignores absolute window positioning: the popover anchor and pinned
  window restore degrade to compositor placement; X11 behaves.
- Global hotkey is a no-op (no portable X11/Wayland registration).
- Snapshot-to-clipboard shells out to `wl-copy` or `xclip` (best-effort).
- Audio needs `libasound.so.2` (ALSA); when missing (or PipeWire/Pulse lacks the
  ALSA compat layer) streams play video-only with a logged notice.

## Distribution (future)

- **Windows** (decided 2026-07): paid = Microsoft Store as MSIX under a company
  account (the Store signs and auto-updates it); free = the unsigned Inno Setup
  installer from `scripts/package-windows.ps1` on GitHub releases (SmartScreen
  supplies the deliberate friction — intentionally unsigned, like the macOS
  DMG). No winget listing (frictionless `winget upgrade` would defeat that).
  One release tag per version carries all OS assets:
  `QuickProtect-<ver>.dmg` / `QuickProtect-Setup-<ver>-win-x64.exe` /
  `QuickProtect-<ver>-linux-x64.tar.gz`.
  MSIX packaging is in place (`scripts/package-msix.ps1`,
  `installer/msix/AppxManifest.xml`, committed tile assets); the Partner Center
  identity/publisher values are the only missing inputs. Two container
  behaviours are handled in code: `%APPDATA%` writes are redirected by Windows
  (no change needed), and launch-at-login moves from the `Run` key — virtualised
  away in a package — to the manifest's `windows.startupTask`, which the
  Settings UI surfaces as a pointer to Windows' own switch.
- **Linux** (deferred): frictionless-update channel wanted (Flathub preferred,
  pending its AI-assisted-app policy; fallbacks AUR + AppImage/tarball). Bundle
  the FFmpeg 7.1 natives (as the Windows installer does) or declare an FFmpeg
  7.x runtime dependency.
