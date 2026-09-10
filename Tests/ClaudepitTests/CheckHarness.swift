import Foundation

/// Tiny assert-based check harness (no XCTest — CLI-toolchain only machine).
/// Each check throws on failure; the runner tallies and exits non-zero if any fail.
struct CheckFailure: Error { let message: String }

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw CheckFailure(message: message()) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String = "") throws {
    if a != b { throw CheckFailure(message: "\(label): expected \(b), got \(a)") }
}

/// Run a named check, print PASS/FAIL, return true on pass.
func check(_ name: String, _ body: () throws -> Void) -> Bool {
    do { try body(); print("PASS  \(name)"); return true }
    catch { print("FAIL  \(name): \(error)"); return false }
}

/// Make a fresh temp directory for a check.
func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Copy a checked-in fixture dir to a temp dir, return the copy.
func copyFixture(_ relativePath: String) throws -> URL {
    // Fixtures live next to this source file under Fixtures/.
    let src = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures").appending(path: relativePath)
    let dst = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.copyItem(at: src, to: dst)
    return dst
}
