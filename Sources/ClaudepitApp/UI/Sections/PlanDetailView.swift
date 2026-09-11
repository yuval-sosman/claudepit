import SwiftUI
import ClaudepitCore

struct PlanFile: Identifiable, Equatable {
    var id: URL { path }
    let name: String
    let path: URL
    let modifiedAt: Date
}

struct PlanDetailView: View {
    let plan: PlanFile
    @ObservedObject var app: AppState
    var onPlanChanged: (() -> Void)? = nil

    @State private var content: String = ""
    @State private var loadError: String?
    @State private var showQA = false
    @State private var pendingImproved: String? = nil   // non-nil = diff mode

    var body: some View {
        GeometryReader { geo in
            GlassCard {
                VStack(spacing: 0) {
                    titleBar
                    Divider().opacity(0.15)

                    if showQA {
                        PlanQAPanel(planContent: content, cwd: app.activePath, planPath: plan.path) { newContent, _ in
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
        .onChange(of: plan) {
            loadContent()
            showQA = false
            pendingImproved = nil
        }
    }

    @ViewBuilder
    private var titleBar: some View {
        HStack(spacing: 8) {
            if let tid = app.returnToTaskID {
                Button {
                    app.focusTaskID = tid
                    app.returnToTaskID = nil
                    app.selected = .tasks
                } label: {
                    Label("Back to task", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text(plan.name)
                .font(.headline)
                .lineLimit(1)
            CopyPathButton(url: plan.path)
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
            try improved.write(to: plan.path, atomically: true, encoding: .utf8)
            content = improved
            pendingImproved = nil
            onPlanChanged?()
        } catch {
            // surface nothing — file write errors are rare; content stays in diff mode
        }
    }

    private func loadContent() {
        let url = plan.path
        Task.detached(priority: .userInitiated) {
            let result = try? String(contentsOf: url, encoding: .utf8)
            await MainActor.run {
                content = result ?? ""
                loadError = result == nil ? "Could not read plan" : nil
            }
        }
    }
}
