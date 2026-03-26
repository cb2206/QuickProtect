import AppKit

// Entry point: run as a status-bar-only (accessory) app
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
