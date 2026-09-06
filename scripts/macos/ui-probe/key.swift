import Foundation
import CoreGraphics
import AppKit
// Safety: only drive the screen while the app that was frontmost when the
// check started is still frontmost (default: the Claude desktop app). If the
// user has switched to something else, they are using the Mac — abort.
let expectedFront = ProcessInfo.processInfo.environment["UIPROBE_EXPECT_FRONT"] ?? "Claude"
if let front = NSWorkspace.shared.frontmostApplication?.localizedName, front != expectedFront {
    FileHandle.standardError.write("ui-probe: refusing to post events — frontmost app is \(front), expected \(expectedFront)\n".data(using: .utf8)!)
    exit(3)
}
// usage: key <virtual key code> [cmd,alt,shift,ctrl]
let code = CGKeyCode(UInt16(CommandLine.arguments[1])!)
var flags: CGEventFlags = []
if CommandLine.arguments.count > 2 {
    for f in CommandLine.arguments[2].split(separator: ",") {
        switch f { case "cmd": flags.insert(.maskCommand); case "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift); case "ctrl": flags.insert(.maskControl); default: break }
    }
}
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(60_000)
}
