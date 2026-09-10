import SwiftUI
import ClaudepitCore

func timelineColor(_ kind: TimelineMarker.Kind) -> Color {
    switch kind {
    case .user:     return .blue
    case .task:     return .green
    case .subagent: return .purple
    case .skill:    return .orange
    case .question: return .pink
    case .hook:     return .cyan
    case .tools:    return .gray
    case .plan:     return .yellow
    }
}

func timelineKindName(_ kind: TimelineMarker.Kind) -> String {
    switch kind {
    case .user:     return "Your message"
    case .task:     return "Task"
    case .subagent: return "Subagent"
    case .skill:    return "Skill"
    case .question: return "Question"
    case .hook:     return "Hook"
    case .tools:    return "Tools"
    case .plan:     return "Plan"
    }
}

/// Thin vertical scrubber: index-proportional colored dots, hover label, tap to jump.
struct TimelineRail: View {
    let markers: [TimelineMarker]
    let eventCount: Int
    let onTap: (Int) -> Void
    var onJumpTop: (() -> Void)? = nil
    var onJumpBottom: (() -> Void)? = nil

    @State private var hovered: Int?   // marker index being hovered
    @State private var showLegend = false

    var body: some View {
        VStack(spacing: 6) {
            Button { showLegend.toggle() } label: {
                Image(systemName: Icon.info).font(.title3).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Timeline color key")
            .popover(isPresented: $showLegend, arrowEdge: .leading) { legend }

            rail
        }
        .frame(width: 22)
    }

    private var rail: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .top) {
                Rectangle().fill(.secondary.opacity(0.15)).frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .center)

                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    let y = CGFloat(h) * CGFloat(Double(m.index) / Double(max(eventCount - 1, 1)))
                    dot(m, y: y)
                }

                if let top = onJumpTop {
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
                        .position(x: 11, y: 0)
                        .onTapGesture { top() }
                }
                if let bottom = onJumpBottom {
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
                        .position(x: 11, y: h)
                        .onTapGesture { bottom() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline").font(.headline)
            ForEach(legendKinds, id: \.self) { kind in
                HStack(spacing: 8) {
                    Circle().fill(timelineColor(kind)).frame(width: 9, height: 9)
                    Text(timelineKindName(kind))
                }
            }
            Divider()
            Text("Bash, Read, Edit, etc. are not shown.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var legendKinds: [TimelineMarker.Kind] {
        [.user, .task, .subagent, .skill, .question, .hook, .plan]
    }

    @ViewBuilder private func dot(_ m: TimelineMarker, y: CGFloat) -> some View {
        let isHover = hovered == m.index
        Circle()
            .fill(timelineColor(m.kind))
            .frame(width: isHover ? 9 : 6, height: isHover ? 9 : 6)
            .position(x: 11, y: y)
            .onHover { hovering in
                if hovering { hovered = m.index }
                else if hovered == m.index { hovered = nil }
            }
            .onTapGesture { onTap(m.index) }
    }
}
