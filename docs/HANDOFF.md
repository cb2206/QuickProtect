# Windows/Linux port — current state

Cross-platform .NET 8 + Avalonia reimplementation of the macOS QuickProtect
app, living in `dotnet/`. Work happens directly on `dev`; releases are tagged
from `main` (see the repo README for the branch flow).

## Status

Shipping on all three channels:

- **Windows** since 1.3 (2026-08): Microsoft Store (paid MSIX, Store-signed
  and auto-updated) and the Inno Setup installer on GitHub releases (not
  code-signed, notify-only update check).
- **Linux** since 1.3.1 (2026-08): self-contained x64 tarball on GitHub
  releases, with an AUR package (`quickprotect-bin`, `dotnet/installer/aur/`)
  prepared but not yet published to the AUR.

Feature parity with the macOS app is complete; the intentional differences and
the per-platform caveats (GNOME tray click behaviour, Wayland window placement,
portal-owned global hotkeys) are in `PARITY.md`.

## Architecture: the video engine (don't regress these)

Video is the macOS-style custom pipeline on top of FFmpeg 9.0:

- `App/Video/FfmpegEngine.cs` — loads the FFmpeg natives (bundled per RID by
  `scripts/get-ffmpeg.*`, pinned to a fixed BtbN build with SHA-256 checks;
  system libraries on Linux when the folder is absent). Logs FFmpeg
  warnings/errors to `video.log` in the config directory.
- `App/Video/VideoStreamClient.cs` — one thread per stream session:
  avformat/avcodec demux + decode → BGRA latest-frame buffer. First frame
  displays immediately; the last frame survives reconnects and URL switches;
  broken streams retry with backoff; quality switches hand over seamlessly to
  a second session. `Stop()` only signals — it never blocks the UI thread.
- `App/Video/VideoSurface.cs` — composited Avalonia control (WriteableBitmap):
  fit/fill + digital zoom applied via source rect at draw time. Video is
  ordinary Avalonia content, so it is clickable, gesture-capable, overlayable.
- `App/Video/VideoStreamCoordinator.cs` — one shared client per camera lens
  (macOS `RTSPClientManager` analog): desires per consumer, highest quality
  wins, upgrades immediate / downgrades 0.6 s delayed, new allocation created
  before the old is released, failed allocations retried with backoff, desires
  that change mid-switch re-resolved when the switch settles.
- **RTSPS**: `Core/Services/RtspTlsTunnel.cs` carries TLS + the certificate
  policy (FFmpeg plays plain `rtsp://127.0.0.1`). It pins under the configured
  controller identity (`ControllerAddress.PinKey`), the same pin the HTTPS API
  uses. Keep it — it IS the cert policy.

Audio: the engine decodes the stream's audio track (Opus/AAC) and renders it
through a platform sink — WASAPI shared mode via NAudio on Windows, ALSA via
libasound P/Invoke on Linux (video-only with a logged notice when
`libasound.so.2` is missing). Same rules as the Swift app: only the focused
stream and pinned windows are audio-active, muted by default, Mute (M) only
shown when the stream actually has audio.

## Certificate trust

System trust first (a publicly valid certificate for the host is accepted
without pinning), then trust-on-first-use pinning of the controller's
SubjectPublicKeyInfo SHA-256, keyed by `ControllerAddress.PinKey`. A changed
key is rejected and listed in Settings → Connection with both fingerprints;
"Trust new certificate" re-pins. The same policy, hash and key layout are used
by the macOS app.

## Dev environment

- `dotnet build` + run has video natively on x64 and ARM64 (win-arm64 and
  linux-arm64 natives are fetched too).
- Run once per checkout: `powershell -File dotnet/scripts/get-ffmpeg.ps1`
  (Windows) or `dotnet/scripts/get-ffmpeg.sh` (Linux/macOS) — downloads the
  pinned BtbN LGPL-shared natives into gitignored `dotnet/native/` after
  verifying their checksums.
- Test flags: `--open-panel`, `--open-settings`, `--no-dismiss` (disables the
  popover's click-outside dismiss; REQUIRED for UI automation).
- Logs: `crash.log`, `video.log` in `%APPDATA%\QuickProtect`
  (`~/.config/QuickProtect` on Linux). Native crashes bypass crash.log — on
  Windows check the event log (`.NET Runtime` 1026). Stream URLs are never
  logged in full (the path is a bearer token).
- With `ShowInTaskbar=False`, `MainWindowHandle` is 0 — find the panel HWND by
  EnumWindows and raise with `SetWindowPos HWND_TOPMOST` (foreground lock
  blocks `SetForegroundWindow`).

## Build / test / package

```
cd dotnet
powershell -File scripts/get-ffmpeg.ps1        # once per checkout (Windows)
dotnet restore QuickProtect.sln --locked-mode  # what CI runs
dotnet format QuickProtect.sln --verify-no-changes
dotnet test QuickProtect.sln                   # warnings are errors, analyzers on
powershell -File scripts/package-windows.ps1   # → dist/QuickProtect-Setup-<v>-win-x64.exe
scripts/package-linux.sh                       # → dist/QuickProtect-<v>-linux-x64.tar.gz
```

Every published build carries `LICENSE` and `THIRD-PARTY-NOTICES.txt` (FFmpeg
LGPL-2.1, FFmpeg.AutoGen LGPL-3.0, Avalonia/NAudio/Toolkit MIT, Inter OFL).
Bumping FFmpeg means updating the pinned tag + checksums in both
`get-ffmpeg.*` scripts, the FFmpeg.AutoGen package, and the notices file.

## Open follow-ups

- The FFmpeg pin is a BtbN end-of-month snapshot of the n9.0 branch
  (`autobuild-2026-08-31-13-27`, libavcodec 63) with FFmpeg.AutoGen 9.0.1.1.
  Bump both together every few months (tag + four checksums in
  `scripts/get-ffmpeg.*`, the package versions, THIRD-PARTY-NOTICES.txt) and
  run `dotnet test tests/QuickProtect.App.Tests` with an `ffmpeg` binary on
  PATH — it decodes a live RTSP test pattern through the engine.
- No App-level test project yet: `VideoStreamCoordinator` and the view models
  are only covered indirectly. `ProtectService`'s HTTP paths need a fake
  `HttpMessageHandler`.
