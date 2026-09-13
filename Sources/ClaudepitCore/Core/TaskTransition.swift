import Foundation

public enum TaskTransition {
    /// Last-marker-wins parse of `CLAUDEPIT_ARTIFACT: <path>`.
    public static func parseArtifact(from output: String) -> String? {
        lastMarker(in: output, marker: "CLAUDEPIT_ARTIFACT:")
    }

    /// The deterministic deliverable a phase writes, matching the defaults `TaskRunner.phasePrompt`
    /// hands the agent. nil for phases that choose their own filename (`createPlan` writes under
    /// `plansDir`) or write no file at all (`implement`) — those are only discoverable from the
    /// agent's `CLAUDEPIT_ARTIFACT:` marker.
    public static func expectedArtifact(phase: TaskPhase?, projectSlug: String, taskID: String,
                                         projectsRoot: URL = Paths.projectsRoot) -> URL? {
        let dir = projectsRoot.appending(path: projectSlug).appending(path: "tasks").appending(path: taskID)
        switch phase {
        case .brainstorm: return dir.appending(path: "brainstorm.yaml")
        case .writeSpec:  return dir.appending(path: "spec.md")
        case .codeReview: return dir.appending(path: "review.md")
        case .createPlan, .implement, .none: return nil
        }
    }

    /// Point a task's links at any deterministic deliverable that exists on disk but was never
    /// recorded. Returns nil when nothing changed.
    ///
    /// The runner records links from the agent's scrollback marker when a phase lands, and that can
    /// miss: a phase that finished after the app stopped observing it (or one the runner landed
    /// early, before the file was written) leaves `specPath`/`reviewPath` nil with the file sitting
    /// right there — and the detail view's "Review spec" button disabled for an artifact that
    /// plainly exists. Checked for EVERY phase, not just the current one, so a task that has since
    /// moved on still heals its earlier links.
    public static func healArtifactLinks(_ task: ProjectTask, projectSlug: String,
                                          projectsRoot: URL = Paths.projectsRoot) -> ProjectTask? {
        func existing(_ phase: TaskPhase) -> String? {
            guard let u = expectedArtifact(phase: phase, projectSlug: projectSlug, taskID: task.id, projectsRoot: projectsRoot),
                  FileManager.default.fileExists(atPath: u.path) else { return nil }
            return u.path
        }
        var t = task
        if t.links.brainstormPath == nil { t.links.brainstormPath = existing(.brainstorm) }
        if t.links.specPath == nil       { t.links.specPath = existing(.writeSpec) }
        if t.links.reviewPath == nil     { t.links.reviewPath = existing(.codeReview) }
        // Adopt (or upgrade) findings from review.md. A phase that landed before the file was
        // written recorded none at all, and a task whose findings came from the old scrollback
        // format holds one truncated sentence each — re-reading the file gives both the structured
        // version, without waiting for a re-review.
        if let p = t.links.reviewPath, let text = try? String(contentsOfFile: p, encoding: .utf8) {
            let parsed = parseFindings(from: text)
            let haveStructure = t.links.reviewFindings.contains { $0.isStructured }
            if !parsed.isEmpty, t.links.reviewFindings.isEmpty || (!haveStructure && parsed.contains { $0.isStructured }) {
                t.links.reviewFindings = mergeFindings(existing: t.links.reviewFindings, parsed: parsed)
            }
        }
        return t == task ? nil : t
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

    /// The id of another task holding this task's worktree with a live phase, if any.
    ///
    /// A fix task shares its parent's checkout, so two agents can be pointed at the same files —
    /// the parent re-running its review while the child edits them would corrupt both diffs.
    /// Matched on the standardized path, since one side may carry a symlinked or trailing-slash
    /// spelling of the same directory.
    public static func worktreeBusy(_ task: ProjectTask, allTasks: [ProjectTask]) -> String? {
        guard let path = task.worktree?.path else { return nil }
        let mine = URL(filePath: path).standardizedFileURL.path
        return allTasks.first { other in
            guard other.id != task.id, let p = other.worktree?.path else { return false }
            guard URL(filePath: p).standardizedFileURL.path == mine else { return false }
            return other.status == .running || other.status == .blocked
        }?.id
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
    ///
    /// Two formats, tried in order:
    ///  1. **JSON array** (current) — one object per finding with `title`, `severity`/`level`,
    ///     `what`, `why`, `fix`, `locations`, `category`, `ruleId`. Field names follow SARIF's
    ///     vocabulary where SARIF has an equivalent, so this converts mechanically to a real SARIF
    ///     run later; the three narrative fields are the ones SARIF has no first-class home for.
    ///  2. **`severity | title | detail` lines** (legacy) — kept so a review written by an older
    ///     command body, or by an agent that ignored the JSON instruction, still yields findings
    ///     rather than nothing.
    public static func parseFindings(from output: String) -> [ReviewFinding] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let begin = lines.firstIndex(where: { $0.contains("CLAUDEPIT_FINDINGS_BEGIN") }),
              let end = lines[begin...].firstIndex(where: { $0.contains("CLAUDEPIT_FINDINGS_END") }),
              begin < end else { return [] }
        let body = lines[(begin + 1)..<end]
        if let json = parseFindingsJSON(Array(body)) { return json }
        return parseFindingsLines(Array(body))
    }

    /// JSON array between the markers. Tolerates a ```json fence around it (agents add one by
    /// reflex) and returns nil — not an empty array — when the body simply isn't JSON, so the
    /// caller can fall through to the legacy parser.
    private static func parseFindingsJSON(_ body: [String]) -> [ReviewFinding]? {
        let stripped = body.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        let text = stripped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["), let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        var out: [ReviewFinding] = []
        for obj in raw {
            let title = str(obj["title"]) ?? ""
            guard !title.isEmpty else { continue }
            let what = str(obj["what"]), why = str(obj["why"]), fix = str(obj["fix"])
            let locations = (obj["locations"] as? [Any] ?? []).compactMap { loc -> FindingLocation? in
                if let s = loc as? String { return FindingLocation(s) }
                // Also accept the nested {file, line} shape, which is what SARIF itself uses.
                guard let d = loc as? [String: Any], let f = str(d["file"]) else { return nil }
                return FindingLocation(file: f, line: d["line"] as? Int)
            }
            // `detail` stays populated so every consumer that predates the structured fields —
            // and the fix task's brief — still reads something useful.
            let detail = [what, why.map { "Why: \($0)" }, fix.map { "Fix: \($0)" }]
                .compactMap { $0 }.joined(separator: "\n\n")
            out.append(ReviewFinding(
                id: findingID(title: title, locations: locations, detail: detail),
                title: title,
                detail: detail.isEmpty ? title : detail,
                severity: normalizeSeverity(str(obj["severity"]) ?? str(obj["level"]) ?? "low"),
                ruleID: str(obj["ruleId"]) ?? str(obj["ruleID"]),
                category: str(obj["category"]),
                what: what, why: why, fix: fix,
                locations: locations.isEmpty ? nil : locations))
        }
        return out
    }

    /// Legacy `severity | title | detail`, one per line.
    private static func parseFindingsLines(_ body: [String]) -> [ReviewFinding] {
        var out: [ReviewFinding] = []
        for line in body {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 3 else { continue }
            let title = parts[1], detail = parts[2]
            guard !title.isEmpty else { continue }
            out.append(ReviewFinding(id: findingID(title: title, locations: [], detail: detail),
                                     title: title, detail: detail,
                                     severity: normalizeSeverity(parts[0])))
        }
        return out
    }

    /// Stable identity across re-reviews.
    ///
    /// Keyed on title + first location rather than title + full text: `spawnedTaskID` is matched by
    /// id in `mergeFindings`, so hashing the narrative would drop the "task created" link every time
    /// a reviewer reworded a sentence. Two same-titled findings in different files stay distinct;
    /// with no location at all it falls back to the detail, which is the old behaviour.
    static func findingID(title: String, locations: [FindingLocation], detail: String) -> String {
        let anchor = locations.first?.display ?? detail
        return fnv1aHex(title + "|" + anchor)
    }

    /// Accepts the report's Critical/Important/Minor vocabulary and SARIF's error/warning/note,
    /// and normalises both onto the high/med/low the rest of the app speaks.
    static func normalizeSeverity(_ raw: String) -> String {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "high", "critical", "error":      return "high"
        case "med", "medium", "important", "warning": return "med"
        default:                                return "low"
        }
    }

    private static func str(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Fold a fresh parse into the findings already on the task.
    ///
    /// A codeReview re-run re-parses the same findings — ids are content-hashed, so they match —
    /// and a wholesale assignment would forget which of them the user already turned into tasks.
    /// The new parse is the source of truth for what *exists* and for the text; `spawnedTaskID` is
    /// the one field carried over, because only the app ever sets it.
    public static func mergeFindings(existing: [ReviewFinding],
                                     parsed: [ReviewFinding]) -> [ReviewFinding] {
        let spawned = Dictionary(existing.map { ($0.id, $0.spawnedTaskID) },
                                 uniquingKeysWith: { a, b in a ?? b })
        return parsed.map { f in
            var out = f
            if out.spawnedTaskID == nil { out.spawnedTaskID = spawned[f.id] ?? nil }
            return out
        }
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
