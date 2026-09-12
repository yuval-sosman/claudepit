import SwiftUI
import AppKit

/// Makes the hosting NSWindow use desktop-sampling vibrancy (real glass).
struct VibrancyView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// ponytail: bare-executable launch (no .app bundle) starts non-regular, so
// the window never becomes key and TextField keyboard input is dead. Force it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ClaudepitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ZStack {
                VibrancyView().ignoresSafeArea()
                ContentView(app: app)
            }
            .onAppear {
                app.startWatching()
                app.refreshClaudeAuth()
            }
            // The sign-in flow finishes in a browser, outside this app — so nothing
            // else would ever clear the banner. Guarded on needsSignIn so a healthy
            // login costs no subprocess on ordinary window focus.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                if app.claudeAuth?.needsSignIn == true { app.refreshClaudeAuth(force: true) }
            }
        }
        .windowStyle(.hiddenTitleBar)

        // Status-bar item. Shares the one `AppState` with the window above — it is a second
        // *view* of the same data, never a second source of truth, so its count and Home's
        // "Needs attention" card are the same list by construction.
        MenuBarExtra { MenuBarPanel(app: app) } label: { MenuBarLabel(app: app) }
            .menuBarExtraStyle(.window)
    }
}
