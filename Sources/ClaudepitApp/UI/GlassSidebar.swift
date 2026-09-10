import SwiftUI

private struct SidebarGroup {
    let label: String?
    let sections: [Section]
}

// Specs is the only indented child of Tasks
private let taskChildren: [Section] = [.specs]

private let sidebarGroups: [SidebarGroup] = [
    SidebarGroup(label: nil,             sections: [.home]),
    SidebarGroup(label: "Execution",     sections: [.tasks, .sessions, .plans, .worktrees, .loops, .memory]),
    SidebarGroup(label: "Configuration", sections: [.claudeMd, .plugins, .agents, .skills, .commands, .rules, .mcp, .hooks, .settings]),
]

struct GlassSidebar: View {
    @Binding var selected: Section
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(sidebarGroups.enumerated()), id: \.offset) { _, group in
                if let label = group.label, expanded {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                }
                ForEach(group.sections) { section in
                    sidebarButton(section)
                    if section == .tasks {
                        ForEach(Array(taskChildren.enumerated()), id: \.element) { idx, child in
                            sidebarButton(child, indent: true, isLast: idx == taskChildren.count - 1)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(8)
        .frame(width: expanded ? 230 : 60)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.18)) { expanded = hovering } }
    }

    private func sidebarButton(_ section: Section, indent: Bool = false, isLast: Bool = false) -> some View {
        Button { selected = section } label: {
            HStack(spacing: 0) {
                if indent && expanded {
                    // Tree line: vertical bar + elbow, drawn in a fixed-width canvas
                    Canvas { ctx, size in
                        let x = size.width / 2
                        let midY = size.height / 2
                        var path = Path()
                        // vertical segment from top down to mid-row
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: isLast ? midY : size.height))
                        // horizontal elbow to the right
                        path.move(to: CGPoint(x: x, y: midY))
                        path.addLine(to: CGPoint(x: size.width, y: midY))
                        ctx.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1)
                    }
                    .frame(width: 16, height: 36)
                    .padding(.leading, 20)
                }
                HStack(spacing: 12) {
                    if indent && !expanded {
                        Image(systemName: section.systemImage)
                            .frame(width: 24)
                            .font(.system(size: 13))
                            .foregroundStyle(selected == section ? .primary : .secondary)
                    } else {
                        Image(systemName: section.systemImage)
                            .frame(width: 24)
                    }
                    if expanded {
                        Text(section.title).lineLimit(1)
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, indent && expanded ? 4 : 12)
                .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == section ? Color.white.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
