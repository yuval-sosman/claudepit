import SwiftUI
import ClaudepitCore

struct SpecDetailView: View {
    let spec: SpecFile
    @ObservedObject var app: AppState
    var onSpecChanged: (() -> Void)? = nil

    @State private var content: String = ""
    @State private var loadError: String?
    @State private var showQA = false
    @State private var pendingImproved: String? = nil

    var body: some View {
        GeometryReader { geo in
            GlassCard {
                VStack(spacing: 0) {
                    titleBar
                    Divider().opacity(0.15)

                    if showQA {
                        PlanQAPanel(planContent: content, cwd: app.activePath, planPath: spec.path,
                                    contentLabel: "spec") { newContent, _ in
                            pendingImproved = newContent
                            showQA = false
                        }
                        .frame(height: geo.size.height * 0.4)
                        Divider().opacity(0.15)
                    }

                    if let err = loadError {
                        Text(err).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if pendingImproved != nil {
                        PlanDiffView(lines: planDiffLines(from: content, to: pendingImproved ?? ""))
                    } else {
                        ScrollView {
                            MarkdownText(content)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
        }
        .onAppear { loadContent() }
        .onChange(of: spec) {
            loadContent()
            showQA = false
            pendingImproved = nil
        }
    }

    @ViewBuilder
    private var titleBar: some View {
        HStack(spacing: 8) {
            if let tid = app.returnToSpecTaskID {
                Button {
                    app.focusTaskID = tid
                    app.returnToSpecTaskID = nil
                    app.selected = .tasks
                } label: {
                    Label("Back to task", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text(spec.name)
                .font(.headline)
                .lineLimit(1)
            CopyPathButton(url: spec.path)
            Spacer()
            if pendingImproved != nil {
                Button("Dismiss") {
                    pendingImproved = nil
                }
                .controlSize(.small)

                Button("Accept") {
                    acceptImprovement()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button {
                    showQA.toggle()
                } label: {
                    Image(systemName: showQA
                          ? "bubble.left.and.text.bubble.right.fill"
                          : "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func acceptImprovement() {
        guard let improved = pendingImproved else { return }
        do {
            try improved.write(to: spec.path, atomically: true, encoding: .utf8)
            content = improved
            pendingImproved = nil
            onSpecChanged?()
        } catch {
            // file write errors are rare; content stays in diff mode
        }
    }

    private func loadContent() {
        let url = spec.path
        Task.detached(priority: .userInitiated) {
            let result = try? String(contentsOf: url, encoding: .utf8)
            await MainActor.run {
                content = result ?? ""
                loadError = result == nil ? "Could not read spec" : nil
            }
        }
    }
}
