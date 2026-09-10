import Foundation
@testable import ClaudepitCore

func writeOpsChecks() -> [Bool] {
    [
        check("setModel writes and backs up") {
            let dir = try tempDir()
            let f = dir.appending(path: "settings.json")
            try #"{"model":"opus","env":{"X":"1"}}"#.write(to: f, atomically: true, encoding: .utf8)

            try WriteOps.setModel("sonnet", in: f, epoch: 7)

            let obj = try JSONFile.readObject(f)
            try expectEqual(obj["model"] as? String, "sonnet", "model updated")

            let env = obj["env"] as? [String: Any]
            try expectEqual(env?["X"] as? String, "1", "env untouched")

            try expect(FileManager.default.fileExists(atPath: f.path + ".backup.7"), "backup exists")
        },

        check("setMCPEnabled toggles disabled flag") {
            let dir = try tempDir()
            let f = dir.appending(path: "settings.json")
            try #"{"mcpServers":{"pencil":{"command":"x"}}}"#.write(to: f, atomically: true, encoding: .utf8)

            try WriteOps.setMCPEnabled("pencil", false, in: f, epoch: 1)

            let obj = try JSONFile.readObject(f)
            let servers = obj["mcpServers"] as? [String: Any]
            let pencil = servers?["pencil"] as? [String: Any]
            try expectEqual(pencil?["disabled"] as? Bool, true, "disabled flag set")
        },

        check("setSkillOverride creates missing file and writes off state") {
            let dir = try tempDir()
            let f = dir.appending(path: ".claude/settings.json")   // .claude dir does not exist yet
            try WriteOps.setSkillOverride("foo", enabled: false, in: f, epoch: 1)

            try expect(FileManager.default.fileExists(atPath: f.path), "file created")
            try expect(!FileManager.default.fileExists(atPath: f.path + ".backup.1"), "no backup for new file")
            let obj = try JSONFile.readObject(f)
            let o = obj["skillOverrides"] as? [String: String]
            try expectEqual(o?["foo"], "user-invocable-only", "off state written")
        },

        check("setSkillOverride on removes key and drops empty object; backs up existing file") {
            let dir = try tempDir()
            let f = dir.appending(path: "settings.json")
            try #"{"skillOverrides":{"foo":"user-invocable-only"},"model":"opus"}"#.write(to: f, atomically: true, encoding: .utf8)

            try WriteOps.setSkillOverride("foo", enabled: true, in: f, epoch: 9)

            let obj = try JSONFile.readObject(f)
            try expect(obj["skillOverrides"] == nil, "empty skillOverrides dropped")
            try expectEqual(obj["model"] as? String, "opus", "other keys untouched")
            try expect(FileManager.default.fileExists(atPath: f.path + ".backup.9"), "backup made for existing file")
        }
    ]
}
