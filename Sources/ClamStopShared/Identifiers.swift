// Identifiers shared by the app, the daemon and the packaging scripts.
// Keep in sync with scripts/ and Resources/ (see CLAUDE.md).
public enum ClamStopID {
    public static let appBundleID = "io.github.chanoj.clamstop"
    public static let daemonLabel = "io.github.chanoj.clamstop.daemon"
    public static let daemonPlistName = "io.github.chanoj.clamstop.daemon.plist"
    public static let machServiceName = "io.github.chanoj.clamstop.daemon.xpc"
}
