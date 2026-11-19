import Logging
import OSLogHandler

/// Runlet's swift-log loggers: every level of every call site ends up in the
/// Darwin unified logging system through `OSLogHandler` (subsystem
/// `app.runlet`, one os category per logger label), with `metadata` values
/// redacted unless marked `Sensitivity.public`.
///
/// Logs are viewable in Console.app or via:
/// ```sh
/// log stream --predicate 'subsystem == "app.runlet"'
/// ```
enum AppLogger {
    private static let subsystem = "app.runlet"

    /// Installs the handler factory and has to run before the first logger
    /// is built - `LoggingSystem.bootstrap` traps when called twice. The
    /// `Logger` statics below are lazy, so their construction picks up this
    /// factory.
    static func bootstrap() {
        LoggingSystem.bootstrap { label in
            var handler = OSLogHandler(subsystem: subsystem, category: label)
            #if !DEBUG
                // Release builds drop debug and trace the way the old
                // `#if DEBUG` gate did; the levels stay cheap because the
                // message and metadata arguments are autoclosures.
                handler.logLevel = .info
            #endif
            return handler
        }
    }

    static let app = Logger(label: "App")
    static let sshTunnel = Logger(label: "SSHTunnel")
    static let connection = Logger(label: "Connection")
    static let connectionTest = Logger(label: "ConnectionTest")
    static let functions = Logger(label: "Functions")
    static let profiler = Logger(label: "Profiler")
    static let pubSub = Logger(label: "PubSub")
    static let database = Logger(label: "Database")
    static let cluster = Logger(label: "Cluster")
    static let serverInfo = Logger(label: "ServerInfo")
    static let redis = Logger(label: "Redis")
    static let keys = Logger(label: "Keys")
    static let shell = Logger(label: "Shell")
    static let analysis = Logger(label: "Analysis")
}
