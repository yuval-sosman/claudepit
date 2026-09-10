import SwiftUI
import ClaudepitCore

/// Shared inline Q&A panel used by both PlanDetailView and SessionDetailView.
struct PlanQAPanel: View {
    let planContent: String
    var title: String = "Ask about this plan"
    var showImprovement: Bool = true
    /// When provided, improvement detection and apply flow are enabled.
    var planPath: URL? = nil
    /// Override the content label in prompts. Defaults to "plan" or "memory file" based on showImprovement.
    var contentLabel: String? = nil
    /// Called with the improved content; caller owns diff display and persistence.
    var onPlanImproved: ((String, URL) -> Void)? = nil
    /// Called with each assistant answer text (stripped of tags).
    var onAnswer: ((String) -> Void)? = nil

    @State private var messages: [QAMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @State private var turnCount: Int = 0
    @State private var errorMessage: String?
    @State private var improvementIndexes: Set<Int> = []
    @State private var applyingIndex: Int? = nil

    private let maxTurns = 10

    private static let suggestionTag = "[[SUGGEST_IMPROVEMENT]]"

    /// Strips the AI signal tag and returns (cleanText, tagWasPresent).
    private func processResponse(_ raw: String) -> (String, Bool) {
        if raw.contains(Self.suggestionTag) {
            let cleaned = raw
                .replacingOccurrences(of: "\n" + Self.suggestionTag, with: "")
                .replacingOccurrences(of: Self.suggestionTag, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned, true)
        }
        return (raw, false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(turnCount) / \(maxTurns)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)

            Divider().opacity(0.25)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { idx, msg in
                            messageRow(msg, index: idx).id(idx)
                        }
                        if isLoading {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary).font(.caption)
                            }
                            .padding(.leading, 12)
                            .id("loading")
                        }
                        if let err = errorMessage {
                            Text(err).foregroundStyle(.red).font(.caption).padding(.leading, 12)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) {
                    withAnimation { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
                }
                .onChange(of: isLoading) {
                    if isLoading { withAnimation { proxy.scrollTo("loading", anchor: .bottom) } }
                }
            }

            Divider().opacity(0.25)

            if turnCount >= maxTurns {
                Text("Limit reached — close to start fresh")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            } else {
                HStack(spacing: 8) {
                    TextField("Ask a question…", text: $inputText, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .onSubmit { sendIfReady() }
                    Button("Send") { sendIfReady() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.18)))
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: QAMessage, index: Int) -> some View {
        if msg.role == "user" {
            HStack(alignment: .top) {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                copyButton(msg.text)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 4) {
                    MarkdownText(msg.text)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    copyButton(msg.text)
                }

                if showImprovement && improvementIndexes.contains(index) {
                    HStack {
                        Spacer(minLength: 40)
                        if applyingIndex == index {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Generating improvement…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                applyImprovement(suggestion: msg.text, index: index)
                            } label: {
                                Label("Apply improvement", systemImage: "wand.and.stars")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(applyingIndex != nil)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    private func sendIfReady() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading, turnCount < maxTurns else { return }

        messages.append(QAMessage(role: "user", text: question))
        turnCount += 1
        inputText = ""
        isLoading = true
        errorMessage = nil

        let prompt = PlanQARunner.buildPrompt(
            planContent: planContent,
            history: Array(messages.dropLast()),
            question: question,
            contentLabel: contentLabel ?? (showImprovement ? "plan" : "memory file")
        )
        let answerIndex = messages.count

        Task {
            do {
                let answer = try await PlanQARunner.ask(prompt)
                await MainActor.run {
                    let (clean, tagPresent) = processResponse(answer)
                    messages.append(QAMessage(role: "assistant", text: clean))
                    if tagPresent { improvementIndexes.insert(answerIndex) }
                    onAnswer?(clean)
                    isLoading = false
                }
            } catch PlanQAError.claudeNotFound {
                await MainActor.run { errorMessage = "claude CLI not found"; isLoading = false }
            } catch PlanQAError.processFailed(let code, _) {
                await MainActor.run { errorMessage = "Request failed (exit \(code)) — try again"; isLoading = false }
            } catch {
                await MainActor.run { errorMessage = "Request failed — try again"; isLoading = false }
            }
        }
    }

    private func applyImprovement(suggestion: String, index: Int) {
        guard let path = planPath, applyingIndex == nil else { return }
        applyingIndex = index
        errorMessage = nil

        let prompt = PlanQARunner.buildImprovementPrompt(planContent: planContent, suggestion: suggestion)

        Task {
            do {
                let improved = try await PlanQARunner.improve(prompt)
                await MainActor.run {
                    onPlanImproved?(improved, path)
                    applyingIndex = nil
                }
            } catch PlanQAError.claudeNotFound {
                await MainActor.run { errorMessage = "claude CLI not found"; applyingIndex = nil }
            } catch PlanQAError.processFailed(let code, _) {
                await MainActor.run { errorMessage = "Improvement failed (exit \(code)) — try again"; applyingIndex = nil }
            } catch {
                await MainActor.run { errorMessage = "Improvement failed — try again"; applyingIndex = nil }
            }
        }
    }
}
