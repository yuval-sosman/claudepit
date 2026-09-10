import SwiftUI
import ClaudepitCore
import AppKit

/// A small clipboard button that copies the given text.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.callout)
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

/// Expanded body of a tool invocation: colored diff for edits, else INPUT json + RESULT.
struct ToolDetail: View {
    let inv: ToolInvocation

    var body: some View {
        if inv.name == "AskUserQuestion" {
            askUserQuestion
        } else {
            VStack(alignment: .leading, spacing: 8) {
                let diff = diffLines(toolName: inv.name, input: inv.input)
                if !diff.isEmpty {
                    DiffView(lines: diff, isSwift: isSwiftFile, isMarkdown: isMarkdownFile,
                             language: fileLanguage)
                } else if !inv.input.isEmpty {
                    label("INPUT")
                    Text(prettyJSON(inv.input))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }

                label("RESULT")
                resultView
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var askUserQuestion: some View {
        let questions = parseAskQuestions(inv.input)
        let answers = inv.resultText.map(parseAskAnswers) ?? [:]
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                AskQuestionView(q: q, chosen: chosenLabels(q, answers))
            }
            if questions.isEmpty {
                Text("No questions").font(.caption).italic().foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func chosenLabels(_ q: AskQuestion, _ answers: [String: String]) -> Set<String> {
        // answers maps question text → chosen label; match by question text
        if let a = answers[q.question] { return [a] }
        return []
    }

    @ViewBuilder private var resultView: some View {
        if let r = inv.resultText {
            let capped = String(r.prefix(4000))
            if inv.isError == true {
                Text(capped).font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                switch classifyResult(capped) {
                case .json:
                    Text(prettyJSONString(capped)).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                case .markdown:
                    MarkdownText(capped)
                case .plain:
                    Text(capped).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if r.count > 4000 {
                    Text("… \(r.count - 4000) more chars").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No result").font(.caption).italic().foregroundStyle(.secondary)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption2.bold()).foregroundStyle(.secondary)
    }

    private var isSwiftFile: Bool {
        let path = (inv.input["file_path"] as? String) ?? (inv.input["notebook_path"] as? String) ?? ""
        return path.hasSuffix(".swift")
    }

    private var isMarkdownFile: Bool {
        let path = (inv.input["file_path"] as? String) ?? ""
        return path.hasSuffix(".md") || path.hasSuffix(".markdown")
    }

    private var fileLanguage: String? {
        let path = (inv.input["file_path"] as? String) ?? (inv.input["notebook_path"] as? String) ?? ""
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : GenericHighlighter.language(forExtension: ext)
    }

    private func prettyJSON(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return String(describing: obj) }
        return s
    }
    private func prettyJSONString(_ s: String) -> String {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: out, encoding: .utf8) else { return s }
        return str
    }
}

/// Read-only rendering of one AskUserQuestion question — inline header, the
/// question in a light card, and single-line option rows.
private struct AskQuestionView: View {
    let q: AskQuestion
    let chosen: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // inline header + (choose one/multiple) hint
            HStack(spacing: 6) {
                if !q.header.isEmpty {
                    Text(q.header.uppercased()).font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                }
                Text(q.multiSelect ? "(choose multiple)" : "(choose one)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // question in its own light card
            Text(q.question).font(.body).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            // single-line option rows
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                let isChosen = chosen.contains(opt.label)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                        .font(.caption)
                    Text(opt.label).bold()
                    if !opt.description.isEmpty {
                        Text("— \(opt.description)").font(.callout).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(isChosen ? Color.accentColor.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isChosen ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.08),
                                      lineWidth: 1)
                )
            }
        }
    }
}

/// Colored line diff (removed red, added green), with an optional file header.
struct DiffView: View {
    let lines: [DiffLine]
    var isSwift: Bool = false
    var isMarkdown: Bool = false
    /// Non-Swift language for GenericHighlighter (nil = plain). Derive from the
    /// file extension at the call site.
    var language: String? = nil
    @State private var rendered = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar: file name (first .file line) + action buttons
            HStack(spacing: 8) {
                if let fileLabel = lines.first(where: { $0.kind == .file })?.text {
                    Text(fileLabel)
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isMarkdown {
                    Button { rendered.toggle() } label: {
                        Image(systemName: rendered ? "chevron.left.forwardslash.chevron.right" : "text.viewfinder")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(rendered ? "Show raw" : "Render markdown")
                }
                CopyButton(text: copyText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.15))

            Divider().opacity(0.2)

            if isMarkdown && rendered {
                MarkdownText(copyText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    diffRows
                }
                .padding(6)
            }
        }
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var diffRows: some View {
        let shown = Array(lines.prefix(400))
        ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
            if line.kind != .file { row(line) }
        }
        if lines.count > 400 {
            Text("… \(lines.count - 400) more lines").font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Added lines (the resulting content) — the useful thing to copy from a diff.
    private var copyText: String {
        lines.filter { $0.kind == .add }.map(\.text).joined(separator: "\n")
    }

    @ViewBuilder private func row(_ line: DiffLine) -> some View {
        switch line.kind {
        case .file:
            EmptyView()   // rendered in toolbar header
        case .note:
            Divider().opacity(0.3).padding(.vertical, 2)
        case .add:
            diffLine("+", line.text, .green)
        case .remove:
            diffLine("-", line.text, .red)
        case .context:
            diffLine(" ", line.text, .primary)
        }
    }

    private func diffLine(_ sign: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign).font(.system(.body, design: .monospaced)).foregroundStyle(color).frame(width: 10)
            lineText(text, fallbackColor: color)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(color.opacity(0.10))
    }

    @ViewBuilder private func lineText(_ text: String, fallbackColor: Color) -> some View {
        let shown = text.isEmpty ? " " : text
        if isSwift {
            Text(SwiftHighlighter.attributed(shown))
        } else if let lang = language {
            Text(GenericHighlighter.attributed(shown, language: lang))
        } else {
            Text(shown)
        }
    }
}
