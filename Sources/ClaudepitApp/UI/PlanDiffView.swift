import SwiftUI

enum PlanDiffLine {
    case unchanged(String)
    case removed(String)
    case added(String)
}

/// Myers-style LCS line diff. Shared by Plans "Apply improvement" and the task chat panel.
func planDiffLines(from original: String, to improved: String) -> [PlanDiffLine] {
    let oldLines = original.components(separatedBy: "\n")
    let newLines = improved.components(separatedBy: "\n")

    let m = oldLines.count, n = newLines.count
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in stride(from: m - 1, through: 0, by: -1) {
        for j in stride(from: n - 1, through: 0, by: -1) {
            if oldLines[i] == newLines[j] {
                dp[i][j] = 1 + dp[i + 1][j + 1]
            } else {
                dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
            }
        }
    }

    var result: [PlanDiffLine] = []
    var i = 0, j = 0
    while i < m && j < n {
        if oldLines[i] == newLines[j] {
            result.append(.unchanged(oldLines[i])); i += 1; j += 1
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            result.append(.removed(oldLines[i])); i += 1
        } else {
            result.append(.added(newLines[j])); j += 1
        }
    }
    while i < m { result.append(.removed(oldLines[i])); i += 1 }
    while j < n { result.append(.added(newLines[j])); j += 1 }
    return result
}

struct PlanDiffView: View {
    let lines: [PlanDiffLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func row(_ line: PlanDiffLine) -> some View {
        switch line {
        case .unchanged(let text):
            base("  " + text)
                .foregroundStyle(.primary.opacity(0.75))
        case .removed(let text):
            base("- " + text)
                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
                .background(Color(red: 1, green: 0.2, blue: 0.2).opacity(0.12))
        case .added(let text):
            base("+ " + text)
                .foregroundStyle(Color(red: 0.35, green: 0.9, blue: 0.45))
                .background(Color(red: 0.2, green: 0.8, blue: 0.3).opacity(0.12))
        }
    }

    private func base(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
    }
}
