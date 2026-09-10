import Foundation

public enum TaskTransition {
    /// Last-marker-wins parse of `CLAUDEPIT_ARTIFACT: <path>`.
    public static func parseArtifact(from output: String) -> String? {
        lastMarker(in: output, marker: "CLAUDEPIT_ARTIFACT:")
    }

    /// Next phase in the task's planned list after `current` (nil current → first planned; nil if last/not-found).
    public static func nextPlannedPhase(after current: TaskPhase?, in planned: [TaskPhase]) -> TaskPhase? {
        guard let current else { return planned.first }
        guard let i = planned.firstIndex(of: current), i + 1 < planned.count else { return nil }
        return planned[i + 1]
    }

    /// A task can run iff every dependency id resolves to a `.done` task. Missing id / cycle → false.
    public static func canRun(_ task: ProjectTask, allTasks: [ProjectTask]) -> Bool {
        unmetDependencies(task, allTasks: allTasks).isEmpty
    }

    /// Dependency ids that are not yet satisfied (missing task or not `.done`).
    public static func unmetDependencies(_ task: ProjectTask, allTasks: [ProjectTask]) -> [String] {
        task.dependsOn.filter { dep in
            guard let d = allTasks.first(where: { $0.id == dep }) else { return true }
            return d.status != .done
        }
    }

    /// Insert `phase` into `planned` at its canonical `TaskPhase.allCases` position (idempotent).
    public static func insertPhase(_ phase: TaskPhase, into planned: [TaskPhase]) -> [TaskPhase] {
        if planned.contains(phase) { return planned }
        let order = TaskPhase.allCases
        let target = order.firstIndex(of: phase) ?? order.count
        var out = planned
        let idx = out.firstIndex { (order.firstIndex(of: $0) ?? order.count) > target } ?? out.count
        out.insert(phase, at: idx)
        return out
    }

    /// False if adding edge `from → to` (from depends on to) would create a cycle, or is self.
    public static func canAddDependency(from: ProjectTask, to: ProjectTask, allTasks: [ProjectTask]) -> Bool {
        if from.id == to.id { return false }
        if from.dependsOn.contains(to.id) { return false }   // already there
        // Cycle if `from` is reachable from `to` via dependsOn.
        let byID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
        var stack = [to.id]; var seen = Set<String>()
        while let cur = stack.popLast() {
            if cur == from.id { return false }
            guard seen.insert(cur).inserted, let t = byID[cur] else { continue }
            stack.append(contentsOf: t.dependsOn)
        }
        return true
    }

    /// Parse a `CLAUDEPIT_FINDINGS_BEGIN … CLAUDEPIT_FINDINGS_END` block into findings.
    /// Each line: `severity | title | detail`. Deterministic id = FNV-1a hex of title.
    public static func parseFindings(from output: String) -> [ReviewFinding] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let begin = lines.firstIndex(where: { $0.contains("CLAUDEPIT_FINDINGS_BEGIN") }),
              let end = lines.firstIndex(where: { $0.contains("CLAUDEPIT_FINDINGS_END") }),
              begin < end else { return [] }
        var out: [ReviewFinding] = []
        for line in lines[(begin + 1)..<end] {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 3 else { continue }
            let severity = parts[0].lowercased(), title = parts[1], detail = parts[2]
            guard !title.isEmpty else { continue }
            // id keyed on title+detail so two same-titled findings stay distinct (they're Identifiable).
            out.append(ReviewFinding(id: fnv1aHex(title + "|" + detail), title: title, detail: detail, severity: severity))
        }
        return out
    }

    /// Parse the brainstorm YAML deliverable into typed suggestions.
    /// ponytail: hand-rolled line-parser for exactly the brainstorm schema (`suggestions:` list of
    /// `kind`/`value`/`rationale`). No YAML lib — upgrade to one only if the schema grows nested/complex.
    public static func parseBrainstormSuggestions(from yaml: String) -> [BrainstormSuggestion] {
        var out: [BrainstormSuggestion] = []
        var inList = false
        var kind: String?, value: String?, rationale: String?

        func flush() {
            defer { kind = nil; value = nil; rationale = nil }
            guard let k = kind.flatMap(BrainstormSuggestion.Kind.init(rawValue:)),
                  let v = value, !v.isEmpty else { return }
            out.append(BrainstormSuggestion(id: fnv1aHex(k.rawValue + "|" + v), kind: k,
                                            value: v, rationale: rationale ?? ""))
        }

        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !inList {
                if trimmed.hasPrefix("suggestions:") { inList = true }
                continue
            }
            // A new list item starts with "- " — flush the previous one first.
            var body = trimmed
            if body.hasPrefix("- ") { flush(); body = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            else if body == "-" { flush(); continue }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces)
            let val = stripYAMLValue(String(body[body.index(after: colon)...]))
            switch key {
            case "kind":      kind = val.lowercased()
            case "value":     value = val
            case "rationale": rationale = val
            default:          break   // unknown key — ignore (tolerant)
            }
        }
        flush()
        return out
    }

    /// Strip an inline `# comment`, surrounding quotes, and whitespace from a YAML scalar.
    private static func stripYAMLValue(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        // Only treat a trailing `#` as a comment when the value isn't quoted (quotes may contain #).
        if !(v.hasPrefix("\"") || v.hasPrefix("'")), let hash = v.firstIndex(of: "#") {
            v = String(v[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    /// Last-marker-wins parse of `CLAUDEPIT_VERIFY: pass|fail`.
    public static func parseVerify(from output: String) -> Bool? {
        guard let val = lastMarker(in: output, marker: "CLAUDEPIT_VERIFY:")?.lowercased() else { return nil }
        if val == "pass" { return true }
        if val == "fail" { return false }
        return nil
    }

    // MARK: - helpers

    private static func lastMarker(in output: String, marker: String) -> String? {
        var found: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let r = line.range(of: marker) {
                found = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return (found?.isEmpty == false) ? found : nil
    }

    /// Deterministic 32-bit FNV-1a hex (Swift's hashValue is per-run randomized — unusable for stable ids).
    static func fnv1aHex(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(h, radix: 16)
    }
}
