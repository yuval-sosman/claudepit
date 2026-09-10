import Foundation
@testable import ClaudepitCore

func appConfigStoreChecks() -> [Bool] {
    var results: [Bool] = []
    let store = AppConfigStore()

    func freshBase() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "appcfg-\(Int.random(in: 0..<Int.max))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    results.append(check("seedIfNeeded writes all file-backed configs with builtin defaults") {
        let base = freshBase()
        store.seedIfNeeded(base)
        for c in ManagedConfig.catalog where !c.filename.isEmpty {
            let url = Paths.appConfigDir(base).appending(path: c.filename)
            try expect(FileManager.default.fileExists(atPath: url.path), "seeded \(c.filename)")
            try expectEqual(store.content(base, c), c.builtinDefault, "\(c.id) = builtin")
        }
    })

    results.append(check("seedIfNeeded never overwrites a user edit") {
        let base = freshBase()
        store.seedIfNeeded(base)
        let c = ManagedConfig.byID("summary-hook")!
        try store.saveContent(base, c, "MY EDIT")
        store.seedIfNeeded(base)   // second seed must not clobber
        try expectEqual(store.content(base, c), "MY EDIT", "edit survives re-seed")
    })

    // Auto-update: an untouched copy is refreshed when the built-in changes; an edited copy isn't.
    // We simulate a "new built-in" by pointing the stored seededHash at an OLD value, so the file
    // (which still equals the current built-in) is treated as untouched-and-stale.
    results.append(check("seedIfNeeded auto-updates an untouched copy when builtin changed") {
        let base = freshBase()
        let c = ManagedConfig.byID("summary-hook")!
        // Seed the copy with an OLD built-in and record its hash as the seed.
        try store.saveContent(base, c, "OLD BUILTIN")
        store.setSeededHashForTest(base, c.id, AppConfigStore.hashForTest("OLD BUILTIN"))
        // Now seedIfNeeded should see: file hash == seededHash (untouched) but != current builtin → refresh.
        store.seedIfNeeded(base)
        try expectEqual(store.content(base, c), c.builtinDefault, "untouched copy refreshed to new builtin")
    })

    results.append(check("seedIfNeeded preserves an edited copy even when builtin changed") {
        let base = freshBase()
        let c = ManagedConfig.byID("summary-hook")!
        try store.saveContent(base, c, "MY EDIT")
        // Seed hash points at some other value, and file != that hash → edited, must be preserved.
        store.setSeededHashForTest(base, c.id, AppConfigStore.hashForTest("OLD BUILTIN"))
        store.seedIfNeeded(base)
        try expectEqual(store.content(base, c), "MY EDIT", "edited copy preserved")
    })

    results.append(check("content round-trips after saveContent") {
        let base = freshBase()
        let c = ManagedConfig.byID("task-plan")!
        try store.saveContent(base, c, "custom plan command")
        try expectEqual(store.content(base, c), "custom plan command", "saved content read back")
    })

    results.append(check("content falls back to builtin when file deleted/corrupted") {
        let base = freshBase()
        store.seedIfNeeded(base)
        let c = ManagedConfig.byID("memory-hook")!
        try FileManager.default.removeItem(at: Paths.appConfigDir(base).appending(path: c.filename))
        try expectEqual(store.content(base, c), c.builtinDefault, "fallback to builtin")
    })

    results.append(check("resetToDefault restores builtin, discarding edits") {
        let base = freshBase()
        let c = ManagedConfig.byID("memory-system-prompt")!
        try store.saveContent(base, c, "garbage")
        try store.resetToDefault(base, c)
        try expectEqual(store.content(base, c), c.builtinDefault, "reset to builtin")
    })

    results.append(check("setEnabled / isEnabled round-trip through config.json") {
        let base = freshBase()
        store.setEnabled(base, "summary-hook", false)
        try expect(!store.isEnabled(base, "summary-hook"), "disabled persisted")
        store.setEnabled(base, "summary-hook", true)
        try expect(store.isEnabled(base, "summary-hook"), "re-enabled persisted")
    })

    results.append(check("cleanupPeriodDays default is 3650 and round-trips") {
        let base = freshBase()
        try expectEqual(store.cleanupPeriodDays(base), 3650, "default 3650")
        store.setCleanupPeriodDays(base, 30)
        try expectEqual(store.cleanupPeriodDays(base), 30, "custom value read back")
    })

    // MARK: status()

    results.append(check("status: seed -> untouched, edit -> edited, reset -> untouched, delete -> missing") {
        let base = freshBase()
        let c = ManagedConfig.byID("summary-hook")!
        try expect(store.status(base, c) == .missing, "missing before seed")
        store.seedIfNeeded(base)
        try expect(store.status(base, c) == .untouched, "untouched after seed")
        try store.saveContent(base, c, "MY EDIT")
        try expect(store.status(base, c) == .edited, "edited after save")
        store.seedIfNeeded(base)
        try expect(store.status(base, c) == .edited, "still edited after re-seed")
        try store.resetToDefault(base, c)
        try expect(store.status(base, c) == .untouched, "untouched after reset")
        try FileManager.default.removeItem(at: Paths.appConfigDir(base).appending(path: c.filename))
        try expect(store.status(base, c) == .missing, "missing after delete")
    })

    results.append(check("status: a .number entry reports untouched (it has no editable copy)") {
        let base = freshBase()
        store.seedIfNeeded(base)
        let c = ManagedConfig.byID("cleanup-period")!
        try expect(c.filename.isEmpty, "cleanup-period has no copy")
        try expect(store.status(base, c) == .untouched, "no copy -> nothing to diverge")
    })

    // Regression: a copy from before hashing (seededHash nil) whose content already equals the
    // built-in must get its hash stamped WITHOUT the file being rewritten — a rewrite here is
    // identical bytes but a real FileWatcher event, on every single launch.
    results.append(check("seedIfNeeded stamps a nil seededHash without rewriting the file") {
        let base = freshBase()
        let c = ManagedConfig.byID("memory-system-prompt")!
        store.seedIfNeeded(base)
        // Force the pre-hashing shape: content == builtin, but no recorded seededHash.
        var file = store.load(base)
        file.configs[c.id] = ManagedConfigState(enabled: true, cleanupPeriodDays: nil, seededHash: nil)
        try Data(JSONEncoder().encode(file)).write(to: Paths.appConfigFile(base), options: .atomic)
        try expect(store.load(base).configs[c.id]?.seededHash == nil, "seededHash cleared")

        let url = Paths.appConfigDir(base).appending(path: c.filename)
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        store.seedIfNeeded(base)

        try expectEqual(store.load(base).configs[c.id]?.seededHash,
                        AppConfigStore.hashForTest(c.builtinDefault), "hash stamped")
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try expectEqual(mtime, stamp, "file NOT rewritten")
        try expectEqual(store.content(base, c), c.builtinDefault, "content still the builtin")
    })

    results.append(check("load returns defaults on corrupt config.json") {
        let base = freshBase()
        try FileManager.default.createDirectory(at: Paths.appConfigDir(base), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: Paths.appConfigFile(base))
        try expectEqual(store.load(base).configs.count, 0, "empty configs on corrupt file")
        try expect(store.isEnabled(base, "summary-hook"), "falls back to defaultEnabled")
    })

    return results
}
