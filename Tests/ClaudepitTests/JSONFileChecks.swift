import Foundation
@testable import ClaudepitCore

func jsonFileChecks() -> [Bool] {
    [
        check("JSONFile round-trip + backup") {
            let dir = try tempDir()
            let file = dir.appending(path: "settings.json")
            try #"{"model":"opus"}"#.write(to: file, atomically: true, encoding: .utf8)

            var obj = try JSONFile.readObject(file)
            try expectEqual(obj["model"] as? String, "opus", "read model")

            let backup = try JSONFile.backup(file, epoch: 123)
            try expect(FileManager.default.fileExists(atPath: backup.path), "backup exists")

            obj["model"] = "sonnet"
            try JSONFile.writeObject(obj, to: file)
            let reread = try JSONFile.readObject(file)
            try expectEqual(reread["model"] as? String, "sonnet", "rewritten model")
        }
    ]
}
