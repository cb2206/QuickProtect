import Foundation
import CoreGraphics
let code = CGKeyCode(UInt16(CommandLine.arguments[1])!)
CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
