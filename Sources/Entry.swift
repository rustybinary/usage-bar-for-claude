import AppKit

// Entry point. The app runs as a menu bar accessory: no Dock icon, no main window.
@main
enum UsageBarForClaudeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
