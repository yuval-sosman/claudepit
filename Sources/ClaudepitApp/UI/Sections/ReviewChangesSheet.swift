import SwiftUI
import AppKit
import ClaudepitCore

/// Source Control: a worktree's changes (or a task's brainstorm suggestions — same UI over
/// `ChangeSource`) as a file list beside the selected file's diff, with stage / unstage / discard
/// per file and per block, merge-conflict resolution, and a commit bar.
///
/// Keys: Esc closes; ⌘↩ commits; ⌘R refreshes; in the list ↑/↓ move, Space stages or unstages
/// (marks a conflict resolved), ⌫ discards (asks first). It also refreshes on its own — every few
/// seconds and when the app comes back to the front — because the usual reason to have it open is
/// an agent, or an editor, changing the files.
struct ReviewChangesSheet: View {
    let source: ChangeSource
    var onCommitted: () -> Void

    typealias FileRef = ChangeSelection

    /// The selected file's diff, tagged with the selection it was loaded for: rows for one file
    /// must never sit under another's name, where a block button would act on them.
    struct LoadedDiff {
        let ref: FileRef
        let raw: String
        let fileHeader: [String]
        let hunks: [DiffHunk]
        let binary: Bool
        /// Set (to the byte count) when the diff is too big to draw unasked.
        let tooLarge: Int?
        /// A conflicted file's text split at its markers.
        let conflict: ConflictDocument?
        /// An image's two versions — the before is git's copy, the after git's or the disk's.
        var images: (before: NSImage?, after: NSImage?)? = nil
    }

    struct Confirmation {
        let title: String
        let message: String
        let button: String
        var destructive = true
        let action: () -> Void
    }

    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @Environment(\.sourceControlAutoConfirm) private var autoConfirm
    @Environment(\.sourceControlProbe) private var probe
    #endif
    @State private var files: [StagedFile] = []
    @State private var loaded = false
    @State private var context = ChangeContext()
    @State private var focused: FileRef?
    @State private var diff: LoadedDiff?
    @State private var largeDiffAllowed: FileRef?
    @AppStorage("sourceControlTreeView") private var treeView = true
    @State private var commitMessage = ""
    @State private var prefilledMerge = false
    @State private var errorText: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var confirmation: Confirmation?
    @State private var reloadGeneration = 0
    @FocusState private var listFocused: Bool

    /// Above this a diff waits for "Show anyway": parsing and laying out tens of thousands of
    /// lines (a generated file, a lockfile) stalls the sheet.
    private static let largeDiffBytes = 1_500_000

    private var conflicts: [StagedFile] { files.filter { $0.conflict != nil } }
    private var staged: [StagedFile]  { files.filter { $0.staged } }
    private var unstaged: [StagedFile] { files.filter { $0.unstaged } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            banners
            HStack(spacing: 0) {
                fileList.frame(minWidth: 280, maxWidth: 360, maxHeight: .infinity)
                Divider().opacity(0.2)
                diffPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.2)
            commitBar
        }
        .background(.ultraThinMaterial)
        .task {
            if let key = source.draftKey, let draft = CommitDrafts.store[key] { commitMessage = draft }
            await reload()
        }
        .onChange(of: commitMessage) { _, new in
            guard let key = source.draftKey else { return }
            CommitDrafts.store[key] = new.isEmpty ? nil : new
        }
        // A loop owned by the sheet, not a `Timer.publish` stored on the view: the host page
        // re-renders on its own clock, re-creating this struct — and with it a stored timer,
        // whose countdown would restart each time and might never fire.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await quietRefresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        #if DEBUG
        .onChange(of: probeState, initial: true) { _, state in probe?(state) }
        #endif
        .alert(confirmation?.title ?? "", isPresented: confirmationBinding, presenting: confirmation) { c in
            Button(c.button, role: c.destructive ? .destructive : nil) { c.action() }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }

    #if DEBUG
    private var probeState: SourceControlProbeState {
        SourceControlProbeState(focused: focused, files: files, diffRef: currentDiff?.ref,
                                hunks: currentDiff?.hunks.count ?? 0, conflicts: currentDiff?.conflict?.conflicts.count,
                                images: [currentDiff?.images?.before, currentDiff?.images?.after].compactMap { $0 }.count,
                                commitMessage: commitMessage, merging: context.merging,
                                notice: notice, error: errorText, busy: busy)
    }
    #endif

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 15)).foregroundStyle(Color.accentColor)
            Text("Source Control").font(.headline)
            Text("·").foregroundStyle(.secondary)
            Text(source.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                .layoutPriority(-1)
            if let branch = context.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.white.opacity(0.07), in: Capsule())
                    .help("Commits go to \(branch)")
                    .layoutPriority(-2)
            }
            if busy { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if !files.isEmpty {
                HStack(spacing: 6) {
                    Text(summaryText).font(.caption).foregroundStyle(.tertiary)
                    LineStatText(stat: totalStat, font: .caption.monospacedDigit())
                }
                .fixedSize()
            }
            Button { treeView.toggle() } label: {
                Image(systemName: treeView ? "list.bullet.indent" : "list.bullet")
                    .foregroundStyle(.secondary)
            }.buttonStyle(.plain).help(treeView ? "Show as list" : "Show as tree")
            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var summaryText: String {
        let n = Set(files.map(\.path)).count
        return "\(n) file\(n == 1 ? "" : "s") changed"
    }

    private var totalStat: LineStat? {
        let stats = files.flatMap { [$0.stagedStat, $0.unstagedStat] }.compactMap { $0 }.filter { !$0.binary }
        guard !stats.isEmpty else { return nil }
        return LineStat(added: stats.map(\.added).reduce(0, +), removed: stats.map(\.removed).reduce(0, +))
    }

    @ViewBuilder private var banners: some View {
        if context.merging || !conflicts.isEmpty {
            SourceControlBanner(tone: conflicts.isEmpty ? .success : .warning, text: mergeBannerText) {
                if context.merging {
                    Button("Abort Merge…") { askAbortMerge() }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                        .disabled(busy)
                        .help("git merge --abort — back to how the branch was before the merge")
                        .debugFrame("sc-abort-merge")
                }
            }
        }
        if let e = errorText {
            SourceControlBanner(tone: .error, text: e, onDismiss: { errorText = nil })
        }
        if let n = notice {
            SourceControlBanner(tone: .success, text: n, onDismiss: { notice = nil })
        }
    }

    private var mergeBannerText: String {
        let n = conflicts.count
        let files = "\(n) conflicted file\(n == 1 ? "" : "s")"
        if !context.merging { return "\(files) — resolve each, then mark it resolved." }
        return n == 0 ? "All conflicts resolved — commit to finish the merge."
                      : "Merge in progress — resolve \(files), then commit to finish it."
    }

    // MARK: File list

    private var fileList: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !conflicts.isEmpty {
                            SourceControlGroupHeader(title: ChangeList.conflicts.title, count: conflicts.count) {
                                Button("Mark All Resolved") { markResolved(conflicts) }
                                    .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain).disabled(busy)
                                    .help("Stage every conflicted file as it is now")
                                    .debugFrame("sc-mark-all-resolved")
                            }
                            fileRows(conflicts, list: .conflicts)
                        }
                        if !staged.isEmpty {
                            SourceControlGroupHeader(title: ChangeList.staged.title, count: staged.count) {
                                Button("Unstage All") { run { await source.unstage(staged) } }
                                    .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain).disabled(busy)
                                    .help("Move every staged change back to Changes")
                                    .debugFrame("sc-unstage-all")
                            }
                            fileRows(staged, list: .staged)
                        }
                        if !unstaged.isEmpty {
                            SourceControlGroupHeader(title: ChangeList.changes.title, count: unstaged.count) {
                                Button("Discard All") { askDiscard(unstaged, staged: false) }
                                    .font(.caption2).foregroundStyle(.red).buttonStyle(.plain).disabled(busy)
                                    .help("Throw away every unstaged change (asks first)")
                                    .debugFrame("sc-discard-all")
                                Button("Stage All") { run { await source.stage(unstaged) } }
                                    .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain).disabled(busy)
                                    .help("Stage every change for the commit")
                                    .debugFrame("sc-stage-all")
                            }
                            fileRows(unstaged, list: .changes)
                        }
                        if files.isEmpty && loaded {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("No changes", systemImage: "checkmark.circle")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text("Nothing is waiting to be committed.").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: focused) { _, f in
                    // Keyboard steps keep the row in view; a click is already on screen.
                    if let f { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rowID(f)) } }
                }
            }
            if !files.isEmpty {
                Divider().opacity(0.15)
                Text(source.needsCommitMessage ? "↑↓ files · Space stage · ⌫ discard · ⌘↩ commit" : "↑↓ · Space accept · ⌫ dismiss")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            let delta: Int
            switch press.key {
            case .upArrow: delta = -1
            case .downArrow: delta = 1
            default: return .ignored
            }
            if let next = PageListKeys.step(focused, by: delta, in: displayOrder) { select(next) }
            return .handled
        }
        .onKeyPress(.space) {
            guard !busy, let f = focused, let file = file(for: f) else { return .ignored }
            primaryAction(file, ChangeList(f))
            return .handled
        }
        // The Delete key never reaches onKeyPress — it arrives as deleteBackward:.
        .onDeleteCommand {
            guard !busy, let f = focused, !f.conflicted, let file = file(for: f) else { return }
            askDiscard([file], staged: f.staged)
        }
    }

    /// Every row in the order the lists draw them — what ↑/↓ walks.
    private var displayOrder: [FileRef] {
        ordered(conflicts).map { ref($0, .conflicts) }
            + ordered(staged).map { ref($0, .staged) }
            + ordered(unstaged).map { ref($0, .changes) }
    }

    private func ref(_ f: StagedFile, _ list: ChangeList) -> FileRef {
        FileRef(path: f.path, staged: list == .staged, untracked: f.untracked, conflicted: list == .conflicts)
    }

    private func rowID(_ f: FileRef) -> String { "\(ChangeList(f).rawValue)/\(f.path)" }

    private func file(for ref: FileRef) -> StagedFile? {
        files.first { $0.path == ref.path && (ref.conflicted ? $0.conflict != nil : (ref.staged ? $0.staged : $0.unstaged)) }
    }

    private func ordered(_ list: [StagedFile]) -> [StagedFile] {
        treeView ? treeGroups(list).flatMap(\.1) : list
    }

    @ViewBuilder private func fileRows(_ list: [StagedFile], list kind: ChangeList) -> some View {
        if treeView {
            ForEach(treeGroups(list), id: \.0) { dir, items in
                if !dir.isEmpty {
                    Label(dir, systemImage: "folder")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1).truncationMode(.head)
                        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 1)
                }
                ForEach(items) { f in fileRow(f, kind, indent: dir.isEmpty ? 0 : 12) }
            }
        } else {
            ForEach(list) { f in fileRow(f, kind, indent: 0) }
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

    private func fileRow(_ f: StagedFile, _ list: ChangeList, indent: CGFloat) -> some View {
        let r = ref(f, list)
        return SourceControlFileRow(
            file: f, list: list,
            name: treeView ? (f.path as NSString).lastPathComponent : f.path,
            indent: indent, isSelected: focused == r, listFocused: listFocused, busy: busy,
            onSelect: { select(r); listFocused = true },
            onPrimary: { primaryAction(f, list) },
            onDiscard: list == .conflicts ? nil : { askDiscard([f], staged: list == .staged) }
        ) {
            rowMenu(f, list)
        }
        .id(rowID(r))
    }

    @ViewBuilder private func rowMenu(_ f: StagedFile, _ list: ChangeList) -> some View {
        switch list {
        case .conflicts:
            Button("Mark Resolved") { markResolved([f]) }
            Button("Use Current Version…") { askTakeSide(f, .current) }
            Button("Use Incoming Version…") { askTakeSide(f, .incoming) }
            Button("Delete File", role: .destructive) { askDeleteConflicted(f) }
        case .staged:
            Button("Unstage") { run { await source.unstage([f]) } }
            Button("Discard All Changes…", role: .destructive) { askDiscard([f], staged: true) }
        case .changes:
            Button("Stage") { run { await source.stage([f]) } }
            Button(f.untracked ? "Move to Trash…" : "Discard Changes…", role: .destructive) { askDiscard([f], staged: false) }
        }
        if let url = source.fileURL(path: f.path) {
            Divider()
            if FileManager.default.fileExists(atPath: url.path) {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Copy Path") { copy(url.path) }
            Button("Copy Relative Path") { copy(f.path) }
        }
    }

    // MARK: Diff

    private var currentDiff: LoadedDiff? {
        guard let d = diff, d.ref == focused else { return nil }
        return d
    }

    private var diffPanel: some View {
        VStack(spacing: 0) {
            if let f = focused, let file = file(for: f) {
                diffHeader(file, f)
                Divider().opacity(0.15)
            }
            Group {
                if focused == nil {
                    emptyPanel
                } else if let d = currentDiff {
                    loadedPanel(d)
                } else {
                    ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var emptyPanel: some View {
        VStack(spacing: 8) {
            if files.isEmpty && loaded {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(TranscriptStyle.added.opacity(0.8))
                Text("Working tree clean").font(.subheadline).foregroundStyle(.secondary)
                if let n = notice { Text(n).font(.caption).foregroundStyle(.tertiary) }
            } else if loaded {
                Text("Select a file to view its diff").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func loadedPanel(_ d: LoadedDiff) -> some View {
        if d.ref.conflicted, let file = file(for: d.ref) {
            ConflictResolutionView(file: file, document: d.conflict, headHunks: d.hunks, busy: busy,
                                   actions: conflictActions(file, d))
        } else if let bytes = d.tooLarge {
            message(icon: "doc.text.magnifyingglass", "Large diff",
                    "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of changes — drawing them all is slow.") {
                Button("Show Anyway") { largeDiffAllowed = d.ref; Task { await loadDiff(force: true) } }
                    .buttonStyle(.bordered).controlSize(.small)
                openButton(d.ref.path)
            }
        } else if d.binary {
            binaryPanel(d)
        } else if d.hunks.isEmpty {
            message(icon: "doc.questionmark", "No diff",
                    d.ref.untracked ? "The file is empty." : "Only the file's mode or name changed, or it is empty.") {
                openButton(d.ref.path)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(d.hunks) { hunk in hunkView(hunk, d) }
                }
                .padding(8)
            }
        }
    }

    private func message<Buttons: View>(icon: String, _ title: String, _ detail: String,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            HStack(spacing: 8) { buttons() }.padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "icns"]

    @ViewBuilder private func binaryPanel(_ d: LoadedDiff) -> some View {
        if let images = d.images, images.before != nil || images.after != nil {
            let staged = file(for: d.ref)?.staged ?? false
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 20) {
                    if let before = images.before {
                        imageColumn(before, title: "Before", source: d.ref.staged ? "last commit" : (staged ? "staged" : "last commit"))
                    }
                    if images.before != nil && images.after != nil {
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    }
                    if let after = images.after {
                        imageColumn(after, title: images.before == nil ? "New" : "After", source: d.ref.staged ? "staged" : "on disk")
                    } else {
                        Text("Deleted").font(.caption).foregroundStyle(TranscriptStyle.removed)
                    }
                }
                openButton(d.ref.path)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            message(icon: "doc.zipper", "Binary file", "git has no text diff for it.") { openButton(d.ref.path) }
        }
    }

    /// One version of an image at its own size — doubled when tiny, never blown up past that
    /// (a 96-pixel icon stretched to fill the panel is a blur).
    private func imageColumn(_ image: NSImage, title: String, source: String) -> some View {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        let scale = min(w < 160 && h < 160 ? 2 : 1, 320 / w, 280 / h)
        return VStack(spacing: 6) {
            Image(nsImage: image).resizable().interpolation(scale > 1 ? .none : .high)
                .frame(width: w * scale, height: h * scale)
                .background(Color.black.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.1)))
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(source)").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func openButton(_ path: String) -> some View {
        if let url = source.fileURL(path: path), FileManager.default.fileExists(atPath: url.path) {
            Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// The selected file, which list it is in, and what can be done to all of it.
    private func diffHeader(_ file: StagedFile, _ f: FileRef) -> some View {
        HStack(spacing: 8) {
            if let kind = file.conflict { ConflictMark(kind: kind) } else { ChangeBadge(change: file.change) }
            Text((f.path as NSString).lastPathComponent).font(.callout.monospaced().weight(.semibold)).lineLimit(1)
            let dir = (f.path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                Text(dir).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            if let orig = file.origPath {
                Text("← \(orig)").font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    .help("Renamed from \(orig)")
            }
            listBadge(file, f)
            LineStatText(stat: f.conflicted ? nil : (f.staged ? file.stagedStat : file.unstagedStat), font: .caption.monospacedDigit())
            Spacer(minLength: 8)
            fileTools(f.path)
            if f.conflicted {
                EmptyView()
            } else if f.staged {
                SourceControlTextButton(title: "Unstage File", busy: busy) { run { await source.unstage([file]) } }
                    .debugFrame("sc-file-unstage")
                SourceControlTextButton(title: "Discard File", role: .destructive, busy: busy) { askDiscard([file], staged: true) }
                    .help("Throw away all of its changes, staged and unstaged (asks first)")
                    .debugFrame("sc-file-discard")
            } else {
                SourceControlTextButton(title: "Stage File", busy: busy) { run { await source.stage([file]) } }
                    .debugFrame("sc-file-stage")
                SourceControlTextButton(title: file.untracked ? "Move to Trash" : "Discard File", role: .destructive, busy: busy) {
                    askDiscard([file], staged: false)
                }
                .debugFrame("sc-file-discard")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// "Staged" / "Unstaged" / … — and for a file with changes in both lists, a switch between
    /// its two halves, so seeing what is left to stage doesn't mean finding its other row.
    @ViewBuilder private func listBadge(_ file: StagedFile, _ f: FileRef) -> some View {
        if file.staged && file.unstaged {
            HStack(spacing: 0) {
                halfButton("Staged", selected: f.staged) { select(FileRef(path: f.path, staged: true, untracked: false)) }
                    .debugFrame("sc-side-staged")
                halfButton("Unstaged", selected: !f.staged) { select(FileRef(path: f.path, staged: false, untracked: false)) }
                    .debugFrame("sc-side-unstaged")
            }
            .background(.white.opacity(0.06), in: Capsule())
            .help("This file has staged and unstaged changes — switch between them")
        } else {
            let text = f.conflicted ? "Conflict" : (f.staged ? "Staged" : (f.untracked ? "Untracked" : "Unstaged"))
            let tint: Color = f.conflicted ? .orange : (f.staged ? .green : .secondary)
            Text(text)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .foregroundStyle(tint)
                .background((f.staged || f.conflicted ? tint : Color.white).opacity(0.12), in: Capsule())
        }
    }

    private func halfButton(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 1.5)
                .foregroundStyle(selected ? (title == "Staged" ? Color.green : .primary) : .secondary)
                .background(selected ? Color.white.opacity(0.12) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Open, reveal and copy the selected file's path.
    @ViewBuilder private func fileTools(_ path: String) -> some View {
        if let url = source.fileURL(path: path) {
            HStack(spacing: 8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    toolIcon(Icon.openFile, "Open the file") { NSWorkspace.shared.open(url) }
                    toolIcon(Icon.revealInFinder, "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                CopyButton(text: path, help: "Copy the path", size: 10)
            }
            .padding(.trailing, 4)
        }
    }

    private func toolIcon(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system).font(.system(size: 10)).foregroundStyle(.secondary) }
            .buttonStyle(.plain).help(help)
    }

    // Hunk toolbar: the loaded diff's list decides direction.
    private func hunkView(_ hunk: DiffHunk, _ d: LoadedDiff) -> some View {
        let path = d.ref.path
        let patch = buildPatch(fileHeader: d.fileHeader, hunk: hunk)
        let file = file(for: d.ref)
        let buttons = HStack(spacing: 10) {
            if d.ref.staged {
                SourceControlTextButton(title: "Unstage Block", busy: busy) {
                    run { await source.applyHunk(patch: patch, reverse: true, cached: true) }
                }
                .debugFrame("sc-hunk-\(hunk.id)-unstage")
            } else {
                SourceControlTextButton(title: "Stage Block", busy: busy) {
                    // A new file is one block: staging it is staging the file, which also works
                    // for a source that can't apply patches.
                    if d.ref.untracked, let file { run { await source.stage([file]) } }
                    else { run { await source.applyHunk(patch: patch, reverse: false, cached: true) } }
                }
                .debugFrame("sc-hunk-\(hunk.id)-stage")
                SourceControlTextButton(title: "Discard Block", role: .destructive, busy: busy) {
                    if d.ref.untracked, let file { askDiscard([file], staged: false) }
                    else { askDiscardBlock(patch) }
                }
                .debugFrame("sc-hunk-\(hunk.id)-discard")
            }
        }
        .padding(.trailing, 6)
        // A source with no files on disk (brainstorm suggestions) has no line numbers worth showing.
        let lines = source.fileURL(path: path) == nil
            ? hunk.numberedLines().map { DiffLine(kind: $0.kind, text: $0.text) }
            : hunk.numberedLines()
        return DiffView(lines: lines,
                        isSwift: path.hasSuffix(".swift"), isMarkdown: path.hasSuffix(".md"),
                        language: GenericHighlighter.language(forExtension: (path as NSString).pathExtension),
                        title: hunk.label,
                        accessory: AnyView(buttons),
                        startsRendered: false)
    }

    private func conflictActions(_ file: StagedFile, _ d: LoadedDiff) -> ConflictResolutionView.Actions {
        let url = source.fileURL(path: file.path)
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return ConflictResolutionView.Actions(
            resolve: { index, block, choice in
                guard let url else { return }
                applyConflict { ConflictFileIO.resolve(url, index: index, expected: block, choice) }
            },
            resolveAll: { count, choice in
                guard let url else { return }
                applyConflict { ConflictFileIO.resolveAll(url, expected: count, choice) }
            },
            takeSide: { side in askTakeSide(file, side) },
            delete: { askDeleteConflicted(file) },
            markResolved: { markResolved([file]) },
            open: exists ? { NSWorkspace.shared.open(url!) } : nil)
    }

    // MARK: Commit

    private var trimmedMessage: String { commitMessage.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nothing staged, but changes waiting: the commit button stages them all first rather than
    /// sitting disabled with "stage the changes to commit".
    private var commitsEverything: Bool {
        source.needsCommitMessage && staged.isEmpty && !unstaged.isEmpty && conflicts.isEmpty && !context.merging
    }

    /// Why the commit button is off, said beside it — a dead button with no reason reads as a bug.
    private var commitBlocker: String? {
        guard source.needsCommitMessage else { return nil }
        if !conflicts.isEmpty {
            return "Resolve \(conflicts.count) conflicted file\(conflicts.count == 1 ? "" : "s") first"
        }
        // A merge can commit with nothing staged — taking this branch's side everywhere leaves
        // no changes, and the merge commit is still what finishes it.
        if staged.isEmpty && unstaged.isEmpty && !context.merging { return "Nothing to commit" }
        if trimmedMessage.isEmpty { return "Write a commit message" }
        return nil
    }

    private var subjectLength: Int {
        commitMessage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.count } ?? 0
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
                        Text(context.merging ? "Merge commit message…" : "Commit message…")
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
                .overlay(alignment: .bottomTrailing) {
                    // Git's convention: a summary line short enough to read in a log.
                    if subjectLength > 50 {
                        Text("\(subjectLength)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(subjectLength > 72 ? Color.orange : Color.secondary.opacity(0.6))
                            .padding(6)
                            .help(subjectLength > 72
                                  ? "The first line is \(subjectLength) characters — git logs read best under 72"
                                  : "First line: \(subjectLength) characters")
                    }
                }
            }

            HStack(spacing: 10) {
                if source.needsCommitMessage {
                    Text(stagedLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let commitBlocker {
                    Text(commitBlocker).font(.caption).foregroundStyle(.tertiary)
                }
                Button { commit() } label: {
                    Label(commitsEverything ? "Stage All & \(source.commitVerb)" : (context.merging ? "Commit Merge" : source.commitVerb),
                          systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help(commitsEverything ? "Stage all \(unstaged.count) changes and \(source.commitVerb.lowercased()) them (⌘↩)"
                                        : "\(source.commitVerb) (⌘↩)")
                .disabled(busy || commitBlocker != nil)
                .debugFrame("sc-commit")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.white.opacity(0.04))
    }

    private var stagedLine: String {
        if !staged.isEmpty { return "\(staged.count) file\(staged.count == 1 ? "" : "s") staged" }
        if commitsEverything { return "Nothing staged — this commits all \(unstaged.count) change\(unstaged.count == 1 ? "" : "s")" }
        return ""
    }

    private func commit() {
        let stageFirst = commitsEverything ? unstaged : []
        let message = trimmedMessage
        busy = true; errorText = nil; notice = nil
        Task {
            defer { busy = false }
            if !stageFirst.isEmpty {
                let s = await source.stage(stageFirst)
                if !s.ok { errorText = s.message.isEmpty ? "Staging failed" : s.message; await reload(); return }
            }
            let r = await source.commit(message: message)
            guard r.ok else {
                errorText = r.message.isEmpty ? "\(source.commitVerb) failed" : r.message
                await reload()
                return
            }
            if let key = source.draftKey { CommitDrafts.store[key] = nil }
            commitMessage = ""; prefilledMerge = false
            onCommitted()
            // Changes left behind (a partial commit): stay open on them and say what landed.
            // Nothing left — or a source with no commit to speak of — closes, as it always did.
            let remaining = await source.status()
            guard source.needsCommitMessage, !remaining.isEmpty else { dismiss(); return }
            if let head = await source.headCommit() {
                notice = "Committed \(head.shortHash) — \(head.subject)"
            } else {
                notice = "Committed"
            }
            await reload()
        }
    }

    // MARK: - Actions

    private func select(_ ref: FileRef) {
        guard focused != ref else { return }
        focused = ref
        Task { await loadDiff() }
    }

    private func primaryAction(_ f: StagedFile, _ list: ChangeList) {
        switch list {
        case .conflicts: markResolved([f])
        case .staged: run { await source.unstage([f]) }
        case .changes: run { await source.stage([f]) }
        }
    }

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

    /// A conflict resolution writes the file; a refusal means it changed under the view.
    private func applyConflict(_ op: @escaping () -> Result<Void, ConflictFileIO.Failure>) {
        run {
            switch op() {
            case .success: return (true, "")
            case .failure(.changed): return (false, "The file changed since it was shown — it has been reloaded; check it and choose again.")
            case .failure(.unreadable): return (false, "Couldn't read the file as text.")
            case .failure(.unwritable(let why)): return (false, "Couldn't write the file: \(why)")
            }
        }
    }

    /// Stage conflicted files; ask first when one still has conflict markers, which a plain
    /// `git add` would commit as content.
    private func markResolved(_ list: [StagedFile]) {
        let marked = list.filter { f in
            guard let url = source.fileURL(path: f.path) else { return false }
            return ConflictFileIO.load(url)?.hasConflicts ?? false
        }
        guard !marked.isEmpty else { run { await source.markResolved(list) }; return }
        let name = marked.count == 1 ? (marked[0].path as NSString).lastPathComponent : "\(marked.count) files"
        confirm(Confirmation(
            title: "\(name) still \(marked.count == 1 ? "has" : "have") conflict markers",
            message: "Marking \(marked.count == 1 ? "it" : "them") resolved stages the file as it is — the <<<<<<< and >>>>>>> lines included.",
            button: "Mark Resolved", destructive: false) { run { await source.markResolved(list) } })
    }

    private func askDiscard(_ list: [StagedFile], staged: Bool) {
        guard !list.isEmpty else { return }
        let one = list.count == 1 ? list[0] : nil
        let name = one.map { ($0.path as NSString).lastPathComponent }
        let trashed = list.filter { $0.untracked || (staged && ($0.change == .added || $0.origPath != nil)) }
        let title: String, message: String, button: String
        if let one, let name, one.untracked {
            title = "Move \(name) to the Trash?"
            message = "It's a new file git has no copy of. You can get it back from the Trash."
            button = "Move to Trash"
        } else if staged {
            title = name.map { "Discard all changes to \($0)?" } ?? "Discard all changes to \(list.count) files?"
            message = "Staged and unstaged changes are thrown away and \(one == nil ? "the files go" : "it goes") back to the last commit."
                + (trashed.isEmpty ? " This can't be undone." : " A file the last commit doesn't have moves to the Trash.")
            button = "Discard"
        } else {
            title = name.map { "Discard changes to \($0)?" } ?? "Discard all \(list.count) changes?"
            let tracked = list.count - trashed.count
            var parts: [String] = []
            if tracked > 0 {
                parts.append(one != nil ? "Its unstaged changes are permanently lost; anything staged is kept."
                                        : "Unstaged changes to \(tracked) file\(tracked == 1 ? "" : "s") are permanently lost; anything staged is kept.")
            }
            if !trashed.isEmpty { parts.append("\(trashed.count) new file\(trashed.count == 1 ? "" : "s") move\(trashed.count == 1 ? "s" : "") to the Trash.") }
            message = parts.joined(separator: " ")
            button = "Discard"
        }
        confirm(Confirmation(title: title, message: message, button: button) {
            run { await source.discard(list, staged: staged) }
        })
    }

    private func askDiscardBlock(_ patch: String) {
        confirm(Confirmation(title: "Discard this block?",
                             message: "These lines go back to how they were. This can't be undone.",
                             button: "Discard") {
            run { await source.applyHunk(patch: patch, reverse: true, cached: false) }
        })
    }

    /// The whole file from one side replaces whatever is on disk — including any resolution
    /// already typed into it — so it asks.
    private func askTakeSide(_ f: StagedFile, _ side: ConflictSide) {
        let name = (f.path as NSString).lastPathComponent
        confirm(Confirmation(title: "Replace \(name) with the \(side == .current ? "current" : "incoming") version?",
                             message: side == .current
                                ? "The file becomes this branch's version (git checkout --ours). The other side's changes to it, and anything resolved in it so far, are dropped."
                                : "The file becomes the incoming version (git checkout --theirs). This branch's changes to it, and anything resolved in it so far, are dropped.",
                             button: "Replace") {
            run { await source.takeSide(f, side) }
        })
    }

    private func askDeleteConflicted(_ f: StagedFile) {
        confirm(Confirmation(title: "Delete \((f.path as NSString).lastPathComponent)?",
                             message: "Resolves the conflict by deleting the file (git rm). The deletion is staged.",
                             button: "Delete") {
            run { await source.deleteConflicted(f) }
        })
    }

    private func askAbortMerge() {
        confirm(Confirmation(title: "Abort the merge?",
                             message: "git merge --abort puts the branch and its files back as they were before the merge. Conflicts resolved so far are lost.",
                             button: "Abort Merge") {
            run { await source.abortMerge() }
        })
    }

    private func confirm(_ c: Confirmation) {
        #if DEBUG
        if let autoConfirm { autoConfirm(c.title); c.action(); return }
        #endif
        confirmation = c
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: - Data

    /// Staged: the last commit's version → the staged one. Unstaged: the staged (or committed)
    /// version → the file on disk. git's copies come through temp files, deleted once read.
    private func images(of file: StagedFile, _ f: FileRef) async -> (before: NSImage?, after: NSImage?) {
        func load(_ version: StoredVersion) async -> NSImage? {
            guard let url = await source.storedCopy(file, version) else { return nil }
            defer { try? FileManager.default.removeItem(at: url) }
            return NSImage(contentsOf: url)
        }
        let before: NSImage? = f.untracked ? nil : await load(f.staged ? .head : .index)
        let after: NSImage?
        if f.staged { after = await load(.index) }
        else { after = source.fileURL(path: f.path).flatMap { NSImage(contentsOf: $0) } }
        return (before, after)
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let src = source
        async let status = src.status()
        async let ctx = src.context()
        let (newFiles, newContext) = await (status, ctx)
        // A newer reload started while git ran; its answer wins.
        guard generation == reloadGeneration else { return }
        apply(newFiles, newContext)
        await loadDiff()
    }

    private func apply(_ newFiles: [StagedFile], _ newContext: ChangeContext) {
        files = newFiles
        context = newContext
        loaded = true
        if commitMessage.isEmpty, !prefilledMerge, newContext.merging, let m = newContext.mergeMessage {
            commitMessage = m
            prefilledMerge = true
        }
        focused = ChangeSelection.follow(focused, staged: staged.map(\.path), unstaged: unstaged.map(\.path),
                                         conflicted: conflicts.map(\.path))
        // Opening on the first file means the diff panel never starts out empty.
        if focused == nil, let first = displayOrder.first { focused = first }
    }

    /// The poll and the activation refresh: re-read only when something actually moved, so an
    /// idle sheet never re-draws (or loses its scroll position).
    private func quietRefresh() async {
        guard loaded, !busy else { return }
        let generation = reloadGeneration
        let src = source
        async let status = src.status()
        async let ctx = src.context()
        let (newFiles, newContext) = await (status, ctx)
        guard !busy, generation == reloadGeneration else { return }
        if newFiles != files || newContext != context { apply(newFiles, newContext) }
        await loadDiff()
    }

    /// Load the focused file's diff. An unchanged diff is left alone — the view keeps its rows,
    /// and the reader keeps their place in it.
    private func loadDiff(force: Bool = false) async {
        guard let f = focused, let file = file(for: f) else { diff = nil; return }
        let raw = await source.diff(file: file, staged: f.staged)
        // A newer selection already replaced this one while git ran.
        guard focused == f else { return }
        var conflict: ConflictDocument?
        if f.conflicted, let url = source.fileURL(path: f.path) { conflict = ConflictFileIO.load(url) }
        if !force, let d = diff, d.ref == f, d.raw == raw, d.conflict == conflict { return }
        let bytes = raw.utf8.count
        if bytes > Self.largeDiffBytes, largeDiffAllowed != f {
            diff = LoadedDiff(ref: f, raw: raw, fileHeader: [], hunks: [], binary: false, tooLarge: bytes, conflict: conflict)
            return
        }
        let parsed = parseHunks(raw)
        var loaded = LoadedDiff(ref: f, raw: raw, fileHeader: parsed.fileHeader, hunks: parsed.hunks,
                                binary: isBinaryDiff(raw), tooLarge: nil, conflict: conflict)
        if loaded.binary, Self.imageExtensions.contains((f.path as NSString).pathExtension.lowercased()) {
            loaded.images = await images(of: file, f)
            guard focused == f else { return }
        }
        diff = loaded
    }
}
