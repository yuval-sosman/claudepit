import SwiftUI
import ClaudepitCore

// The pieces the Plans and Memory lists are built from. They copy the Sessions list's look —
// selection tint, hover, pinned date headers, the search box — so the three left cards read as
// one family instead of three generations of the app.

/// One row of a page's file list: an optional leading glyph, a title, an optional second line,
/// a meta line, trailing markers, and the actions menu, which shows on hover or selection.
struct PageListRow<Leading: View, Markers: View, MenuItems: View>: View {
    let title: String
    var titleLines = 1
    var subtitle: String? = nil
    /// The second line is a search excerpt rather than the item's own summary.
    var subtitleIsExcerpt = false
    var subtitleLines = 1
    var meta: Text? = nil
    let isSelected: Bool
    let isFocused: Bool
    let isHovered: Bool
    var help: String = ""
    /// A colour down the row's leading edge, full height — the Sessions rows' worktree stripe.
    var edgeColor: Color? = nil
    /// The row's click (selects it).
    var onTap: () -> Void = {}
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let markers: () -> Markers
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            // A Button, not a tap gesture: synthetic clicks (the DEBUG interaction harness) reach
            // a Button but never a bare TapGesture. The "…" menu sits beside it, not inside it.
            Button(action: onTap) {
                HStack(alignment: .center, spacing: 8) {
                    leading()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(titleLines)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                            markers()
                        }
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .italic(subtitleIsExcerpt)
                                .foregroundStyle(.secondary)
                                .lineLimit(subtitleLines)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let meta {
                            meta.font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { menuItems() } label: {
                Image(systemName: Icon.moreActions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered || isSelected ? 1 : 0)
            .help("Actions")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .background(PageListRowBackground(isSelected: isSelected, isFocused: isFocused, isHovered: isHovered))
        .overlay(alignment: .leading) {
            if let edgeColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(edgeColor)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 6)
        .help(help)
        .contextMenu { menuItems() }
    }
}

/// The Sessions list's row tint: accent when selected (stronger while the list has focus),
/// a faint wash on hover.
struct PageListRowBackground: View {
    let isSelected: Bool
    let isFocused: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8).fill(
            isSelected ? Color.accentColor.opacity(isFocused ? 0.26 : 0.16)
                : isHovered ? Color.white.opacity(0.05) : Color.clear)
    }
}

/// A pinned section header: "Today", "Topics · 12".
struct PageListSectionHeader: View {
    let title: String
    var count: Int? = nil
    var help: String = ""

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let count {
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
        .background(Rectangle().fill(.ultraThinMaterial).opacity(0.96))
        .help(help)
    }
}

/// The search box: magnifier, field, clear button. ↓ moves into the results, Esc clears and
/// then leaves the field — the same keys as the Sessions list.
struct PageListSearchField: View {
    @Binding var text: String
    let placeholder: String
    var help: String = ""
    var focusToken = 0
    var onArrowDown: () -> Void = {}
    var onLeave: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Icon.search).font(.system(size: 11)).foregroundStyle(.secondary)
            SearchTextField(text: $text, placeholder: placeholder, focusToken: focusToken,
                            onArrowDown: onArrowDown,
                            onEscape: { if text.isEmpty { onLeave() } else { text = "" } })
                .frame(height: 16)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: Icon.clearField).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .help(help)
    }
}

/// A removable filter chip under the search box.
struct PageListChip: View {
    let text: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove filter")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.2), in: Capsule())
    }
}

/// An empty list's explanation: what would appear here, and how to get it.
struct PageListEmptyState<Extra: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            extra().padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PageListEmptyState where Extra == EmptyView {
    init(icon: String, title: String, detail: String) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

/// Moving a list's selection with ↑/↓: the neighbour of `current` in `order`, clamped at the
/// ends; with nothing selected, ↓ picks the first item and ↑ the last.
enum PageListKeys {
    static func step<ID: Equatable>(_ current: ID?, by delta: Int, in order: [ID]) -> ID? {
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else {
            return delta > 0 ? order.first : order.last
        }
        return order[min(order.count - 1, max(0, i + delta))]
    }
}
