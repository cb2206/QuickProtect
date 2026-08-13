# Windows/Linux port — session handoff

Cross-platform .NET 8 + Avalonia reimplementation of the macOS QuickProtect
app, living in `dotnet/`. Merged into `dev` 2026-07-19 (the `feat/windows-linux-port`
branch was deleted after the merge — work now happens directly on `dev`).

## Status
**Custom FFmpeg video engine + full macOS-parity UI, live-verified on Windows**
against a real controller (7 cameras at 10.0.1.1), including audio playback
(WASAPI/ALSA, see below). All 13 bugs from the 2026-07-07 bug-report round are
fixed and verified. Publicly released since 1.3 (2026-08): Microsoft Store
(paid MSIX) + the unsigned Inno Setup installer on GitHub releases. Linux
ships since 1.3.1 (2026-08) as a self-contained tarball on the same releases,
with an AUR package (`quickprotect-bin`) prepared in `dotnet/installer/aur/`
(`docs/PARITY.md`'s Distribution section has the channel details).
See `PARITY.md` for the feature matrix and intentional differences.

## Architecture: the video engine (don't regress these)

libVLC is GONE. Video is the macOS-style custom pipeline:

- `App/Video/FfmpegEngine.cs` — loads FFmpeg 7.1 natives (bundled per RID from
  `scripts/get-ffmpeg.ps1`, incl. **win-arm64** → native ARM decode; system
  libs on Linux when the folder is absent). Logs to
  `%APPDATA%\QuickProtect\video.log`.
- `App/Video/VideoStreamClient.cs` — one thread per stream: avformat/avcodec
  demux+decode → BGRA latest-frame buffer. First frame displays immediately;
  last frame survives reconnects and URL switches (no grey flash); broken
  streams retry with backoff; `SwitchUrl` changes quality in place.
- `App/Video/VideoSurface.cs` — composited Avalonia control (WriteableBitmap):
  fit/fill + digital zoom applied via source rect at draw time. Because video
  is ordinary Avalonia content, it's clickable/gesture-capable/overlayable —
  the entire native-HWND airspace bug class (input, overlays, pin crashes,
  D3D11 vout glitches) no longer exists.
- `App/Video/VideoStreamCoordinator.cs` — one shared client per camera lens
  (macOS RTSPClientManager analog): desires per consumer, highest quality
  wins, upgrades immediate / downgrades 0.6s-delayed, new allocation created
  before the old is released, entries keep their last frame after stop.
- **RTSPS**: `Core/Services/RtspTlsTunnel.cs` still carries TLS + TOFU pinning
  (FFmpeg plays plain rtsp://127.0.0.1). Keep it — it IS the cert policy.

Audio playback is done: the engine decodes the stream's audio track (Opus/AAC)
and renders it through a platform sink — WASAPI shared mode via NAudio on
Windows, ALSA via libasound P/Invoke on Linux (best-effort, untested until the
Linux phase). Same macOS-parity rules as the Swift app: only the focused
stream and pinned windows are audio-active, muted by default, Mute (M) only
shown when the stream actually has audio.

## Dev environment (this ARM64 VM)

- Plain `dotnet build` + run now has video (native ARM64 FFmpeg) — the old
  x64-publish requirement is gone.
- Run once per checkout: `powershell -File scripts/get-ffmpeg.ps1`
  (downloads BtbN LGPL-shared natives into gitignored `dotnet/native/`).
- Test flags: `--open-panel`, `--open-settings`, `--no-dismiss` (disables the
  popover's click-outside dismiss; REQUIRED for UI automation).
- Logs: `crash.log`, `video.log` in `%APPDATA%\QuickProtect`. Native crashes
  bypass crash.log — check the Windows event log (`.NET Runtime` 1026).
- With `ShowInTaskbar=False`, `MainWindowHandle` is 0 — find the panel HWND by
  EnumWindows and raise with `SetWindowPos HWND_TOPMOST` (foreground lock
  blocks `SetForegroundWindow`).

## Build / test / package
```
cd dotnet
powershell -File scripts/get-ffmpeg.ps1        # once per checkout
dotnet build QuickProtect.sln
dotnet test tests/QuickProtect.Core.Tests
powershell -File scripts/package-windows.ps1   # → dist/QuickProtect-Setup-<v>-win-x64.exe
```

## Next phase: Linux
Cross-publish compiles; `get-ffmpeg.ps1` also fetches linux-x64/arm64 natives
(or use system FFmpeg). Platform notes in `PARITY.md` (tray/Wayland/hotkey
caveats). The engine is pure .NET + FFmpeg — no platform video code.
