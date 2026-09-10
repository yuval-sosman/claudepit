import SwiftUI
import ClaudepitCore

struct ReviewChangesSheet: View {
    let source: ChangeSource
    var onCommitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var files: [StagedFile] = []
    @State private var focused: (path: String, staged: Bool, untracked: Bool)? = nil
    @State private var hunks: [DiffHunk] = []
    @State private var fileHeader: [String] = []
    @State private var loadingDiff = false
    @State private var treeView = true
    @State private var commitMessage = ""
    @State private var errorText: String?
    @State private var busy = false
    @State private var pendingDiscard: (() async -> Void)? = nil
    @State private var confirmDiscard = false

    private var staged: [StagedFile]  { files.filter { $0.staged } }
    private var unstaged: [StagedFile] { files.filter { $0.unstaged } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if let e = errorText {
                Text(e).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
            }
            HStack(spacing: 0) {
                fileList.frame(minWidth: 260, maxWidth: 340, maxHeight: .infinity)
                Divider().opacity(0.2)
                diffPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.2)
            commitBar
        }
        .background(.ultraThinMaterial)
        .task { await reload() }
        .alert("Discard changes?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { Task { await pendingDiscard?() } }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("This permanently deletes the selected uncommitted changes.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 15)).foregroundStyle(Color.accentColor)
            Text("Source Control").font(.headline)
            Text("·").foregroundStyle(.secondary)
            Text(source.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { treeView.toggle() } label: {
                Image(systemName: treeView ? "list.bullet.indent" : "list.bullet")
                    .foregroundStyle(.secondary)
            }.buttonStyle(.plain).help(treeView ? "Show as list" : "Show as tree")
            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Refresh")
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !staged.isEmpty {
                    groupHeader("STAGED CHANGES", count: staged.count) {
                        Button("Unstage All") { run { for f in staged { _ = await source.unstageFile(path: f.path) }; return (true, "") } }
                            .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                    fileRows(staged, staged: true)
                }
                if !unstaged.isEmpty {
                    groupHeader("CHANGES", count: unstaged.count) {
                        Button("Discard All") { askDiscardAll() }
                            .font(.caption2).foregroundStyle(.red).buttonStyle(.plain)
                        Button("Stage All") { run { for f in unstaged { _ = await source.stageFile(path: f.path) }; return (true, "") } }
                            .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                    fileRows(unstaged, staged: false)
                }
                if files.isEmpty {
                    Text("No changes").font(.caption).foregroundStyle(.secondary).padding(12)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func groupHeader(_ title: String, count: Int, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).fontWeight(.bold).foregroundStyle(.secondary).tracking(0.6)
            Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            actions()
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    }

    // Flat list now; tree grouping added in the tree branch below.
    @ViewBuilder private func fileRows(_ list: [StagedFile], staged: Bool) -> some View {
        if treeView {
            ForEach(treeGroups(list), id: \.0) { dir, items in
                if !dir.isEmpty {
                    Text(dir).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .padding(.horizontal, 14).padding(.top, 4)
                }
                ForEach(items) { f in fileRow(f, staged: staged, indent: dir.isEmpty ? 0 : 12) }
            }
        } else {
            ForEach(list) { f in fileRow(f, staged: staged, indent: 0) }
        }
    }

    /// Group files by their parent directory for the tree view. ponytail: one
    /// level of folder grouping — full nested tree only if a real repo needs it.
    private func treeGroups(_ list: [StagedFile]) -> [(String, [StagedFile])] {
        var byDir: [String: [StagedFile]] = [:]
        for f in list {
            let dir = (f.path as NSString).deletingLastPathComponent
            byDir[dir, default: []].append(f)
        }
        return byDir.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func fileRow(_ f: StagedFile, staged: Bool, indent: CGFloat) -> some View {
        let isFocused = focused?.path == f.path && focused?.staged == staged
        return HStack(spacing: 6) {
            Text(badge(f.change)).font(.caption2.monospaced().bold())
                .foregroundStyle(badgeColor(f.change)).frame(width: 14)
            Text(treeView ? (f.path as NSString).lastPathComponent : f.path)
                .font(.caption.monospaced())
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if staged {
                iconButton("minus.circle", "Unstage") { run { await source.unstageFile(path: f.path) } }
            } else {
                iconButton("plus.circle", "Stage") { run { await source.stageFile(path: f.path) } }
            }
            iconButton("arrow.uturn.backward.circle", "Discard") {
                askDiscard { await source.discardFile(path: f.path, untracked: f.untracked) }
            }
        }
        .padding(.leading, 10 + indent).padding(.trailing, 10).padding(.vertical, 5)
        .background(isFocused ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { focused = (f.path, staged, f.untracked); Task { await loadDiff() } }
        .padding(.horizontal, 4)
    }

    private var diffPanel: some View {
        Group {
            if loadingDiff {
                ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if focused == nil {
                Text("Select a file to view its diff")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hunks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No diff").font(.subheadline).foregroundStyle(.secondary)
                    Text("Binary, untracked, or empty diff.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(hunks) { hunk in hunkView(hunk) }
                    }.padding(8)
                }
            }
        }
    }

    // Hunk toolbar: focused file's staged flag decides direction.
    private func hunkView(_ hunk: DiffHunk) -> some View {
        let path = focused?.path ?? ""
        let isStaged = focused?.staged ?? false
        let patch = buildPatch(fileHeader: fileHeader, hunk: hunk)
        let raw = ([hunk.header] + hunk.lines).joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(hunkRangeLabel(hunk.header)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                if isStaged {
                    hunkButton("Unstage Block") { run { await source.applyHunk(patch: patch, reverse: true, cached: true) } }
                } else {
                    hunkButton("Stage Block") { run { await source.applyHunk(patch: patch, reverse: false, cached: true) } }
                    hunkButton("Discard Block") {
                        askDiscard { await source.applyHunk(patch: patch, reverse: true, cached: false) }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            DiffView(lines: diffLinesFromUnified(raw, path: path),
                     isSwift: path.hasSuffix(".swift"), isMarkdown: path.hasSuffix(".md"),
                     language: GenericHighlighter.language(forExtension: (path as NSString).pathExtension))
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var commitBar: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if source.needsCommitMessage {
                ZStack(alignment: .topLeading) {
                    // Invisible text drives height: min 2 lines, max 5 lines
                    Text(commitMessage.isEmpty ? "Commit message…" : commitMessage)
                        .font(.body)
                        .padding(.horizontal, 8).padding(.vertical, 10)
                        .lineLimit(2...5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(0)
                    if commitMessage.isEmpty {
                        Text("Commit message…")
                            .font(.body).foregroundStyle(.tertiary)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $commitMessage)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 1))
            }

            Button {
                busy = true
                Task {
                    let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    let r = await source.commit(message: msg)
                    busy = false
                    if r.ok { onCommitted(); dismiss() }
                    else { errorText = r.message.isEmpty ? "\(source.commitVerb) failed" : r.message }
                }
            } label: {
                Label(source.commitVerb, systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy
                || (source.needsCommitMessage
                    && (staged.isEmpty || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.white.opacity(0.04))
    }

    // MARK: - Actions
    private func run(_ op: @escaping () async -> (ok: Bool, message: String)) {
        busy = true
        Task {
            let r = await op()
            if !r.ok { errorText = r.message.isEmpty ? "git command failed" : r.message }
            else { errorText = nil }
            await reload()
            busy = false
        }
    }

    private func askDiscardAll() {
        let files = unstaged
        askDiscard {
            var lastResult: (ok: Bool, message: String) = (true, "")
            for f in files { lastResult = await source.discardFile(path: f.path, untracked: f.untracked) }
            return lastResult
        }
    }

    private func askDiscard(_ op: @escaping () async -> (ok: Bool, message: String)) {
        pendingDiscard = { run(op) }
        confirmDiscard = true
    }

    private func iconButton(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system).font(.caption2).foregroundStyle(.secondary) }
            .buttonStyle(.plain).help(help).disabled(busy)
    }

    private func hunkButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(.caption2)
            .foregroundStyle(Color.accentColor).disabled(busy)
    }

    /// Turn a raw `@@ -a,b +c,d @@` header into a plain "Lines c–end" label.
    /// If a section heading trails the second `@@` (git allows it — brainstorm uses
    /// "<KindDir> · <id>"), show that instead, dropping the " · <id>" bookkeeping.
    /// Falls back to the raw header if it doesn't parse.
    private func hunkRangeLabel(_ header: String) -> String {
        if let close = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex) {
            let heading = header[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty {
                return heading.range(of: " · ").map { String(heading[..<$0.lowerBound]) } ?? heading
            }
        }
        // "@@ -a,b +c,d @@" — we want the new-side range (c, d).
        guard let plus = header.range(of: "+") else { return header }
        let after = header[plus.upperBound...]
        let nums = after.prefix { $0 != " " && $0 != "@" }
        let parts = nums.split(separator: ",")
        guard let start = Int(parts.first ?? "") else { return header }
        let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        let end = start + max(count, 1) - 1
        return start == end ? "Line \(start)" : "Lines \(start)–\(end)"
    }

    // MARK: - Data
    private func reload() async {
        files = await source.status()
        if let f = focused, !files.contains(where: { $0.path == f.path }) { focused = nil; hunks = [] }
        await loadDiff()
    }

    private func loadDiff() async {
        guard let f = focused else { hunks = []; return }
        loadingDiff = true; defer { loadingDiff = false }
        let raw = await source.diff(path: f.path, staged: f.staged, untracked: f.untracked)
        let parsed = parseHunks(raw)
        fileHeader = parsed.fileHeader; hunks = parsed.hunks
    }

    private func badge(_ c: ChangedFile.Change) -> String {
        switch c { case .modified: "M"; case .added: "A"; case .deleted: "D"; case .renamed: "R"; case .untracked: "?" }
    }
    private func badgeColor(_ c: ChangedFile.Change) -> Color {
        switch c { case .added, .untracked: .green; case .deleted: .red; case .renamed: .blue; case .modified: .orange }
    }
}
