import Foundation

/// What the menu bar item renders: a badge, an icon, and the rows behind them.
///
/// Built from `buildWorkstream`'s output rather than from tasks/agents directly — the menu bar
/// and Home's "Needs attention" card must never disagree about what is waiting on you, and the
/// folding of an agent into the task it runs is exactly the part that would drift if both
/// counted for themselves.
public struct MenuBarSummary: Equatable {
    /// Rows waiting on a human — blocked/failed tasks, dirty worktrees, blocked agents.
    public let attentionCount: Int
    /// Live agents that are working right now and need nothing from you.
    public let workingCount: Int
    /// The rows to list in the panel, already capped.
    public let rows: [WorkItem]
    /// Rows dropped by the cap, so the panel can say "+N more" instead of lying by omission.
    public let overflow: Int

    public init(attentionCount: Int, workingCount: Int, rows: [WorkItem], overflow: Int) {
        self.attentionCount = attentionCount
        self.workingCount = workingCount
        self.rows = rows
        self.overflow = overflow
    }

    /// One icon-plus-count pair in the status item's label.
    public struct Segment: Equatable {
        public let symbol: String
        /// Nil only for the idle segment, which is a bare icon.
        public let count: String?
        public init(symbol: String, count: String?) {
            self.symbol = symbol
            self.count = count
        }
    }

    /// What the status item actually draws, left to right.
    ///
    /// Attention and activity are *both* shown when both exist — a raised hand with its own count
    /// sits to the left of the working-agent count — because collapsing to the winner hid the fact
    /// that an agent had stopped for you: the label kept reading as a single number and only the
    /// glyph changed. Seeing "2 working" was the normal state, so nothing about it invited a click.
    public var segments: [Segment] {
        var out: [Segment] = []
        if attentionCount > 0 {
            out.append(Segment(symbol: attentionSymbol, count: "\(attentionCount)"))
        }
        if workingCount > 0 {
            out.append(Segment(symbol: busySymbol, count: "\(workingCount)"))
        }
        if out.isEmpty { out.append(Segment(symbol: idleSymbol, count: nil)) }
        return out
    }

    /// Attention outranks activity: a count next to a raised hand means "you", a count next to
    /// the terminal glyph means "me". Nil when there is nothing at all, which leaves a bare icon.
    public var badge: String? { segments[0].count }

    public var needsAttention: Bool { attentionCount > 0 }
    public var isBusy: Bool { workingCount > 0 }

    /// The raised hand is the app's established "waiting for you" mark (Home rows, session rows);
    /// `bolt.horizontal` reads as work in flight. Status items render template images, so the two
    /// states must be told apart by *shape* — a tint would be stripped.
    public var attentionSymbol: String { "hand.raised.fill" }
    public var busySymbol: String { "bolt.horizontal.fill" }
    public var idleSymbol: String { "square.stack.3d.up" }

    /// Leading SF Symbol for the status item — the first segment's.
    public var symbol: String { segments[0].symbol }

    /// One line for the panel header and the item's tooltip.
    public var headline: String {
        switch (attentionCount, workingCount) {
        case (0, 0):            return "Nothing running"
        case (0, let w):        return "\(w) agent\(w == 1 ? "" : "s") working"
        case (let a, 0):        return "\(a) item\(a == 1 ? "" : "s") need you"
        case (let a, let w):    return "\(a) need\(a == 1 ? "s" : "") you · \(w) working"
        }
    }
}

/// Pure builder. `limit` caps the listed rows; the counts always describe the full list.
public func buildMenuBarSummary(workstream: [WorkItem], limit: Int = 8) -> MenuBarSummary {
    let attention = workstream.filter { $0.needsAttention }.count
    // A row that needs attention is not also counted as busy, even when an agent backs it —
    // otherwise a blocked task with a live pane would be tallied twice in one line.
    let working = workstream.filter { !$0.needsAttention && $0.agentStatus == Herdr.AgentState.working }.count
    let capped = limit > 0 ? Array(workstream.prefix(limit)) : []
    return MenuBarSummary(attentionCount: attention,
                          workingCount: working,
                          rows: capped,
                          overflow: max(0, workstream.count - capped.count))
}
