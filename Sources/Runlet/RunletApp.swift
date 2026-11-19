import AppKit

@main
struct RunletApp {
    static func main() {
        AppLogger.bootstrap()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
