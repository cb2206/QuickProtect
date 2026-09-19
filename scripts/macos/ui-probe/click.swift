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
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let count = a.count > 3 ? Int(a[3])! : 1
let right = a.count > 4 && a[4] == "right"
let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
for i in 1...count {
    let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)!
    d.setIntegerValueField(.mouseEventClickState, value: Int64(i)); d.post(tap: .cghidEventTap)
    usleep(60_000)
    let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)!
    u.setIntegerValueField(.mouseEventClickState, value: Int64(i)); u.post(tap: .cghidEventTap)
    usleep(80_000)
}
