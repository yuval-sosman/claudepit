import Foundation

/// A markdown document as a page lists it — a plan, a spec. The Plans and Specs pages are one
/// design over two sources, so they share this type, its loader and its search.
///
/// Plan mode names its files with a random slug (`glowing-crafting-pike.md`), so a plan's title
/// is its own first heading; a spec is named by its task. `tag` is what identifies the file
/// besides its title — a plan's slug, a spec's task id.
public struct MarkdownDoc: Identifiable, Equatable, Sendable {
    public let url: URL
    /// The name a list shows: given by the source (a spec's task), else the first heading, else
    /// the file's stem made readable.
    public let title: String
    /// The first paragraph of prose under the title — what the document is about, in one glance.
    public let summary: String?
    public let tag: String
    public let text: String
    public let modifiedAt: Date
    public let bytes: Int
    public let words: Int

    public var id: URL { url }

    public init(url: URL, text: String, modifiedAt: Date, title: String? = nil, tag: String? = nil) {
        self.url = url
        self.text = text
        self.modifiedAt = modifiedAt
        self.bytes = text.utf8.count
        self.words = text.split(whereSeparator: \.isWhitespace).count
        let stem = url.deletingPathExtension().lastPathComponent
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
            ?? MarkdownOutline.title(of: text) ?? MarkdownOutline.humanize(slug: stem)
        self.tag = tag ?? stem
        self.summary = MarkdownOutline.summary(of: text)
    }

    /// Every word of `query` appears in the title, the tag or the text. Empty matches all.
    public func matches(_ query: String) -> Bool {
        SearchText.matches([title, tag, text], query: query)
    }
}

/// Lists documents newest first, re-reading only files whose size or date changed since the last
/// call — the app reloads on every file-watcher tick.
public final class MarkdownDocLoader {
    /// One file to list, with the title and tag its page gives it (nil: derive them).
    public struct Source: Equatable {
        public let url: URL
        public let title: String?
        public let tag: String?
        public init(url: URL, title: String? = nil, tag: String? = nil) {
            self.url = url; self.title = title; self.tag = tag
        }
    }

    private struct Stamp: Equatable { let modified: Date; let size: Int; let source: Source }
    private var cache: [String: (stamp: Stamp, doc: MarkdownDoc)] = [:]

    public init() {}

    public func load(_ sources: [Source]) -> [MarkdownDoc] {
        let fm = FileManager.default
        var fresh: [String: (stamp: Stamp, doc: MarkdownDoc)] = [:]
        for source in sources {
            let url = source.url
            // attributesOfItem, not resourceValues: a URL's resource values can be cached.
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            let stamp = Stamp(modified: modified, size: (attrs[.size] as? Int) ?? 0, source: source)
            if let hit = cache[url.path], hit.stamp == stamp {
                fresh[url.path] = hit
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                fresh[url.path] = (stamp, MarkdownDoc(url: url, text: text, modifiedAt: modified,
                                                      title: source.title, tag: source.tag))
            }
        }
        cache = fresh
        return fresh.values.map(\.doc).sorted {
            $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.tag < $1.tag
        }
    }

    /// Plans: every `.md` file directly in `dir` (`~/.claude/plans`), tagged by its slug.
    public func loadPlans(dir: URL) -> [MarkdownDoc] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
        return load(names.map { Source(url: dir.appending(path: $0)) })
    }

    /// Specs: every `<task-id>/spec.md` under `tasksRoot` — orphaned task folders included, which
    /// a task's `links.specPath` can never reach — named by its task (`taskNames`, keyed by id),
    /// else its own heading, and tagged by the task id.
    public func loadSpecs(tasksRoot: URL, taskNames: [String: String]) -> [MarkdownDoc] {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: tasksRoot.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        return load(ids.map { id in
            Source(url: tasksRoot.appending(path: id).appending(path: "spec.md"), title: taskNames[id], tag: id)
        })
    }
}

/// Reads the shape of a markdown document without rendering it: its title and its opening line
/// of prose. Used for plans, and for memory files that carry no `description`.
public enum MarkdownOutline {
    /// The first `#` heading outside a code fence (after any frontmatter), else the first heading
    /// of any level. Inline markup is stripped.
    public static func title(of markdown: String) -> String? {
        var firstAny: String?
        for line in proseLines(markdown) {
            guard let (level, text) = heading(line) else { continue }
            if level == 1 { return text }
            if firstAny == nil { firstAny = text }
        }
        return firstAny
    }

    /// The first paragraph (or first list item) that is not a heading, fence, table or rule,
    /// flattened to plain text and capped at `limit` characters. A byline opening the document —
    /// one short line of `·`-separated facts, like a spec's "Task `56cf65b6` · 2026-09-13" — is
    /// skipped: it says nothing about what the document is.
    public static func summary(of markdown: String, limit: Int = 280) -> String? {
        var paragraph: [String] = []
        var first = true
        func isByline(_ p: [String]) -> Bool { p.count == 1 && p[0].count <= 120 && p[0].contains(" · ") }
        for line in proseLines(markdown) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let structural = t.isEmpty || heading(line) != nil || t.hasPrefix("|") || t.hasPrefix(">")
                || isRule(t) || t.hasPrefix("<")
            if structural {
                if !paragraph.isEmpty {
                    if first && isByline(paragraph) { paragraph = []; first = false; continue }
                    break
                }
                continue
            }
            if let item = listItem(t) {
                if paragraph.isEmpty { paragraph = [item] }
                break
            }
            paragraph.append(t)
        }
        guard !paragraph.isEmpty, !(first && isByline(paragraph)) else { return nil }
        let flat = plain(paragraph.joined(separator: " "))
        guard !flat.isEmpty else { return nil }
        return truncate(flat, limit: limit)
    }

    /// `glowing-crafting-pike` → "Glowing crafting pike".
    public static func humanize(slug: String) -> String {
        let spaced = slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Bold, italics, code ticks and link targets removed; whitespace collapsed.
    public static func plain(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`"] { out = out.replacingOccurrences(of: mark, with: "") }
        out = out.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])"#, with: "$1",
                                       options: .regularExpression)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func truncate(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.—-")) + "…"
    }

    /// The document's lines minus a leading frontmatter block and anything inside code fences.
    private static func proseLines(_ markdown: String) -> [String] {
        var lines = markdown.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = Array(lines[(close + 1)...])
        }
        var out: [String] = []
        var inFence = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); out.append(""); continue }
            out.append(inFence ? "" : line)
        }
        return out
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        var text = String(t.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        let clean = plain(text)
        return clean.isEmpty ? nil : (hashes, clean)
    }

    private static func listItem(_ t: String) -> String? {
        for bullet in ["- ", "* ", "+ "] where t.hasPrefix(bullet) {
            var item = String(t.dropFirst(2))
            for box in ["[ ] ", "[x] ", "[X] "] where item.hasPrefix(box) { item = String(item.dropFirst(4)) }
            return item
        }
        if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty,
           t[t.index(after: dot)...].first == " " {
            return String(t[t.index(dot, offsetBy: 2)...])
        }
        return nil
    }

    private static func isRule(_ t: String) -> Bool {
        t.count >= 3 && (Set(t) == ["-"] || Set(t) == ["*"] || Set(t) == ["_"])
    }
}

/// Word search shared by the Plans and Memory lists, plus the excerpt a row shows when the match
/// is somewhere its title and summary don't reveal.
public enum SearchText {
    /// Every whitespace-separated word of `query` occurs in at least one field. Empty matches all.
    public static func matches(_ fields: [String], query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { w in fields.contains { $0.localizedCaseInsensitiveContains(w) } }
    }

    /// A one-line excerpt of `text` around the first word of `query` that `visible` doesn't
    /// already show — nil when every word is already visible, or none occurs in `text`.
    public static func snippet(in text: String, query: String, visible: [String], radius: Int = 48) -> String? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let word = words.first(where: { w in !visible.contains { $0.localizedCaseInsensitiveContains(w) } }),
              let hit = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        var start = text.index(hit.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(hit.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        // Cut at word boundaries, so the excerpt never opens or closes on half a word.
        if start > text.startIndex, let space = text[start..<hit.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        if end < text.endIndex, let space = text[hit.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        var excerpt = MarkdownOutline.plain(String(text[start..<end]).replacingOccurrences(of: "#", with: ""))
        if start > text.startIndex { excerpt = "…" + excerpt }
        if end < text.endIndex { excerpt += "…" }
        return excerpt
    }
}
