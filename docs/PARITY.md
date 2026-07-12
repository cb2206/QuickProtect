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
- **Settings window** — connection, default quality, PTZ credentials,
  launch-at-login, appearance (auto/light/dark), accent color (7 presets, applied
  live), focus-controls toggle, snapshot destination (clipboard/folder + picker),
  language picker, hotkey recorder, update banner.
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
  input (global cursor poll on Windows; the native libVLC surface swallows
  Avalonia pointer events).
- **PTZ control** — d-pad + zoom pill (pointer hold), keyboard (arrows, I/O),
  continuous-velocity moves with the macOS quick-tap **minimum burst** (0.25s,
  `PtzBurstTimer` in Core, unit-tested).
- **Pinned always-on-top windows** — borderless, top-most, draggable, aspect-locked
  resize, frame persistence, restore-on-launch, independent pinned allocation.
- **Snapshots** — clipboard (Win32 CF_DIB+PNG / wl-copy / xclip / osascript) or
  folder, honoring the destination setting; async capture awaits libVLC's file.
- **Secondary-lens PiP** — package-camera side panel in focus with a **swap**
  button that exchanges playback between the lenses in place (no re-allocation).
- **Onboarding** — 3-step wizard (Connect → PTZ → All set).
- **Global hotkey** — native `RegisterHotKey` on Windows; Linux is a documented no-op.
- **Update checker** — notify-only GitHub releases poll + Settings banner.
- **Theming** — light/auto/dark via Avalonia theme variants with the full Aurora
  token palette (23 semantic Qp* tokens per variant); video surfaces (grid tiles,
  focus, pinned windows) stay pinned dark exactly like macOS; accent-derived
  brushes update live.
- **Localization** — 7 languages (en/de/fr/es/nl/it/pt-BR) from the macOS String
  Catalog; `Loc` helper + `{loc:Loc}` markup extension; OS culture detection +
  Settings language picker.
- **Graceful degradation** — if libVLC can't initialize, the app runs without
  video and tiles show a notice instead of crashing.
- **Diagnostics** — `crash.log` (fatal), `vlc.log` (libVLC Warning+, or full with
  `QP_VLC_DEBUG=1`); `--open-panel` / `--no-dismiss` flags for testing.
- **Windows installer** — Inno Setup (`installer/QuickProtect.iss`) via
  `scripts/package-windows.ps1`, 7 wizard languages, closes the running tray app
  on upgrade.

## Intentional differences from macOS

| Topic | macOS | This port | Why |
|---|---|---|---|
| Audio playback | decoded + rendered (default muted) | **not yet implemented** — mute button is a stub | the FFmpeg engine is video-only so far; a WASAPI/ALSA audio sink is the next engine milestone |
| Profile rename/delete in header menu | header profile menu | Settings → Cameras & Layout | header has switcher + save-as-new; full management lives in Settings |
| Stream-protocol toggle | `usePlainRtsp` setting exists in the UI | omitted | The macOS setting is vestigial — nothing consumes it (the stream token is only valid on the rtsps endpoint, `ProtectService.swift:455`) |
| Grid-tile PiP | optional per-camera PiP on grid tiles | focus-only PiP | each PiP is a native HWND + an extra server stream; cost outweighs the value at grid size |
| Panel anchor | popover under the menu-bar item (top) | popover at the tray corner (bottom-right) | Windows/Linux tray convention |
| Digital zoom input | pinch/scroll gestures on the frame | keyboard (+/−/0, arrows) | the native libVLC surface cannot receive Avalonia gestures |
| Per-display panel size | per-profile **and** per-display | per-profile | multi-monitor display identity is less stable off macOS; revisit if needed |

## Platform notes (for the Linux phase)

- Video requires system libVLC (`apt install vlc`); no Linux native NuGet exists.
- The rtsps TLS tunnel works unchanged on Linux (pure .NET sockets).
- Tray icons need StatusNotifierItem/appindicator support (GNOME may need an
  extension) — without a tray, add a `--open-panel` desktop entry as fallback.
- Wayland ignores absolute window positioning: the popover anchor and pinned
  window restore degrade to compositor placement; X11 behaves.
- Global hotkey is a no-op (no portable X11/Wayland registration).
- Snapshot-to-clipboard shells out to `wl-copy` or `xclip` (best-effort).

## Distribution (future)

- **Windows**: `scripts/package-windows.ps1` → Inno Setup installer (done); code
  signing still open. The notify-only updater policy carries over.
- **Linux**: AppImage or Flatpak; declare the `vlc`/`libvlc` runtime dependency.
