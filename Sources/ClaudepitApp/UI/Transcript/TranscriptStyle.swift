import SwiftUI
import ClaudepitCore

/// The transcript's visual vocabulary in one place: one colour and one glyph per kind of thing,
/// shared by the rows, the filter chips and the turn rail, so "amber" means an edit everywhere
/// on the page. Icons follow the sidebar's (hooks `link`, skills `wand.and.stars`, agents
/// `person.2`, MCP `server.rack`) so a thing looks the same here as in its own section.
enum TranscriptStyle {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    // Kinds
    static let prompt = Color.accentColor
    static let claude = rgb(0xE0, 0x8A, 0x6A)      // Claude's terracotta, a step lighter for dark
    static let thinking = rgb(0xB4, 0x9C, 0xF0)    // lavender
    static let read = rgb(0x6C, 0xB2, 0xF5)        // sky: reading and searching
    static let edit = rgb(0xF2, 0xA6, 0x4E)        // amber: changing files
    static let shell = rgb(0x6F, 0xCF, 0x97)       // mint: the terminal
    static let web = rgb(0x5C, 0xC8, 0xD6)         // teal
    static let agent = rgb(0xC0, 0x8B, 0xF5)       // purple: delegation
    static let skill = rgb(0xF5, 0x8F, 0x5C)       // orange
    static let mcp = rgb(0x4F, 0xC4, 0xB0)         // sea green
    static let task = rgb(0x8C, 0xD1, 0x6F)        // green: task list
    static let question = rgb(0xF2, 0x7F, 0xB5)    // pink
    static let plan = rgb(0xE8, 0xC9, 0x4F)        // yellow
    static let context = rgb(0x5F, 0xB8, 0xE0)     // cyan: injected context
    static let hook = rgb(0xE8, 0xC3, 0x3A)        // gold
    static let system = Color.secondary
    static let error = rgb(0xF2, 0x5F, 0x5C)
    static let warning = rgb(0xF0, 0xA0, 0x3C)
    static let added = rgb(0x5E, 0xC2, 0x7B)
    static let removed = rgb(0xF2, 0x6D, 0x6D)

    // Surfaces (dark-first; the whole app is designed on the glass dark surface)
    static let codeBackground = Color.black.opacity(0.30)
    static let codeHeader = Color.white.opacity(0.04)
    static let hairline = Color.white.opacity(0.08)
    static let rowHover = Color.white.opacity(0.045)
    static let bodyBackground = Color.white.opacity(0.035)

    // Type
    static let bodyFont = Font.system(size: 13)
    static let rowTitle = Font.system(size: 12, weight: .semibold)
    static let rowDetail = Font.system(size: 12)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let meta = Font.system(size: 11).monospacedDigit()
    static let caption = Font.system(size: 11)
    static let sectionLabel = Font.system(size: 10, weight: .semibold)

    /// Task spans cycle through these, so two tasks worked back to back stay apart.
    private static let spanPalette = [task, rgb(0x5C, 0xC8, 0xD6), rgb(0x7F, 0xA7, 0xF5), rgb(0xB4, 0x9C, 0xF0), rgb(0xF2, 0x7F, 0xB5)]
    static func spanColor(_ index: Int) -> Color { spanPalette[index % spanPalette.count] }

    static func color(for filter: TranscriptFilter) -> Color {
        switch filter {
        case .prompts: return prompt
        case .responses: return claude
        case .thinking: return thinking
        case .tools: return read
        case .edits: return edit
        case .plans: return plan
        case .tasks: return task
        case .questions: return question
        case .subagents: return agent
        case .skills: return skill
        case .context: return context
        case .hooks: return hook
        case .system: return Color(white: 0.6)
        case .errors: return error
        }
    }

    static func icon(for filter: TranscriptFilter) -> String {
        switch filter {
        case .prompts: return "person.fill"
        case .responses: return "sparkle"
        case .thinking: return "brain"
        case .tools: return "wrench.and.screwdriver"
        case .edits: return "pencil"
        case .plans: return "list.bullet.clipboard"
        case .tasks: return "checklist"
        case .questions: return "questionmark.bubble"
        case .subagents: return "person.2"
        case .skills: return "wand.and.stars"
        case .context: return "paperclip"
        case .hooks: return "link"
        case .system: return "gearshape"
        case .errors: return "exclamationmark.triangle"
        }
    }

    /// Glyph and colour for a tool call, by what it does.
    static func toolStyle(_ inv: ToolInvocation) -> (icon: String, color: Color) {
        switch inv.toolClass {
        case .agent: return ("person.2", agent)
        case .skill: return ("wand.and.stars", skill)
        case .mcp: return ("server.rack", mcp)
        case .builtin: break
        }
        switch inv.name {
        case "Read", "NotebookRead": return ("doc.text", read)
        case "Grep": return ("text.magnifyingglass", read)
        case "Glob", "LS": return ("folder", read)
        case "ToolSearch": return ("shippingbox", read)
        case "Edit", "MultiEdit": return ("pencil", edit)
        case "Write": return ("doc.badge.plus", edit)
        case "NotebookEdit": return ("book.pages", edit)
        case "Bash", "BashOutput", "KillShell", "KillBash": return ("terminal", shell)
        case "Monitor": return ("waveform.path.ecg", shell)
        case "WebFetch": return ("globe", web)
        case "WebSearch": return ("magnifyingglass", web)
        case "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskStop", "TaskOutput", "TodoWrite":
            return ("checklist", task)
        case "AskUserQuestion": return ("questionmark.bubble", question)
        case "ExitPlanMode", "EnterPlanMode": return ("list.bullet.clipboard", plan)
        case "SendMessage", "SubagentHandback", "ListAgents": return ("bubble.left.and.bubble.right", agent)
        case "ScheduleWakeup", "CronCreate", "CronDelete", "CronList": return ("clock", Color(white: 0.65))
        default: return ("wrench.and.screwdriver", Color(white: 0.65))
        }
    }
}

/// Numbers and times as the transcript prints them.
enum TranscriptFormat {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f
    }()

    /// `14:52:26`.
    static func clock(_ t: TimeInterval?) -> String? {
        t.map { timeFormatter.string(from: Date(timeIntervalSince1970: $0)) }
    }

    /// `Sep 30, 14:52`.
    static func dayClock(_ t: TimeInterval?) -> String? {
        t.map { dayTimeFormatter.string(from: Date(timeIntervalSince1970: $0)) }
    }

    /// `320ms`, `4.2s`, `48s`, `3m 12s`, `1h 4m`.
    static func duration(seconds s: TimeInterval) -> String {
        if s < 1 { return "\(max(1, Int((s * 1000).rounded())))ms" }
        if s < 10 { return String(format: "%.1fs", s) }
        let whole = Int(s.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }

    static func duration(ms: Int) -> String { duration(seconds: Double(ms) / 1000) }

    static func tokens(_ n: Int) -> String { CompactCount.tokens(n) }

    /// `Opus 5.5` from `claude-opus-5-5[1m]`.
    static func model(_ id: String) -> String {
        ModelNames.display(id.replacingOccurrences(of: "[1m]", with: ""))
    }

    /// `~/Dev/claudepit` for a path under the home folder.
    static func path(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    static func fileName(_ p: String) -> String { (p as NSString).lastPathComponent }

    static func plural(_ n: Int, _ word: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? word : plural ?? word + "s")"
    }
}
