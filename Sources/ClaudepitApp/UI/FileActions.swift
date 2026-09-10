import SwiftUI
import AppKit

/// Copies a file path string to the general pasteboard.
private func copyPathToPasteboard(_ url: URL) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(url.path, forType: .string)
}

/// A single icon-only "Copy path" button — for headers/detail panes where a
/// full action menu already lives elsewhere (e.g. a row's `…` context menu).
struct CopyPathButton: View {
    let url: URL
    var body: some View {
        Button { copyPathToPasteboard(url) } label: {
            Image(systemName: Icon.copyPath).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy path")
    }
}

/// A `…` (ellipsis) menu exposing the standard file actions — Open in editor /
/// Reveal in Finder / Copy path. Pass `onDelete` to append a destructive
/// "Move to Trash" item; omit (nil) to hide it.
struct FileActionsMenu: View {
    let url: URL
    var onDelete: (() -> Void)? = nil   // ponytail: nil = no delete item shown
    var body: some View {
        Menu {
            fileContextMenu(url: url)
            if let onDelete {
                Divider()
                Button(role: .destructive) { onDelete() } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: Icon.moreActions).font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("File actions")
    }
}

extension View {
    /// The three standard file-action menu items (Open in Editor / Reveal in
    /// Finder / Copy Path) as `Button`+`Label` rows, for use inside a
    /// `.contextMenu { }` or `Menu { }`.
    @ViewBuilder
    func fileContextMenu(url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label("Open in Editor", systemImage: Icon.openFile)
        }
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label("Reveal in Finder", systemImage: Icon.revealInFinder)
        }
        Button { copyPathToPasteboard(url) } label: {
            Label("Copy Path", systemImage: Icon.copyPath)
        }
    }
}

/// A monospaced, middle-truncated file path shown as a clickable link: click to
/// open the file, right-click for the full Open / Reveal / Copy path menu.
struct FilePathLabel: View {
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Text(url.path)
                .lineLimit(1).truncationMode(.middle)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open \(url.lastPathComponent)")
        .contextMenu { fileContextMenu(url: url) }
    }
}
