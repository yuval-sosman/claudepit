import Foundation

public enum JSONFileError: Error { case notAnObject }

public enum JSONFile {
    public static func readObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else { throw JSONFileError.notAnObject }
        return dict
    }

    /// Copy to <file>.backup.<epoch>. Returns backup URL. epoch passed in for testability.
    public static func backup(_ url: URL, epoch: Int) throws -> URL {
        let dest = url.deletingLastPathComponent()
            .appending(path: url.lastPathComponent + ".backup.\(epoch)")
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// Validate that the object serializes to valid JSON, then write atomically.
    public static func writeObject(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        // re-parse to validate round-trips
        _ = try JSONSerialization.jsonObject(with: data)
        try data.write(to: url, options: .atomic)
    }
}
