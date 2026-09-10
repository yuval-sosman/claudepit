import SwiftUI
import ClaudepitCore

/// Palette cycled by span order so adjacent tasks are visually distinguishable.
func taskGroupColor(_ index: Int) -> Color {
    let palette: [Color] = [.blue, .teal, .purple, .orange, .pink]
    return palette[index % palette.count]
}

/// A task span: colored tappable heading + a left accent bar down all its rows.
struct TaskGroupView<Row: View>: View {
    let span: TaskSpan
    let colorIndex: Int
    let onHeadingTap: () -> Void
    @ViewBuilder var rows: () -> Row

    var body: some View {
        let color = taskGroupColor(colorIndex)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onHeadingTap) {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                    Text(span.label).bold()
                    Spacer()
                    Image(systemName: "list.bullet.rectangle").font(.caption2).opacity(0.7)
                }
                .foregroundStyle(color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.5)).frame(width: 3)
                VStack(alignment: .leading, spacing: 10) { rows() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One clickable task line (shared by TodoListView and SynthTodoView).
struct TodoRow: View {
    let id: String
    let status: String
    let subject: String
    var hasSpan: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon).foregroundStyle(.secondary).font(.caption)
                Text("#\(id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(subject).foregroundStyle(Color.accentColor)
                Spacer()
                if hasSpan {
                    Text("→ #\(id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusIcon: String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dashed"
        default: return "circle"
        }
    }
}

/// Renders a TaskList invocation as clickable task lines (parsed from its result text).
struct TodoListView: View {
    let inv: ToolInvocation
    var startByTaskId: [String: Int] = [:]
    let onTapTask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TODO list").font(.caption2.bold()).foregroundStyle(.secondary)
            let lines = parsedTasks
            if lines.isEmpty {
                Text(inv.resultText ?? "").font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                ForEach(lines, id: \.id) { t in
                    TodoRow(id: t.id, status: t.status, subject: t.subject,
                            hasSpan: startByTaskId[t.id] != nil) { onTapTask(t.id) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    // TaskList result lines look like: "#1 [completed] subject" — but the exact
    // format may vary; parse leniently: id from "#N", optional "[status]", rest is subject.
    private var parsedTasks: [(id: String, status: String, subject: String)] {
        guard let text = inv.resultText else { return [] }
        var out: [(String, String, String)] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let hash = line.firstIndex(of: "#") else { continue }
            let after = line[line.index(after: hash)...]
            let id = String(after.prefix { $0.isNumber })
            guard !id.isEmpty else { continue }
            var rest = String(after.drop { $0.isNumber }).trimmingCharacters(in: .whitespaces)
            var status = "pending"
            if rest.hasPrefix("[") , let close = rest.firstIndex(of: "]") {
                status = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            out.append((id, status, rest))
        }
        return out
    }
}
