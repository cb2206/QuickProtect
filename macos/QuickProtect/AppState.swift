import SwiftUI

/// Window-level state that AppDelegate owns but views need to read: whether
/// the panel is in true fullscreen, and the pinned floating-window manager.
/// Injected into the SwiftUI environment (`\.appState`) so views never reach
/// for `NSApp.delegate`.
final class AppState: ObservableObject {
    @Published var isInTrueFullscreen = false
    /// Set by AppDelegate once the manager exists; nil in previews and tests.
    var pinnedWindows: PinnedWindowManager?
}

private struct AppStateKey: EnvironmentKey {
    /// Inert instance for views hosted without an injection: never
    /// fullscreen, no pinning available.
    static let defaultValue = AppState()
}

extension EnvironmentValues {
    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
}
