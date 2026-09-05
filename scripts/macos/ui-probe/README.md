# ui-probe — drive the Debug app for hands-off checks

Two single-file tools that post hardware-level events with CGEvent, for
exercising the running app without a person at the keyboard (System Events'
`click at` is too soft for SwiftUI tap gestures and drops its connection):

```bash
swiftc -O -o /tmp/click scripts/macos/ui-probe/click.swift
swiftc -O -o /tmp/key   scripts/macos/ui-probe/key.swift
/tmp/click 835 484            # left click at screen point (x, y)
/tmp/click 960 400 1 right    # right click
/tmp/key 1                    # press virtual key code (1 = S, 53 = Esc, 3 = F)
```

Recipe used on 2026-09-05: launch with
`QUICKPROTECT_DEBUG_LOG=1 macos/build/Debug/QuickProtect.app/Contents/MacOS/QuickProtect --open-panel 2> log`,
read the panel frame with
`osascript -e 'tell application "System Events" to tell process "QuickProtect" to get {position, size} of windows'`,
click tiles/buttons by screen point, and verify with
`screencapture -x -R x,y,w,h out.png` plus the log. Keystrokes reach the
panel because it is key without activating the app; keep the mouse on it.
