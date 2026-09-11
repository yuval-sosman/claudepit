import Foundation

/// Finds CLI tools by searching this machine, rather than assuming an install prefix.
///
/// Claudepit shells out to `claude` and `herdr`, which land in different places depending
/// on how they were installed — Homebrew (`/opt/homebrew/bin`), a user install
/// (`~/.local/bin`), npm/nvm, or `/usr/local/bin` on Intel. Baking in one prefix makes the
/// app work on the machine it was written on and fail on every other one, so resolution is
/// always a search.
///
/// Lookups are pure filesystem — no subprocess. Beyond being faster, this is a hard
/// requirement for any resolver reachable from a SwiftUI view body: a `Process` +
/// `waitUntilExit()` there spins the run loop and re-enters SwiftUI mid-update, which
/// aborts the app.
public enum Executable {

    /// Directories to search, in priority order: the inherited PATH first, then the usual
    /// install locations. The fallbacks matter because an app launched from Finder inherits
    /// a minimal PATH containing neither Homebrew nor `~/.local/bin`.
    public static func searchDirs() -> [String] {
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        return fromPath + [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    /// Absolute path to `tool`, or nil if it isn't installed anywhere we look.
    public static func find(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in searchDirs() where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// A PATH value that includes the fallback locations, for subprocesses we spawn.
    /// Deduped, since `searchDirs()` already starts with the inherited PATH and the
    /// fallbacks usually repeat entries that were in it.
    public static func augmentedPATH() -> String {
        var seen = Set<String>()
        return searchDirs().filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }
}
