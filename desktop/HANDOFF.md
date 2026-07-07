# Windows/Linux port — session handoff

Cross-platform .NET 8 + Avalonia + LibVLCSharp reimplementation of the macOS
QuickProtect app, living in `desktop/`. Branch: `feat/windows-linux-port`.

## Status
**Feature parity reached and live-verified on Windows** against a real
controller (7 cameras at 10.0.1.1): grid + focus video, PTZ, digital zoom,
PiP swap, pinned windows, snapshots (clipboard + folder), fullscreen HUD,
drag-reorder, popover panel, light/auto/dark theming, 7 languages, installer.
See `PARITY.md` for the full matrix and intentional differences.

## The two big root causes fixed on Windows (don't regress these)

1. **Black video tiles** — VLC 3.x has **no access module for `rtsps://`**
   ("no access modules matched" in the debug log). Not a TLS-trust or decoder
   issue. Fixed by `Core/Services/RtspTlsTunnel.cs`: loopback listener →
   `SslStream` to the controller with TOFU `CertificateTrust` validation;
   `VlcManager.MakeMedia` rewrites rtsps URLs to `rtsp://127.0.0.1:<port>/…`.
2. **Native AccessViolation on player teardown** — `VideoView.Detach()` calls
   `set_Hwnd` on the outgoing `MediaPlayer`; disposing the player before the
   view unbinds crashes in `LibVLCMediaPlayerSetHwnd`. Always unbind/close the
   view first, dispose the tile after (see `MainViewModel`,
   `PinnedWindowManager`). Related: libVLC only honors a **new** Hwnd on the
   next `Play()` — after a grid reorder recreates the container, the moved
   tile's playback is restarted (`RestartPlayback`).

## Dev environment gotchas (this ARM64 VM)

- The installed .NET SDK is **ARM64**; libVLC ships x64-only. A plain
  `dotnet run` produces an ARM64 process → **no video** (graceful degradation).
  For video, publish self-contained x64 and run that (under emulation):
  ```
  dotnet publish src/QuickProtect.App -c Debug -r win-x64 --self-contained -o publish-x64-debug
  publish-x64-debug\QuickProtect.exe --open-panel --no-dismiss
  ```
- `--open-panel` opens the grid at launch; `--no-dismiss` disables the
  popover's click-outside dismiss (needed for UI automation, otherwise the
  panel hides the moment focus goes elsewhere).
- Logs: `%APPDATA%\QuickProtect\crash.log`, `%APPDATA%\QuickProtect\vlc.log`
  (Warning+; set `QP_VLC_DEBUG=1` for everything). Native crashes bypass
  crash.log — check the Windows Application event log (`.NET Runtime` 1026).

## Build / test / package
```
cd desktop
dotnet build QuickProtect.sln                 # build all
dotnet test tests/QuickProtect.Core.Tests     # Core unit tests
powershell -File scripts/package-windows.ps1  # → dist/QuickProtect-Setup-<v>-x64.exe
dotnet publish src/QuickProtect.App -c Release -r linux-x64 --self-contained   # compiles ✓
```

## Next phase: Linux
The code is Linux-clean (cross-publish compiles; platform paths abstracted in
`Platform/` and OS-gated). Real-machine testing is the remaining work — see
"Platform notes" in `PARITY.md` for the known degradations (tray icon on
GNOME, Wayland positioning, hotkey no-op, wl-copy/xclip clipboard).

## Layout
- `src/QuickProtect.Core` — portable: models (incl. `DigitalZoom`,
  `PtzBurstTimer`), `ProtectService` (UniFi dual API), `RtspTlsTunnel`,
  `CertificateTrust` (TOFU), `AppSettings`, secret/prefs stores. Unit-tested.
- `src/QuickProtect.App` — Avalonia UI: tray shell (`App.axaml.cs`), popover
  grid (`MainWindow` + `MainViewModel`/`CameraTileViewModel`), focus + PTZ +
  digital zoom + PiP, pinned windows, settings, onboarding, localization,
  `Platform/` (hotkey, launch-at-login, image clipboard).
- `installer/` + `scripts/` — Windows packaging.
- See `git log --oneline` for the feature-by-feature build-out.
